import XCTest
@testable import RestwattCore

final class PowerMathTests: XCTestCase {
    func testDrawWattsUsesReportedBatteryPower() {
        XCTAssertEqual(PowerMath.drawWatts(Fixtures.discharging7W), 7.138, accuracy: 0.001)
    }

    func testDrawWattsFallsBackToVoltageTimesAmperage() {
        var snapshot = Fixtures.discharging7W
        snapshot.batteryPowerMilliWatts = nil
        XCTAssertEqual(PowerMath.drawWatts(snapshot), 7.138, accuracy: 0.001)
    }

    func testImplausibleBatteryPowerLosesAgainstVoltageTimesAmperage() {
        var snapshot = Fixtures.discharging7W
        snapshot.batteryPowerMilliWatts = -14040  // almost twice V*A
        XCTAssertEqual(PowerMath.drawWatts(snapshot), 7.138, accuracy: 0.001)
    }

    func testDrawWattsIsNegativeWhileCharging() {
        XCTAssertLessThan(PowerMath.drawWatts(Fixtures.charging), 0)
    }

    func testRemainingWattHours() {
        XCTAssertEqual(PowerMath.remainingWattHours(Fixtures.discharging7W), 62.975, accuracy: 0.01)
    }

    func testMinutesToEmpty() {
        XCTAssertEqual(PowerMath.minutesToEmpty(remainingWattHours: 62.975, watts: 7.138)!, 529, accuracy: 1)
        XCTAssertNil(PowerMath.minutesToEmpty(remainingWattHours: 62.975, watts: 0.05))
        XCTAssertNil(PowerMath.minutesToEmpty(remainingWattHours: 62.975, watts: -3))
        XCTAssertEqual(PowerMath.minutesToEmpty(remainingWattHours: 62.975, watts: 0.1), PowerMath.maximumMinutes)
    }

    func testPowerState() {
        XCTAssertEqual(Fixtures.discharging7W.powerState, .discharging)
        XCTAssertEqual(Fixtures.charging.powerState, .charging)
        XCTAssertEqual(Fixtures.onExternalPowerFull.powerState, .onExternalPower(fullyCharged: true))
        var pluggedNotCharging = Fixtures.onExternalPowerFull
        pluggedNotCharging.fullyCharged = false
        XCTAssertEqual(pluggedNotCharging.powerState, .onExternalPower(fullyCharged: false))
    }
}
