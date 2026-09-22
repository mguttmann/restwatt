import XCTest
@testable import RestwattCore

/// The Energy Mode mapping, the six fixed pmset vectors and the observation of one refresh
/// (ticket 11, spec section 7.2).
final class EnergyModeTests: XCTestCase {
    func testRawValuesAreWhatPmsetPrintsUnderPowermode() {
        XCTAssertEqual(EnergyMode(rawValue: 0), .automatic)
        XCTAssertEqual(EnergyMode(rawValue: 1), .lowPower)
        XCTAssertEqual(EnergyMode(rawValue: 2), .highPower)
        XCTAssertNil(EnergyMode(rawValue: 3))
        XCTAssertNil(EnergyMode(rawValue: -1))
        XCTAssertEqual(EnergyMode.allCases, [.automatic, .lowPower, .highPower])
    }

    func testLabelsAreApplesWordingAndTheDetailShowsTheRawValue() {
        XCTAssertEqual(EnergyMode.automatic.label, "Automatic")
        XCTAssertEqual(EnergyMode.lowPower.label, "Low Power")
        XCTAssertEqual(EnergyMode.highPower.label, "High Power")
        XCTAssertEqual(EnergyMode.automatic.rawDetail, "powermode 0")
        XCTAssertEqual(EnergyMode.lowPower.rawDetail, "powermode 1")
        XCTAssertEqual(EnergyMode.highPower.rawDetail, "powermode 2")
        XCTAssertEqual(SettingKey.energyMode(.lowPower).label, "Low Power")
    }

    func testPowerSourcesAreThePmsetBlockHeadersFlagsAndMenuWords() {
        XCTAssertEqual(PowerSource.battery.rawValue, "Battery Power")
        XCTAssertEqual(PowerSource.ac.rawValue, "AC Power")
        XCTAssertEqual(PowerSource.battery.pmsetFlag, "-b")
        XCTAssertEqual(PowerSource.ac.pmsetFlag, "-c")
        XCTAssertEqual(PowerSource.battery.label, "Battery")
        XCTAssertEqual(PowerSource.ac.label, "AC")
    }

    // MARK: Vectors

    func testEnergyModeVectorsAreFixedPerSourceAndMode() {
        XCTAssertEqual(SystemCommands.energyModeKey, "lowpowermode")
        XCTAssertEqual(SystemCommands.pmsetEnergyMode(.lowPower, source: .battery),
                       CommandVector("/usr/bin/pmset", ["-b", "lowpowermode", "1"]))
        XCTAssertEqual(SystemCommands.pmsetEnergyMode(.highPower, source: .ac).arguments, ["-c", "lowpowermode", "2"])
        XCTAssertEqual(SystemCommands.pmsetEnergyMode(.automatic, source: .battery).arguments, ["-b", "lowpowermode", "0"])
        XCTAssertEqual(SystemCommands.energyModeVectors, [
            CommandVector("/usr/bin/pmset", ["-b", "lowpowermode", "0"]),
            CommandVector("/usr/bin/pmset", ["-b", "lowpowermode", "1"]),
            CommandVector("/usr/bin/pmset", ["-b", "lowpowermode", "2"]),
            CommandVector("/usr/bin/pmset", ["-c", "lowpowermode", "0"]),
            CommandVector("/usr/bin/pmset", ["-c", "lowpowermode", "1"]),
            CommandVector("/usr/bin/pmset", ["-c", "lowpowermode", "2"]),
        ])
    }

    /// Security lens: only the current source is ever written (never `-a`), every token is
    /// from the constant alphabet, sudo gets the vector unchanged and the dialog never
    /// mentions sudo.
    func testEnergyModeVectorsAddressOneSourceAndPassThePrivilegeGuards() throws {
        XCTAssertEqual(SystemCommands.energyModeVectors.count, 6)
        for vector in SystemCommands.energyModeVectors {
            XCTAssertEqual(vector.executable, "/usr/bin/pmset")
            XCTAssertFalse(vector.arguments.contains("-a"), vector.commandLine)
            XCTAssertEqual(vector.arguments.count, 3)
            for token in [vector.executable] + vector.arguments {
                XCTAssertEqual(try SystemCommands.validatedToken(token), token)
            }
            XCTAssertEqual(Array(SystemCommands.sudoNonInteractive(vector).arguments.prefix(2)), ["-n", "/usr/bin/pmset"])
            XCTAssertEqual(Array(SystemCommands.sudoNonInteractive(vector).arguments.dropFirst(2)), vector.arguments)
            let script = try SystemCommands.administratorScriptSource([vector])
            XCTAssertFalse(script.contains("sudo"))
            XCTAssertEqual(script, "do shell script \"\(vector.commandLine)\" with administrator privileges")
        }
    }

    func testReadVectorsForTheEnergyMode() {
        XCTAssertEqual(SystemCommands.pmsetReadCustom, CommandVector("/usr/bin/pmset", ["-g", "custom"]))
        XCTAssertEqual(SystemCommands.pmsetReadCapabilities, CommandVector("/usr/bin/pmset", ["-g", "cap"]))
    }

    // MARK: Observation

    func testAnAbsentLineReadsAsAutomaticAndAnUnknownValueAsNothing() {
        XCTAssertEqual(EnergyModeObservation(source: .battery, rawValue: nil, highPowerCapable: true).mode, .automatic)
        XCTAssertEqual(EnergyModeObservation(source: .battery, rawValue: 1, highPowerCapable: true).mode, .lowPower)
        XCTAssertNil(EnergyModeObservation(source: .battery, rawValue: 7, highPowerCapable: true).mode)
    }

    func testHighPowerIsOfferedWhenCapableOrAlreadySet() {
        XCTAssertTrue(EnergyModeObservation(source: .ac, rawValue: 2, highPowerCapable: false).offersHighPower)
        XCTAssertFalse(EnergyModeObservation(source: .battery, rawValue: 1, highPowerCapable: false).offersHighPower)
        XCTAssertTrue(EnergyModeObservation(source: .battery, rawValue: nil, highPowerCapable: true).offersHighPower)
    }

    func testSnapshotMarksExactlyTheObservedMode() {
        var snapshot = SettingsSnapshot(energyMode: .known(EnergyModeObservation(source: .battery, rawValue: 1, highPowerCapable: true)))
        XCTAssertTrue(snapshot.isOn(.energyMode(.lowPower)))
        XCTAssertFalse(snapshot.isOn(.energyMode(.automatic)))
        XCTAssertFalse(snapshot.isOn(.energyMode(.highPower)))

        snapshot.energyMode = .unknown("x")
        for mode in EnergyMode.allCases {
            XCTAssertFalse(snapshot.isOn(.energyMode(mode)), "nothing is marked while nothing was read")
        }

        snapshot.energyMode = .known(EnergyModeObservation(source: .battery, rawValue: 7, highPowerCapable: true))
        for mode in EnergyMode.allCases {
            XCTAssertFalse(snapshot.isOn(.energyMode(mode)), "an unknown value marks nothing")
        }
    }
}
