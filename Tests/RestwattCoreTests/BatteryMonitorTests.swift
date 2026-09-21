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

    func testPluggingInResetsTheEstimator() {
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
        XCTAssertNil(charging.estimate)
        XCTAssertEqual(charging.avgTimeToFullMinutes, 65)
        XCTAssertNil(charging.systemTimeToEmptyMinutes)

        snapshot.updateTime += 600
        battery.result = .success(snapshot)
        clock.advance(by: 600)
        let back = status(monitor.tick())
        XCTAssertEqual(back.estimate?.sampleCount, 1)
        XCTAssertEqual(back.estimate?.confidence, .low)
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
