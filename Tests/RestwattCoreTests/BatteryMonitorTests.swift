import XCTest
@testable import RestwattCore

final class BatteryMonitorTests: XCTestCase {
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

    func testEstimatorIsFedOnlyOnNewGaugeUpdate() {
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)

        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1)

        clock.advance(by: 30)
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 1, "same UpdateTime is a duplicate")

        clock.advance(by: 30)
        var next = Fixtures.discharging7W
        next.updateTime += 60
        next.amperageMilliAmps = -600
        next.batteryPowerMilliWatts = -7554
        battery.result = .success(next)
        let third = status(monitor.tick())
        XCTAssertEqual(third.estimate?.sampleCount, 2)
        XCTAssertEqual(third.estimate?.instantWatts, 7.554)
        XCTAssertEqual(third.drawWatts, 7.554)
        XCTAssertEqual(third.systemTimeToEmptyMinutes, 466)
        XCTAssertEqual(third.percent, 95)
    }

    func testDirectionFlipRestartsTheSmoothing() {
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)
        var snapshot = Fixtures.discharging7W
        for _ in 0..<12 {
            battery.result = .success(snapshot)
            _ = monitor.tick()
            clock.advance(by: 60)
            snapshot.updateTime += 60
        }
        XCTAssertEqual(status(monitor.tick()).estimate?.confidence, .medium)

        battery.result = .success(Fixtures.charging)
        clock.advance(by: 60)
        let charging = status(monitor.tick())
        XCTAssertEqual(charging.state, .charging)
        XCTAssertEqual(charging.estimate?.sampleCount, 1, "charging starts its own smoothing from scratch")
        XCTAssertEqual(charging.estimate?.confidence, .low)
        XCTAssertNotNil(charging.estimate?.smoothedMinutes, "Restwatt has its own time to full")
        XCTAssertEqual(charging.avgTimeToFullMinutes, 65)
        XCTAssertNil(charging.systemTimeToEmptyMinutes)

        snapshot.updateTime += 600
        battery.result = .success(snapshot)
        clock.advance(by: 600)
        let back = status(monitor.tick())
        XCTAssertEqual(back.state, .discharging)
        XCTAssertEqual(back.estimate?.sampleCount, 1)
        XCTAssertEqual(back.estimate?.confidence, .low)
    }

    func testStrongChargerGetsOwnTimeToFullNextToTheGaugeFigure() {
        let battery = FakeBattery(Fixtures.charging96W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)
        let first = status(monitor.tick())
        XCTAssertEqual(first.state, .charging)
        XCTAssertEqual(first.drawWatts, -49.055, accuracy: 1e-9)
        XCTAssertEqual(first.estimate?.smoothedMinutes, 22)
        XCTAssertEqual(first.estimate?.instantMinutes, 22)
        XCTAssertEqual(first.avgTimeToFullMinutes, 50)
        XCTAssertEqual(first.adapterWatts, 96)
        XCTAssertNil(first.systemTimeToEmptyMinutes)
        XCTAssertEqual(first.percent, 75)

        // The next gauge reading charges a little slower; the smoothed time lags the instant one.
        clock.advance(by: 60)
        var next = Fixtures.charging96W
        next.updateTime += 60
        next.amperageMilliAmps = 3000
        next.batteryPowerMilliWatts = 37920
        battery.result = .success(next)
        let second = status(monitor.tick())
        XCTAssertEqual(second.estimate?.sampleCount, 2)
        XCTAssertEqual(second.estimate?.instantWatts, 37.92)
        XCTAssertGreaterThan(second.estimate!.smoothedWatts, 37.92)
        XCTAssertLessThan(second.estimate!.smoothedMinutes!, second.estimate!.instantMinutes!)
    }

    func testWeakSourceWithNetDrainShowsDrawAndTimeLeft() {
        let processes = FakeProcesses([Fixtures.process(1, "Restwatt", joules: 0, cpuSeconds: 0)])
        let battery = FakeBattery(Fixtures.weakSourceDraining)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: processes, clock: clock)
        let first = status(monitor.tick())
        XCTAssertEqual(first.state, .drainingOnExternalPower)
        XCTAssertEqual(first.drawWatts, 2.266, accuracy: 1e-9)
        XCTAssertEqual(first.estimate?.smoothedMinutes, 1667)
        XCTAssertEqual(first.systemTimeToEmptyMinutes, 466)
        XCTAssertNil(first.avgTimeToFullMinutes)
        XCTAssertEqual(first.adapterWatts, 30)

        clock.advance(by: 30)
        processes.samples = [Fixtures.process(1, "Restwatt", joules: 0.3, cpuSeconds: 0.2)]
        let second = status(monitor.tick())
        XCTAssertFalse(second.processReport.isWarmingUp)
        XCTAssertNil(second.processReport.unaccountedWatts,
                     "the battery draw is only the source's shortfall, not the system draw")
    }

    func testWeakSourceWithSlowChargeGetsOwnTimeToFullWithoutTheGauge() {
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.weakSourceSlowCharge), processes: FakeProcesses(), clock: ManualClock())
        let model = status(monitor.tick())
        XCTAssertEqual(model.state, .charging)
        XCTAssertNil(model.avgTimeToFullMinutes, "the gauge has no figure yet")
        XCTAssertEqual(model.estimate?.smoothedMinutes, 288)
        XCTAssertEqual(model.adapterWatts, 30)
    }

    func testNearZeroFlowOnExternalPowerClaimsNoTime() {
        let monitor = BatteryMonitor(
            battery: FakeBattery(Fixtures.nearZeroFlowOnExternal), processes: FakeProcesses(), clock: ManualClock())
        let model = status(monitor.tick())
        XCTAssertEqual(model.state, .onExternalPower(fullyCharged: false))
        XCTAssertNil(model.estimate)
        XCTAssertNil(model.systemTimeToEmptyMinutes)
        XCTAssertNil(model.avgTimeToFullMinutes)
        XCTAssertEqual(model.adapterWatts, 96)
    }

    func testPluggingInWithAStaleGaugeReadingWaitsForTheGauge() {
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)
        XCTAssertEqual(status(monitor.tick()).state, .discharging)

        // The plug event resamples at once: the flag flipped, the flow values did not.
        var stale = Fixtures.discharging7W
        stale.externalConnected = true
        stale.adapterWatts = 96
        battery.result = .success(stale)
        clock.advance(by: 5)
        let settling = status(monitor.tick())
        XCTAssertEqual(settling.state, .powerSourceChanging)
        XCTAssertNil(settling.estimate)
        XCTAssertNil(settling.systemTimeToEmptyMinutes)
        XCTAssertNil(settling.avgTimeToFullMinutes)
        XCTAssertEqual(settling.percent, 95)

        clock.advance(by: 25)
        XCTAssertEqual(status(monitor.tick()).state, .powerSourceChanging, "same UpdateTime, still settling")

        var fresh = Fixtures.charging96W
        fresh.updateTime = stale.updateTime + 60
        battery.result = .success(fresh)
        clock.advance(by: 30)
        let charging = status(monitor.tick())
        XCTAssertEqual(charging.state, .charging)
        XCTAssertEqual(charging.estimate?.sampleCount, 1)
        XCTAssertEqual(charging.estimate?.smoothedMinutes, 22)
    }

    func testPluggingInWithAFreshGaugeReadingNeedsNoSettling() {
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)
        _ = monitor.tick()

        var fresh = Fixtures.charging96W
        fresh.updateTime = Fixtures.discharging7W.updateTime + 1
        battery.result = .success(fresh)
        clock.advance(by: 5)
        let charging = status(monitor.tick())
        XCTAssertEqual(charging.state, .charging)
        XCTAssertEqual(charging.estimate?.smoothedMinutes, 22)
    }

    func testUnpluggingWithAStaleChargeCurrentShowsNoNegativeDraw() {
        let battery = FakeBattery(Fixtures.charging96W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)
        XCTAssertEqual(status(monitor.tick()).state, .charging)

        var stale = Fixtures.charging96W
        stale.externalConnected = false
        stale.isCharging = false
        stale.adapterWatts = nil
        battery.result = .success(stale)
        clock.advance(by: 5)
        let settling = status(monitor.tick())
        XCTAssertEqual(settling.state, .powerSourceChanging)
        XCTAssertNil(settling.estimate)
        XCTAssertEqual(Formatting.menuBarTitle(.battery(settling)), "75 %")

        var fresh = Fixtures.discharging7W
        fresh.updateTime = stale.updateTime + 60
        battery.result = .success(fresh)
        clock.advance(by: 55)
        let discharging = status(monitor.tick())
        XCTAssertEqual(discharging.state, .discharging)
        XCTAssertEqual(discharging.estimate?.sampleCount, 1)
        XCTAssertEqual(discharging.drawWatts, 7.138)
    }

    func testBatteryOnlyToWeakSourceRestartsTheSmoothing() {
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: FakeProcesses(), clock: clock)
        var snapshot = Fixtures.discharging7W
        for _ in 0..<6 {
            battery.result = .success(snapshot)
            _ = monitor.tick()
            clock.advance(by: 60)
            snapshot.updateTime += 60
        }
        XCTAssertEqual(status(monitor.tick()).estimate?.sampleCount, 6)

        var weak = Fixtures.weakSourceDraining
        weak.updateTime = snapshot.updateTime
        battery.result = .success(weak)
        let onWeakSource = status(monitor.tick())
        XCTAssertEqual(onWeakSource.state, .drainingOnExternalPower)
        XCTAssertEqual(onWeakSource.estimate?.sampleCount, 1, "the watts changed meaning, so the smoothing restarts")
    }

    func testBatteryErrorIsUnavailable() {
        let monitor = BatteryMonitor(
            battery: FakeBattery(error: .noBattery), processes: FakeProcesses(), clock: ManualClock())
        let model = monitor.tick()
        XCTAssertEqual(model, .unavailable(reason: "No battery found"))
        XCTAssertEqual(Formatting.menuBarTitle(model), "No battery")

        let malformed = BatteryMonitor(
            battery: FakeBattery(error: .malformed(key: "Voltage")), processes: FakeProcesses(),
            clock: ManualClock())
        guard case .unavailable = malformed.tick() else {
            return XCTFail("malformed data must not crash or show numbers")
        }
    }

    func testProcessReportLandsInTheModel() {
        let processes = FakeProcesses([Fixtures.process(1, "Restwatt", joules: 0, cpuSeconds: 0)])
        let battery = FakeBattery(Fixtures.discharging7W)
        let clock = ManualClock()
        let monitor = BatteryMonitor(battery: battery, processes: processes, clock: clock)

        XCTAssertTrue(status(monitor.tick()).processReport.isWarmingUp)

        clock.advance(by: 30)
        processes.samples = [Fixtures.process(1, "Restwatt", joules: 0.3, cpuSeconds: 0.2)]
        let second = status(monitor.tick())
        XCTAssertFalse(second.processReport.isWarmingUp)
        XCTAssertEqual(second.processReport.entries.first?.name, "Restwatt")
        XCTAssertEqual(second.processReport.entries.first!.watts, 0.01, accuracy: 1e-9)
        XCTAssertEqual(second.processReport.unaccountedWatts!, 7.128, accuracy: 1e-9)

        clock.advance(by: 30)
        battery.result = .success(Fixtures.onExternalPowerFull)
        processes.samples = [Fixtures.process(1, "Restwatt", joules: 0.6, cpuSeconds: 0.4)]
        let onAC = status(monitor.tick())
        XCTAssertNil(onAC.processReport.unaccountedWatts)
        XCTAssertEqual(onAC.processReport.entries.count, 1)
    }
}
