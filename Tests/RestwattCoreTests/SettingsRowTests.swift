import XCTest
@testable import RestwattCore

/// Pins the labels and order of the settings section of the click menu.
final class SettingsRowTests: XCTestCase {
    private let allOff = SettingsSnapshot(
        awake: [.idleSleep: false, .displaySleep: false, .diskIdle: false],
        sleepDisabled: .known(false),
        sync: [.iCloudDrive: .off, .iCloudPhotos: .off, .oneDrive: .off])

    private func labels(_ snapshot: SettingsSnapshot) -> [String] {
        Formatting.settingsRows(snapshot).map { row in
            switch row.kind {
            case .heading: return row.label
            case .toggle(_, let isOn): return (isOn ? "[x] " : "[ ] ") + row.label + (row.detail.isEmpty ? "" : "  " + row.detail)
            case .note: return "    " + row.label
            case .warning: return "  ! " + row.label
            }
        }
    }

    func testEverythingOff() {
        XCTAssertEqual(labels(allOff), [
            "Power",
            "[ ] Keep awake",
            "[ ] Keep display awake",
            "[ ] Keep disk awake",
            "[ ] Stay awake with the lid closed",
            "    system-wide, needs administrator, restored when Restwatt quits",
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
        XCTAssertEqual(labels(snapshot), [
            "Power",
            "[x] Keep awake",
            "[ ] Keep display awake",
            "[ ] Keep disk awake",
            "[x] Stay awake with the lid closed",
            "    system-wide, needs administrator, restored when Restwatt quits",
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
        XCTAssertEqual(rows[7], "Sync")
    }

    func testUnreadablePmsetShowsOffWithTheReason() {
        var snapshot = allOff
        snapshot.sleepDisabled = .unknown("pmset -g exit 1: pmset: could not read settings")
        let rows = labels(snapshot)
        XCTAssertEqual(rows[4], "[ ] Stay awake with the lid closed")
        XCTAssertEqual(rows[6], "    could not read pmset: pmset -g exit 1: pmset: could not read settings")
    }

    func testWarningsSitUnderTheirOwnToggle() {
        var snapshot = allOff
        snapshot.lastError[.awake(.diskIdle)] = "IOPMAssertionCreateWithName returned e00002bc"
        snapshot.lastError[.sync(.oneDrive)] = "com.microsoft.OneDrive is not installed"
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
                              .sync(.iCloudDrive), .sync(.iCloudPhotos), .sync(.oneDrive)])
    }

    func testEmptySnapshotRendersEverythingOffWithTheNotReadNote() {
        let rows = labels(SettingsSnapshot())
        XCTAssertEqual(rows[4], "[ ] Stay awake with the lid closed")
        XCTAssertEqual(rows[6], "    could not read pmset: not read yet")
        XCTAssertEqual(rows.suffix(3), ["[ ] iCloud Drive  off", "[ ] iCloud Photos  off", "[ ] OneDrive  not running"])
    }

    func testNoDashesInRows() {
        var snapshot = allOff
        snapshot.sleepDisabled = .unknown("x")
        snapshot.lastError = [.lidClosedAwake: "y", .awake(.idleSleep): "z", .sync(.iCloudDrive): "w"]
        snapshot.storeError = "v"
        for candidate in [allOff, snapshot, SettingsSnapshot()] {
            let text = Formatting.settingsRows(candidate).map { $0.label + $0.detail }.joined()
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(text)")
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(text)")
        }
    }
}
