import XCTest
@testable import RestwattCore

/// Every row of the decision table in the spec (section 3.4), one test each.
final class SettingsReconcilerTests: XCTestCase {
    private let none = StoredSettings()
    private let armed = StoredSettings(lidClosedAwakeArmedByRestwatt: true)

    // MARK: Launch

    func testLaunchNotArmedAndNotDisabledDoesNothing() {
        XCTAssertEqual(SettingsReconciler.launchActions(stored: none, observedSleepDisabled: .known(false)), [])
    }

    /// Manuel's Mac today: Wach-AN set `disablesleep 1`, the app has never armed anything.
    /// The first launch must not write pmset.
    func testFirstLaunchWithForeignSleepDisabledWritesNothing() {
        let actions = SettingsReconciler.launchActions(stored: none, observedSleepDisabled: .known(true))
        XCTAssertEqual(actions, [])
    }

    func testCrashGapRestoresSaverProfileAtLaunch() {
        XCTAssertEqual(SettingsReconciler.launchActions(stored: armed, observedSleepDisabled: .known(true)),
                       [.writePmset(.saver, thenArmed: false)])
    }

    func testLaunchArmedButAlreadyResetOnlyDisarms() {
        XCTAssertEqual(SettingsReconciler.launchActions(stored: armed, observedSleepDisabled: .known(false)),
                       [.setArmed(false)])
    }

    func testLaunchWithUnreadablePmsetWritesNothingAndStaysArmed() {
        XCTAssertEqual(SettingsReconciler.launchActions(stored: armed, observedSleepDisabled: .unknown("pmset -g exit 1")), [])
        XCTAssertEqual(SettingsReconciler.launchActions(stored: none, observedSleepDisabled: .unknown("pmset -g exit 1")), [])
    }

    func testLaunchReacquiresStoredAssertionsInDeclarationOrder() {
        let stored = StoredSettings(awake: [.diskIdle: true, .idleSleep: true, .displaySleep: false])
        XCTAssertEqual(SettingsReconciler.launchActions(stored: stored, observedSleepDisabled: .known(false)),
                       [.acquire(.idleSleep), .acquire(.diskIdle)])
    }

    /// The crash-gap reset never depends on a separate `setArmed` step that a failed
    /// predecessor could starve: every list carries the armed flag inside the write itself.
    func testNoListEverEmitsWritePmsetFollowedBySetArmed() {
        let lists: [[SettingsAction]] = [
            SettingsReconciler.launchActions(stored: StoredSettings(awake: [.idleSleep: true, .displaySleep: true, .diskIdle: true], lidClosedAwakeArmedByRestwatt: true), observedSleepDisabled: .known(true)),
            SettingsReconciler.quitActions(armed: true, observedSleepDisabled: .known(true)),
            SettingsReconciler.quitActions(armed: true, observedSleepDisabled: .unknown("x")),
            SettingsReconciler.toggleActions(key: .lidClosedAwake, currentlyOn: false),
            SettingsReconciler.toggleActions(key: .lidClosedAwake, currentlyOn: true),
        ]
        for actions in lists {
            for (index, action) in actions.enumerated() {
                guard case .writePmset = action else { continue }
                XCTAssertEqual(index, actions.count - 1, "a pmset write is the last step, nothing depends on it: \(actions)")
            }
        }
    }

    func testLaunchAssertionsComeBeforeThePmsetReconcile() {
        let stored = StoredSettings(awake: [.displaySleep: true], lidClosedAwakeArmedByRestwatt: true)
        XCTAssertEqual(SettingsReconciler.launchActions(stored: stored, observedSleepDisabled: .known(true)),
                       [.acquire(.displaySleep), .writePmset(.saver, thenArmed: false)])
    }

    // MARK: Quit

    func testQuitArmedAndDisabledWritesSaver() {
        XCTAssertEqual(SettingsReconciler.quitActions(armed: true, observedSleepDisabled: .known(true)),
                       [.writePmset(.saver, thenArmed: false)])
    }

    func testQuitArmedAndUnknownWritesSaver() {
        XCTAssertEqual(SettingsReconciler.quitActions(armed: true, observedSleepDisabled: .unknown("x")),
                       [.writePmset(.saver, thenArmed: false)])
    }

    func testQuitArmedButAlreadyResetOnlyDisarms() {
        XCTAssertEqual(SettingsReconciler.quitActions(armed: true, observedSleepDisabled: .known(false)), [.setArmed(false)])
    }

    func testQuitNotArmedDoesNothingWhateverIsObserved() {
        for observed in [Observation.known(true), .known(false), .unknown("x")] {
            XCTAssertEqual(SettingsReconciler.quitActions(armed: false, observedSleepDisabled: observed), [])
        }
    }

    // MARK: Toggles

    func testAwakeToggleAcquiresOrReleases() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.idleSleep), currentlyOn: false), [.acquire(.idleSleep)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.idleSleep), currentlyOn: true), [.release(.idleSleep)])
    }

    func testLidClosedToggleWritesTheProfileThenArms() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, currentlyOn: false),
                       [.writePmset(.awake, thenArmed: true)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, currentlyOn: true),
                       [.writePmset(.saver, thenArmed: false)])
    }

    /// Turning off a `SleepDisabled 1` that was set outside Restwatt writes the saver profile
    /// too: the user clicked, the checkmark showed on.
    func testLidClosedToggleOffWritesSaverRegardlessOfWhoSetIt() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, currentlyOn: true).first, .writePmset(.saver, thenArmed: false))
    }

    func testSyncTogglesForLaunchdServicesAndOneDrive() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.iCloudDrive), currentlyOn: false), [.bootstrapAndKickstart(.iCloudDrive)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.iCloudPhotos), currentlyOn: true), [.bootout(.iCloudPhotos)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.oneDrive), currentlyOn: false), [.launchApplication(.oneDrive)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.oneDrive), currentlyOn: true), [.quitApplication(.oneDrive)])
    }
}
