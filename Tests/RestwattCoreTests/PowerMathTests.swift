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

    func testMissingWattHours() {
        XCTAssertEqual(PowerMath.missingWattHours(Fixtures.charging96W), 18.18, accuracy: 0.01)
        XCTAssertEqual(PowerMath.missingWattHours(Fixtures.weakSourceSlowCharge), 7.25, accuracy: 0.01)
        var overfull = Fixtures.charging96W
        overfull.remainingCapacityMilliAmpHours = overfull.fullChargeCapacityMilliAmpHours + 20
        XCTAssertEqual(PowerMath.missingWattHours(overfull), 0, "drifting FullChargeCapacity never yields a negative gap")
    }

    func testMinutes() {
        XCTAssertEqual(PowerMath.minutes(energyWattHours: 62.975, watts: 7.138)!, 529, accuracy: 1)
        XCTAssertNil(PowerMath.minutes(energyWattHours: 62.975, watts: 0.05))
        XCTAssertNil(PowerMath.minutes(energyWattHours: 62.975, watts: -3))
        XCTAssertEqual(PowerMath.minutes(energyWattHours: 62.975, watts: 0.1), PowerMath.maximumMinutes)
        XCTAssertEqual(PowerMath.minutes(energyWattHours: 18.176, watts: 49.055), 22)
    }

    func testPowerState() {
        XCTAssertEqual(Fixtures.discharging7W.powerState, .discharging)
        XCTAssertEqual(Fixtures.charging.powerState, .charging)
        XCTAssertEqual(Fixtures.onExternalPowerFull.powerState, .onExternalPower(fullyCharged: true))
        var pluggedNotCharging = Fixtures.onExternalPowerFull
        pluggedNotCharging.fullyCharged = false
        XCTAssertEqual(pluggedNotCharging.powerState, .onExternalPower(fullyCharged: false))
    }

    func testPowerStateFollowsTheNetFlowNotTheFlags() {
        XCTAssertEqual(Fixtures.charging96W.powerState, .charging)
        XCTAssertEqual(Fixtures.weakSourceDraining.powerState, .drainingOnExternalPower,
                       "a connected source that covers less than the draw leaves the battery draining")
        XCTAssertEqual(Fixtures.weakSourceSlowCharge.powerState, .charging)
        XCTAssertEqual(Fixtures.nearZeroFlowOnExternal.powerState, .onExternalPower(fullyCharged: false))

        var flagsSayCharging = Fixtures.weakSourceDraining
        flagsSayCharging.isCharging = true
        XCTAssertEqual(flagsSayCharging.powerState, .drainingOnExternalPower, "IsCharging does not override the sign")

        var noSourceButStaleChargeCurrent = Fixtures.charging96W
        noSourceButStaleChargeCurrent.externalConnected = false
        XCTAssertEqual(noSourceButStaleChargeCurrent.powerState, .discharging, "without a source the sign is irrelevant")
    }

    func testDeadBandEdges() {
        // Voltage times amperage alone, so the net flow is exact: 12.5 V times 40 mA = 0.5 W.
        var edge = Fixtures.discharging7W
        edge.externalConnected = true
        edge.voltageMilliVolts = 12500
        edge.batteryPowerMilliWatts = nil

        edge.amperageMilliAmps = -40
        XCTAssertEqual(PowerMath.drawWatts(edge), PowerMath.flowDeadBandWatts)
        XCTAssertEqual(edge.powerState, .drainingOnExternalPower, "exactly on the band edge counts as draining")
        edge.amperageMilliAmps = 40
        XCTAssertEqual(edge.powerState, .charging, "exactly on the band edge counts as charging")
        edge.amperageMilliAmps = -39
        XCTAssertEqual(edge.powerState, .onExternalPower(fullyCharged: false))
        edge.amperageMilliAmps = 39
        XCTAssertEqual(edge.powerState, .onExternalPower(fullyCharged: false))
        edge.amperageMilliAmps = 0
        edge.fullyCharged = true
        XCTAssertEqual(edge.powerState, .onExternalPower(fullyCharged: true))
    }

    func testDeadBandIsWellAboveTheMinimumDraw() {
        XCTAssertGreaterThan(PowerMath.flowDeadBandWatts, PowerMath.minimumDrawWatts)
        XCTAssertLessThan(PowerMath.flowDeadBandWatts, PowerMath.drawWatts(Fixtures.weakSourceDraining),
                          "the band must not swallow the synthetic weak-source drain")
        XCTAssertLessThan(PowerMath.flowDeadBandWatts, -PowerMath.drawWatts(Fixtures.weakSourceSlowCharge),
                          "the band must not swallow the synthetic slow charge")
    }
}
