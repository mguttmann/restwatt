import XCTest
@testable import RestwattCore

/// Pins the labels and order of the settings section of the click menu.
final class SettingsRowTests: XCTestCase {
    private let allOff = SettingsSnapshot(
        awake: [.idleSleep: false, .displaySleep: false, .diskIdle: false],
        sleepDisabled: .known(false),
        sync: [.iCloudDrive: .off, .iCloudPhotos: .off, .oneDrive: .off],
        energyMode: .known(EnergyModeObservation(source: .battery, rawValue: 0, highPowerCapable: true)))

    private func labels(_ snapshot: SettingsSnapshot) -> [String] {
        Formatting.settingsRows(snapshot).map { row in
            switch row.kind {
            case .heading: return row.label
            case .toggle(_, let isOn): return (isOn ? "[x] " : "[ ] ") + row.label + (row.detail.isEmpty ? "" : "  " + row.detail)
            case .openAtLogin(let isOn): return (isOn ? "[x] " : "[ ] ") + row.label
            case .note: return "    " + row.label
            case .warning: return "  ! " + row.label
            }
        }
    }

    /// The Energy Mode group alone, for the tests that vary only it.
    private func energyRows(_ snapshot: SettingsSnapshot) -> [String] {
        let rows = labels(snapshot)
        let start = rows.firstIndex(of: "Energy Mode")!
        let end = rows.firstIndex(of: "Sync")!
        return Array(rows[start..<end])
    }

    private func snapshot(energy source: PowerSource, _ rawValue: Int?, highPower: Bool = true) -> SettingsSnapshot {
        var snapshot = allOff
        snapshot.energyMode = .known(EnergyModeObservation(source: source, rawValue: rawValue, highPowerCapable: highPower))
        return snapshot
    }

    func testEverythingOff() {
        XCTAssertEqual(labels(allOff), [
            "Power",
            "[ ] Keep awake",
            "[ ] Keep display awake",
            "[ ] Keep disk awake",
            "[ ] Stay awake with the lid closed",
            "    system-wide, needs administrator, restored when Restwatt quits",
            "Energy Mode",
            "    Power Source: Battery",
            "[x] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
            "Sync",
            "[ ] iCloud Drive  off",
            "[ ] iCloud Photos  off",
            "[ ] OneDrive  not running",
        ])
    }

    func testTheSpecExample() {
        var snapshot = allOff
        snapshot.awake[.idleSleep] = true
        snapshot.sleepDisabled = .known(true)
        snapshot.armedByRestwatt = true
        snapshot.sync = [.iCloudDrive: .running, .iCloudPhotos: .loadedIdle, .oneDrive: .off]
        snapshot.energyMode = .known(EnergyModeObservation(source: .battery, rawValue: 1, highPowerCapable: true))
        XCTAssertEqual(labels(snapshot), [
            "Power",
            "[x] Keep awake",
            "[ ] Keep display awake",
            "[ ] Keep disk awake",
            "[x] Stay awake with the lid closed",
            "    system-wide, needs administrator, restored when Restwatt quits",
            "Energy Mode",
            "    Power Source: Battery",
            "[ ] Automatic  powermode 0",
            "[x] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
            "Sync",
            "[x] iCloud Drive  running",
            "[x] iCloud Photos  idle, starts on demand",
            "[ ] OneDrive  not running",
        ])
    }

    func testSetOutsideRestwattOnlyWhenObservedOnAndNotArmed() {
        var snapshot = allOff
        snapshot.sleepDisabled = .known(true)
        snapshot.armedByRestwatt = false
        XCTAssertTrue(labels(snapshot).contains("    set outside Restwatt"))
        XCTAssertEqual(labels(snapshot)[4], "[x] Stay awake with the lid closed")

        snapshot.armedByRestwatt = true
        XCTAssertFalse(labels(snapshot).contains("    set outside Restwatt"))

        snapshot.armedByRestwatt = false
        snapshot.sleepDisabled = .known(false)
        XCTAssertFalse(labels(snapshot).contains("    set outside Restwatt"))
    }

    func testRootFailureShowsOffWithAWarningUnderTheToggle() {
        var snapshot = allOff
        snapshot.lastError[.lidClosedAwake] = "execution error: User canceled. (-128)"
        let rows = labels(snapshot)
        XCTAssertEqual(rows[4], "[ ] Stay awake with the lid closed")
        XCTAssertEqual(rows[5], "    system-wide, needs administrator, restored when Restwatt quits")
        XCTAssertEqual(rows[6], "  ! could not change: execution error: User canceled. (-128)")
        XCTAssertEqual(rows[7], "Energy Mode")
    }

    func testUnreadablePmsetShowsOffWithTheReason() {
        var snapshot = allOff
        snapshot.sleepDisabled = .unknown("pmset -g exit 1: pmset: could not read settings")
        let rows = labels(snapshot)
        XCTAssertEqual(rows[4], "[ ] Stay awake with the lid closed")
        XCTAssertEqual(rows[6], "    could not read pmset: pmset -g exit 1: pmset: could not read settings")
    }

    /// Ticket 7 (b): a click refused because pmset is unreadable shows the reason once, in
    /// the note; the warning says only that nothing was written.
    func testRefusedClickWhilePmsetIsUnreadableShowsTheReasonOnce() {
        var snapshot = allOff
        snapshot.sleepDisabled = .unknown("pmset -g exit 1: pmset: could not read settings")
        snapshot.lastError[.lidClosedAwake] = "not written while SleepDisabled could not be read"
        let rows = labels(snapshot)
        XCTAssertEqual(rows[6], "    could not read pmset: pmset -g exit 1: pmset: could not read settings")
        XCTAssertEqual(rows[7], "  ! could not change: not written while SleepDisabled could not be read")
        XCTAssertEqual(rows.filter { $0.contains("could not read settings") }.count, 1)
    }

    func testWarningsSitUnderTheirOwnToggle() {
        var snapshot = allOff
        snapshot.lastError[.awake(.diskIdle)] = "IOPMAssertionCreateWithName returned e00002bc"
        snapshot.lastError[.sync(.oneDrive)] = "com.microsoft.OneDrive is not installed"
        snapshot.lastError[.energyMode(.highPower)] = "/usr/bin/pmset -b lowpowermode 2 exit 1: pmset: lowpowermode 2 is not supported on this system"
        snapshot.sync[.iCloudPhotos] = .unknown("launchctl print exit 1: Could not connect to launchd")
        snapshot.storeError = "You don't have permission to save the file"
        XCTAssertEqual(labels(snapshot), [
            "Power",
            "[ ] Keep awake",
            "[ ] Keep display awake",
            "[ ] Keep disk awake",
            "  ! could not change: IOPMAssertionCreateWithName returned e00002bc",
            "[ ] Stay awake with the lid closed",
            "    system-wide, needs administrator, restored when Restwatt quits",
            "Energy Mode",
            "    Power Source: Battery",
            "[x] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
            "  ! could not change: /usr/bin/pmset -b lowpowermode 2 exit 1: pmset: lowpowermode 2 is not supported on this system",
            "Sync",
            "[ ] iCloud Drive  off",
            "[ ] iCloud Photos  state unknown: launchctl print exit 1: Could not connect to launchd",
            "[ ] OneDrive  not running",
            "  ! could not change: com.microsoft.OneDrive is not installed",
            "  ! settings could not be saved: You don't have permission to save the file",
        ])
    }

    func testTogglesCarryTheirKeys() {
        let keys = Formatting.settingsRows(allOff).compactMap { row -> SettingKey? in
            if case .toggle(let key, _) = row.kind {
                return key
            }
            return nil
        }
        XCTAssertEqual(keys, [.awake(.idleSleep), .awake(.displaySleep), .awake(.diskIdle), .lidClosedAwake,
                              .energyMode(.automatic), .energyMode(.lowPower), .energyMode(.highPower),
                              .sync(.iCloudDrive), .sync(.iCloudPhotos), .sync(.oneDrive)])
    }

    func testEmptySnapshotRendersEverythingOffWithTheNotReadNote() {
        let rows = labels(SettingsSnapshot())
        XCTAssertEqual(rows[4], "[ ] Stay awake with the lid closed")
        XCTAssertEqual(rows[6], "    could not read pmset: not read yet")
        XCTAssertEqual(energyRows(SettingsSnapshot()), [
            "Energy Mode",
            "    Power Source: unknown",
            "[ ] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "    could not read energy mode: not read yet",
        ])
        XCTAssertEqual(rows.suffix(3), ["[ ] iCloud Drive  off", "[ ] iCloud Photos  off", "[ ] OneDrive  not running"])
    }

    // MARK: Energy Mode (ticket 11)

    /// Manuel's Mac on 2026-09-22: on battery with powermode 1, on AC with powermode 2.
    func testEnergyModeMarksTheValueReadForTheCurrentSource() {
        XCTAssertEqual(energyRows(snapshot(energy: .battery, 1)), [
            "Energy Mode",
            "    Power Source: Battery",
            "[ ] Automatic  powermode 0",
            "[x] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
        ])
        XCTAssertEqual(energyRows(snapshot(energy: .ac, 2)), [
            "Energy Mode",
            "    Power Source: AC",
            "[ ] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "[x] High Power  powermode 2",
        ])
    }

    func testEnergyModeWithoutALineMarksAutomaticAndSaysSo() {
        XCTAssertEqual(energyRows(snapshot(energy: .battery, nil)), [
            "Energy Mode",
            "    Power Source: Battery",
            "[x] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
            "    pmset lists no powermode for Battery Power, read as Automatic",
        ])
    }

    func testEnergyModeWithAnUnknownValueMarksNothingAndSaysSo() {
        XCTAssertEqual(energyRows(snapshot(energy: .ac, 7)), [
            "Energy Mode",
            "    Power Source: AC",
            "[ ] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
            "    powermode 7 is not a known energy mode",
        ])
    }

    /// High Power appears only when the source can set it, or when it is set already.
    func testHighPowerRowFollowsTheCapabilityOrTheSetValue() {
        XCTAssertEqual(energyRows(snapshot(energy: .battery, 1, highPower: false)), [
            "Energy Mode",
            "    Power Source: Battery",
            "[ ] Automatic  powermode 0",
            "[x] Low Power  powermode 1",
        ])
        XCTAssertEqual(energyRows(snapshot(energy: .ac, 2, highPower: false)), [
            "Energy Mode",
            "    Power Source: AC",
            "[ ] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "[x] High Power  powermode 2",
        ])
    }

    func testUnreadableEnergyModeMarksNothingAndNamesTheReason() {
        var snapshot = allOff
        snapshot.energyMode = .unknown("pmset -g cap exit 1: x")
        XCTAssertEqual(energyRows(snapshot), [
            "Energy Mode",
            "    Power Source: unknown",
            "[ ] Automatic  powermode 0",
            "[ ] Low Power  powermode 1",
            "    could not read energy mode: pmset -g cap exit 1: x",
        ])
    }

    func testEnergyModeWarningSitsUnderItsOwnRow() {
        var snapshot = self.snapshot(energy: .battery, 1)
        snapshot.lastError[.energyMode(.highPower)] = "pmset accepted lowpowermode 2 but reports powermode 1 for Battery Power"
        XCTAssertEqual(energyRows(snapshot), [
            "Energy Mode",
            "    Power Source: Battery",
            "[ ] Automatic  powermode 0",
            "[x] Low Power  powermode 1",
            "[ ] High Power  powermode 2",
            "  ! could not change: pmset accepted lowpowermode 2 but reports powermode 1 for Battery Power",
        ])

        var refused = allOff
        refused.energyMode = .unknown("pmset -g cap exit 1: x")
        refused.lastError[.energyMode(.automatic)] = "not written while the power source could not be read"
        XCTAssertEqual(energyRows(refused), [
            "Energy Mode",
            "    Power Source: unknown",
            "[ ] Automatic  powermode 0",
            "  ! could not change: not written while the power source could not be read",
            "[ ] Low Power  powermode 1",
            "    could not read energy mode: pmset -g cap exit 1: x",
        ])
    }

    func testNoDashesInRows() {
        var snapshot = allOff
        snapshot.sleepDisabled = .unknown("x")
        snapshot.energyMode = .unknown("u")
        snapshot.lastError = [.lidClosedAwake: "y", .awake(.idleSleep): "z", .sync(.iCloudDrive): "w",
                              .energyMode(.lowPower): "t"]
        snapshot.storeError = "v"
        for candidate in [allOff, snapshot, SettingsSnapshot(), self.snapshot(energy: .ac, nil), self.snapshot(energy: .battery, 7)] {
            let text = Formatting.settingsRows(candidate).map { $0.label + $0.detail }.joined()
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(text)")
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(text)")
        }
    }
}
