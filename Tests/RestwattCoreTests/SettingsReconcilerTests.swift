import XCTest
@testable import RestwattCore

/// Every row of the decision table in the spec (section 3.4), one test each.
final class SettingsReconcilerTests: XCTestCase {
    private let none = StoredSettings()
    private let armed = StoredSettings(lidClosedAwakeArmedByRestwatt: true)

    /// A snapshot as the menu renders it: `sleepDisabled` decides the lid toggle, `awake`
    /// and `sync` the other two kinds.
    private func snapshot(sleepDisabled: Observation<Bool> = .known(false), armed: Bool = false,
                          awake: [AwakeAssertion: Bool] = [:], remembered: [AwakeAssertion: Bool] = [:],
                          sync: [SyncService: ServiceState] = [:]) -> SettingsSnapshot {
        SettingsSnapshot(awake: awake, sleepDisabled: sleepDisabled, armedByRestwatt: armed,
                         rememberedAwake: remembered, sync: sync)
    }

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
            SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: snapshot(sleepDisabled: .known(false))),
            SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: snapshot(sleepDisabled: .known(true))),
            SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: snapshot(sleepDisabled: .unknown("x"), armed: true)),
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

    // MARK: Settle (the one rule launch and a finished click share)

    func testSettleDropsAnArmedRecordOnlyAgainstAnObservedZero() {
        XCTAssertEqual(SettingsReconciler.settleActions(armed: true, observedSleepDisabled: .known(false)), [.setArmed(false)])
        XCTAssertEqual(SettingsReconciler.settleActions(armed: true, observedSleepDisabled: .known(true)), [])
        XCTAssertEqual(SettingsReconciler.settleActions(armed: true, observedSleepDisabled: .unknown("x")), [])
        for observed in [Observation.known(true), .known(false), .unknown("x")] {
            XCTAssertEqual(SettingsReconciler.settleActions(armed: false, observedSleepDisabled: observed), [])
        }
    }

    // MARK: Toggles

    func testAwakeToggleAcquiresOrReleases() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.idleSleep), snapshot: snapshot()), [.acquire(.idleSleep)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.idleSleep), snapshot: snapshot(awake: [.idleSleep: true])), [.release(.idleSleep)])
    }

    /// Ticket 7 (c): an assertion that is remembered but not held (IOKit refused it) shows
    /// off; the click on it clears the choice instead of trying again.
    func testAwakeToggleOnARememberedButRefusedAssertionReleases() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.idleSleep),
                                                        snapshot: snapshot(awake: [.idleSleep: false], remembered: [.idleSleep: true])),
                       [.release(.idleSleep)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.idleSleep),
                                                        snapshot: snapshot(remembered: [.idleSleep: false])),
                       [.acquire(.idleSleep)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .awake(.displaySleep),
                                                        snapshot: snapshot(remembered: [.idleSleep: true])),
                       [.acquire(.displaySleep)], "another assertion's choice does not count")
    }

    func testLidClosedToggleWritesTheProfileWithTheArmedFlag() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: snapshot(sleepDisabled: .known(false))),
                       [.writePmset(.awake, thenArmed: true)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: snapshot(sleepDisabled: .known(true))),
                       [.writePmset(.saver, thenArmed: false)])
    }

    /// Turning off a `SleepDisabled 1` that was set outside Restwatt writes the saver profile
    /// too: the user clicked, the checkmark showed on.
    func testLidClosedToggleOffWritesSaverRegardlessOfWhoSetIt() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: snapshot(sleepDisabled: .known(true), armed: false)),
                       [.writePmset(.saver, thenArmed: false)])
    }

    /// Ticket 6: with `SleepDisabled` unreadable the checkmark shows off. A click must not
    /// write the awake profile blind (it could never be switched off from the menu again);
    /// it is refused with the reason. Off is the safe direction and stays possible: when
    /// Restwatt armed the setting, the click writes the saver profile.
    func testLidClosedToggleWithUnreadablePmsetRefusesTheAwakeProfile() {
        let unknown = snapshot(sleepDisabled: .unknown("pmset -g exit 1: pmset: could not read settings"))
        XCTAssertFalse(unknown.isOn(.lidClosedAwake))
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: unknown),
                       [.refuseLidClosedWrite("pmset -g exit 1: pmset: could not read settings")])
    }

    func testLidClosedToggleWithUnreadablePmsetWhileArmedWritesSaver() {
        let unknown = snapshot(sleepDisabled: .unknown("pmset -g printed no settings"), armed: true)
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .lidClosedAwake, snapshot: unknown),
                       [.writePmset(.saver, thenArmed: false)])
    }

    // MARK: Energy Mode (ticket 11)

    private func energy(_ source: PowerSource, _ rawValue: Int?, highPower: Bool = true) -> SettingsSnapshot {
        SettingsSnapshot(energyMode: .known(EnergyModeObservation(source: source, rawValue: rawValue, highPowerCapable: highPower)))
    }

    func testEnergyModeClickOnTheMarkedRowWritesNothing() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.lowPower), snapshot: energy(.battery, 1)), [])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.highPower), snapshot: energy(.ac, 2)), [])
    }

    func testEnergyModeClickWritesTheModeForTheObservedSource() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.automatic), snapshot: energy(.battery, 1)),
                       [.writeEnergyMode(.automatic, .battery)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.highPower), snapshot: energy(.battery, 1)),
                       [.writeEnergyMode(.highPower, .battery)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.lowPower), snapshot: energy(.ac, 2)),
                       [.writeEnergyMode(.lowPower, .ac)])
    }

    /// Without a readable source there is no flag to write with; the click is refused and
    /// the reason travels to the row.
    func testEnergyModeClickWithUnknownSourceIsRefusedWithTheReason() {
        let unknown = SettingsSnapshot(energyMode: .unknown("pmset -g cap exit 1: pmset: could not read capabilities"))
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.automatic), snapshot: unknown),
                       [.refuseEnergyModeWrite(.automatic, "pmset -g cap exit 1: pmset: could not read capabilities")])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.lowPower), snapshot: SettingsSnapshot()),
                       [.refuseEnergyModeWrite(.lowPower, "not read yet")])
    }

    /// A missing `powermode` line reads as Automatic: the Automatic row is the marked one.
    func testEnergyModeWithoutALineTreatsAutomaticAsMarked() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.automatic), snapshot: energy(.battery, nil)), [])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(.lowPower), snapshot: energy(.battery, nil)),
                       [.writeEnergyMode(.lowPower, .battery)])
    }

    func testEnergyModeWithAnUnknownValueMarksNothingAndEveryClickWrites() {
        for mode in EnergyMode.allCases {
            XCTAssertEqual(SettingsReconciler.toggleActions(key: .energyMode(mode), snapshot: energy(.battery, 7)),
                           [.writeEnergyMode(mode, .battery)])
        }
    }

    func testSyncTogglesForLaunchdServicesAndOneDrive() {
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.iCloudDrive), snapshot: snapshot(sync: [.iCloudDrive: .off])), [.bootstrapAndKickstart(.iCloudDrive)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.iCloudPhotos), snapshot: snapshot(sync: [.iCloudPhotos: .loadedIdle])), [.bootout(.iCloudPhotos)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.oneDrive), snapshot: snapshot()), [.launchApplication(.oneDrive)])
        XCTAssertEqual(SettingsReconciler.toggleActions(key: .sync(.oneDrive), snapshot: snapshot(sync: [.oneDrive: .running])), [.quitApplication(.oneDrive)])
    }
}
