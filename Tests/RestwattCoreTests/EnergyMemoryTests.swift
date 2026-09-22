import XCTest
@testable import RestwattCore

/// The monitor with a memory: what a launch takes from the file and what it writes back.
final class EnergyMemoryTests: XCTestCase {
    private let wallNow = Fixtures.wallNow.timeIntervalSince1970

    private func status(_ model: DisplayModel) -> BatteryStatus {
        guard case .battery(let status) = model else {
            XCTFail("expected a battery model, got \(model)")
            return BatteryStatus(
                state: .discharging, percent: 0, remainingWattHours: 0, drawWatts: 0, estimate: nil,
                systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: nil,
                processReport: .warmingUp, sampledAt: 0)
        }
        return status
    }

    private func draining(gap: TimeInterval, observed: TimeInterval = 3600) -> StoredEstimatorState {
        StoredEstimatorState(smoothedWatts: 7.5, observedSeconds: observed, sampleCount: 40, lastSampleAt: wallNow - gap)
    }

    private func memory(_ stored: StoredStatistics?, store: MemoryStatisticsStore? = nil,
                        wallClock: ManualWallClock = ManualWallClock()) -> EnergyMemory {
        EnergyMemory(store: store ?? MemoryStatisticsStore(stored), wallClock: wallClock, calendar: Fixtures.newYork)
    }

    private func stored(_ estimators: [String: StoredEstimatorState], bootTime: Date? = Fixtures.bootTime,
                        today: DailyEnergyStatistic? = nil) -> StoredStatistics {
        StoredStatistics(bootTime: bootTime?.timeIntervalSince1970, savedAt: wallNow - 300, estimators: estimators, today: today)
    }

    func testLaunchResumesTheRememberedDrainingEstimate() {
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock(now: 267_741),
            memory: memory(stored(["discharging": draining(gap: 300)])))
        let first = status(monitor.tick()).estimate!
        XCTAssertEqual(first.sampleCount, 41)
        XCTAssertEqual(first.observedSeconds, 3300, "five minutes of pause cost five minutes of window")
        XCTAssertEqual(first.confidence, .high)
        XCTAssertEqual(first.smoothedWatts, 7.5)
        XCTAssertEqual(first.instantWatts, 7.138)
        XCTAssertEqual(Formatting.detailRows(.battery(status(monitor.tick())))[4],
                       DetailRow("Smoothing", "55 min observed, confidence high"))
    }

    func testLaunchAfterAnHourStartsFresh() {
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock(),
            memory: memory(stored(["discharging": draining(gap: 3600)])))
        let first = status(monitor.tick()).estimate!
        XCTAssertEqual(first.sampleCount, 1)
        XCTAssertEqual(first.observedSeconds, 0)
        XCTAssertEqual(first.confidence, .low)
        XCTAssertEqual(first.smoothedWatts, 7.138)
    }

    func testRebootStartsFreshButKeepsToday() {
        let file = stored(["discharging": draining(gap: 120)], bootTime: Fixtures.bootTime.addingTimeInterval(-3600),
                          today: Fixtures.todayStatistic)
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock(),
            memory: memory(file))
        let first = status(monitor.tick())
        XCTAssertEqual(first.estimate?.sampleCount, 1, "the workload is new after a reboot")
        XCTAssertEqual(first.today, Fixtures.todayStatistic, "the day's energy is real either way")
    }

    func testRebootForgetsEveryStateEvenAfterTheFileWasRewritten() {
        let store = MemoryStatisticsStore(stored(
            ["discharging": draining(gap: 120), "charging": draining(gap: 120)],
            bootTime: Fixtures.bootTime.addingTimeInterval(-3600)))
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock, memory: memory(nil, store: store))
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1)
        XCTAssertEqual(store.stored?.bootTime, Fixtures.bootTime.timeIntervalSince1970, "the file now carries the new boot")

        clock.advance(by: 60)
        var charging = Fixtures.charging
        charging.updateTime += 60
        battery.result = .success(charging)
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1, "the pre-reboot charging entry is not resumed either")
    }

    func testChargingMemoryIsNotUsedWhileDraining() {
        let chargingEntry = draining(gap: 0)
        let store = MemoryStatisticsStore(stored(["charging": chargingEntry]))
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock(),
            memory: memory(nil, store: store))
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1)
        // Hardened (tester): the entry of the other state is not consumed, it stays in the file
        // for its own state, next to the new draining entry.
        XCTAssertEqual(store.stored?.estimators["charging"], chargingEntry, "the unused entry stays in the file untouched")
        XCTAssertEqual(store.stored?.estimators["discharging"]?.sampleCount, 1)
    }

    /// Hardened (tester): the whole promise of the ticket in one flow. Session A samples for a
    /// while and writes the file through the store; session B, built on the same store five
    /// minutes later, continues from A's smoothed power with the window shortened by the pause
    /// and shows A's day statistic from its first tick.
    func testASecondLaunchContinuesWhereTheFirstLeftOff() {
        let store = MemoryStatisticsStore()
        let firstWallClock = ManualWallClock()
        let firstClock = ManualClock(now: 1000)
        let firstProcesses = FakeProcesses([Fixtures.process(1, "Restwatt", joules: 0, cpuSeconds: 0)])
        let battery = FakeBattery(Fixtures.discharging7W)
        let firstLaunch = BatteryMonitor(battery: battery, processes: firstProcesses, clock: firstClock,
                                         memory: memory(nil, store: store, wallClock: firstWallClock))
        var snapshot = Fixtures.discharging7W
        var lastStatus = status(firstLaunch.tick())
        for tick in 1...20 {
            firstClock.advance(by: 30)
            firstWallClock.advance(by: 30)
            snapshot.updateTime += 30
            battery.result = .success(snapshot)
            firstProcesses.samples = [Fixtures.process(1, "Restwatt", joules: Double(tick) * 0.3, cpuSeconds: Double(tick) * 0.2)]
            lastStatus = status(firstLaunch.tick())
        }
        XCTAssertEqual(lastStatus.estimate?.sampleCount, 21)
        XCTAssertEqual(lastStatus.estimate?.observedSeconds, 600)
        XCTAssertEqual(lastStatus.today?.sampledSeconds, 600)
        firstLaunch.willTerminate()
        XCTAssertEqual(store.stored?.estimators["discharging"]?.observedSeconds, 600)
        XCTAssertEqual(store.stored?.estimators["discharging"]?.lastSampleAt, wallNow + 600)

        // Five minutes later the app is launched again: fresh uptime clock, fresh process reader,
        // the same file.
        let secondWallClock = ManualWallClock(now: Fixtures.wallNow.addingTimeInterval(600 + 300))
        let secondClock = ManualClock(now: 50)
        let secondLaunch = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: secondClock,
                                          memory: memory(nil, store: store, wallClock: secondWallClock))
        let resumed = status(secondLaunch.tick())
        XCTAssertEqual(resumed.estimate?.sampleCount, 22, "session B counts on from A")
        XCTAssertEqual(resumed.estimate?.observedSeconds, 300, "ten minutes observed minus five minutes of pause")
        XCTAssertEqual(resumed.estimate?.smoothedWatts, 7.138)
        XCTAssertEqual(resumed.estimate?.confidence, .medium, "damped from what A had, not reset to low")
        XCTAssertTrue(resumed.processReport.isWarmingUp, "the live list still needs its second reading")
        XCTAssertEqual(resumed.today?.day, "2026-09-22")
        XCTAssertEqual(resumed.today?.sampledSeconds, 600, "the day statistic shows from the first tick of B")
        XCTAssertEqual(resumed.today?.entries.map(\.name), ["Restwatt"])
        XCTAssertEqual(resumed.today!.totalWattHours, 6.0 / 3600, accuracy: 1e-12, "20 intervals of 0.3 J")

        secondClock.advance(by: 30)
        snapshot.updateTime += 30
        battery.result = .success(snapshot)
        let next = status(secondLaunch.tick())
        XCTAssertEqual(next.estimate?.sampleCount, 23)
        XCTAssertEqual(next.estimate?.observedSeconds, 330, "from the second sample on the window grows with the session")
    }

    /// Hardened (tester): the one case where quitting writes anything is a change the last tick
    /// could not persist; `willTerminate` must retry it.
    func testQuitWritesWhatTheLastTickCouldNot() {
        let store = MemoryStatisticsStore()
        store.saveError = "disk full"
        let monitor = BatteryMonitor(battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock(),
                                     memory: memory(nil, store: store))
        _ = monitor.tick()
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertNil(store.stored)

        store.saveError = nil
        monitor.willTerminate()
        XCTAssertEqual(store.saveCount, 2, "quit retries the failed write")
        XCTAssertEqual(store.stored?.estimators["discharging"]?.sampleCount, 1)
        monitor.willTerminate()
        XCTAssertEqual(store.saveCount, 2, "and writes nothing once the file is current")
    }

    func testFirstEntryIntoAStateResumesLaterSwitchesRestart() {
        let store = MemoryStatisticsStore(stored(["discharging": draining(gap: 60)]))
        let battery = FakeBattery(Fixtures.onExternalPowerFull)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock, memory: memory(nil, store: store))
        XCTAssertNil(status(monitor.tick()).estimate, "on AC there is nothing to estimate")

        clock.advance(by: 600)
        var unplugged = Fixtures.discharging7W
        unplugged.updateTime += 600
        battery.result = .success(unplugged)
        let resumed = status(monitor.tick())
        XCTAssertEqual(resumed.state, .discharging)
        XCTAssertEqual(resumed.estimate?.sampleCount, 41, "first entry into draining this session takes the memory")
        XCTAssertEqual(resumed.estimate?.observedSeconds, 3540)

        clock.advance(by: 60)
        var charging = Fixtures.charging
        charging.updateTime = unplugged.updateTime + 60
        battery.result = .success(charging)
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1, "no charging memory in the file")

        clock.advance(by: 60)
        unplugged.updateTime = charging.updateTime + 60
        battery.result = .success(unplugged)
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1, "a switch back within the session starts fresh")
    }

    func testMemoryIsWrittenAtMostOncePerTickAndOnQuit() {
        let store = MemoryStatisticsStore()
        let processes = FakeProcesses([Fixtures.process(1, "Restwatt", joules: 0, cpuSeconds: 0)])
        let clock = ManualClock()
        let wallClock = ManualWallClock()
        let monitor = BatteryMonitor(battery: FakeBattery(Fixtures.discharging7W), processes: processes, clock: clock,
                                     memory: memory(nil, store: store, wallClock: wallClock))
        for tick in 1...3 {
            _ = monitor.tick()
            XCTAssertEqual(store.saveCount, tick, "each tick changes the anchor time, one write per tick")
            clock.advance(by: 30)
            wallClock.advance(by: 30)
            processes.samples = [Fixtures.process(1, "Restwatt", joules: Double(tick) * 0.3, cpuSeconds: Double(tick) * 0.2)]
        }
        monitor.willTerminate()
        XCTAssertEqual(store.saveCount, 3, "nothing changed since the last tick, so quitting writes nothing")

        _ = monitor.tick()
        XCTAssertEqual(store.saveCount, 4)
        monitor.willTerminate()
        XCTAssertEqual(store.saveCount, 4)
    }

    func testStoredEstimatorCarriesWallClockNotUptime() {
        let store = MemoryStatisticsStore()
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock(now: 267_741),
            memory: memory(nil, store: store))
        _ = monitor.tick()
        let entry = store.stored?.estimators["discharging"]
        XCTAssertEqual(entry?.lastSampleAt, wallNow)
        XCTAssertEqual(entry?.smoothedWatts, 7.138)
        XCTAssertEqual(entry?.observedSeconds, 0)
        XCTAssertEqual(entry?.sampleCount, 1)
        XCTAssertEqual(store.stored?.bootTime, Fixtures.bootTime.timeIntervalSince1970)
        XCTAssertEqual(store.stored?.savedAt, wallNow)
        XCTAssertEqual(store.stored?.version, 1)
        XCTAssertNil(store.stored?.estimators["charging"])
    }

    func testTodayIsRecordedFromAllVisibleNames() {
        let names = ["a", "b", "c", "d", "e", "f", "g"]
        let processes = FakeProcesses(names.enumerated().map { Fixtures.process(Int32($0.offset + 1), $0.element, joules: 0, cpuSeconds: 0) })
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: FakeBattery(Fixtures.discharging7W), processes: processes, clock: clock,
                                     memory: memory(nil))
        let first = status(monitor.tick())
        XCTAssertNil(first.today, "nothing sampled yet")
        XCTAssertTrue(first.processReport.isWarmingUp)

        clock.advance(by: 30)
        processes.samples = names.enumerated().map {
            Fixtures.process(Int32($0.offset + 1), $0.element, joules: Double($0.offset + 1) * 3, cpuSeconds: 1)
        }
        let second = status(monitor.tick())
        XCTAssertEqual(second.processReport.entries.count, 5)
        XCTAssertEqual(second.today?.entries.count, 7)
        XCTAssertEqual(second.today?.day, "2026-09-22")
        XCTAssertEqual(second.today?.sampledSeconds, 30)
        XCTAssertEqual(second.today?.entries.first?.name, "g")
        // 21 J over 30 s is 0.7 W; over 30 s that is 21 J = 5.833 mWh.
        XCTAssertEqual(second.today!.entries.first!.wattHours, 21.0 / 3600, accuracy: 1e-12)
        XCTAssertEqual(second.today!.totalWattHours, 84.0 / 3600, accuracy: 1e-12)
    }

    func testUnavailableWritesNothing() {
        let store = MemoryStatisticsStore()
        let monitor = BatteryMonitor(battery: FakeBattery(error: .noBattery), processes: FakeProcesses(), clock: ManualClock(),
                                     memory: memory(nil, store: store))
        _ = monitor.tick()
        monitor.willTerminate()
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(store.stored)
    }

    func testSaveErrorIsSwallowedAndRetried() {
        let store = MemoryStatisticsStore()
        store.saveError = "disk full"
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: clock,
                                     memory: memory(nil, store: store))
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1, "the tick itself is unaffected")
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertNil(store.stored)

        store.saveError = nil
        clock.advance(by: 30)
        _ = monitor.tick()
        XCTAssertEqual(store.saveCount, 2)
        XCTAssertEqual(store.stored?.estimators["discharging"]?.sampleCount, 1)
    }

    func testWithoutAMemoryTheMonitorBehavesAsBefore() {
        let monitor = BatteryMonitor(battery: FakeBattery(Fixtures.discharging7W), processes: FakeProcesses(), clock: ManualClock())
        let first = status(monitor.tick())
        XCTAssertEqual(first.estimate?.sampleCount, 1)
        XCTAssertNil(first.today)
        monitor.willTerminate()
    }
}
