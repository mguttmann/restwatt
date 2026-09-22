import XCTest
@testable import RestwattCore

/// The coordinator against a simulated system: every call is recorded in order, no process
/// starts, nothing is written outside memory.
final class SettingsCoordinatorTests: XCTestCase {
    private var store = MemorySettingsStore()
    private var assertions = FakeAssertions()
    private var runner = ScriptedCommandRunner()
    private var applications = FakeApplications()

    private func makeCoordinator() -> SettingsCoordinator {
        SettingsCoordinator(store: store, assertions: assertions, commands: runner,
                            applications: applications, uid: testUID)
    }

    private var pmsetWriteCalls: [CommandVector] {
        runner.calls.filter { $0.executable == SystemCommands.sudo || $0.executable == SystemCommands.osascript }
    }

    // MARK: Assertions

    func testLaunchReacquiresTheStoredAssertionOnce() {
        store.stored = StoredSettings(awake: [.idleSleep: true])
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(assertions.acquireCalls.map(\.assertion), [.idleSleep])
        XCTAssertEqual(assertions.acquireCalls.first?.name, "Restwatt: Keep awake")
        XCTAssertEqual(coordinator.snapshot.awake, [.idleSleep: true, .displaySleep: false, .diskIdle: false])
        XCTAssertEqual(store.saveCount, 0, "nothing changed, nothing written")
    }

    func testToggleOnAcquiresAndStoresToggleOffReleases() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.awake(.displaySleep))
        XCTAssertTrue(coordinator.snapshot.isOn(.awake(.displaySleep)))
        XCTAssertEqual(assertions.held.values.map { $0 }, [.displaySleep])
        XCTAssertEqual(store.stored, StoredSettings(awake: [.displaySleep: true]))

        coordinator.toggle(.awake(.displaySleep))
        XCTAssertFalse(coordinator.snapshot.isOn(.awake(.displaySleep)))
        XCTAssertEqual(assertions.releaseCalls.count, 1)
        XCTAssertTrue(assertions.held.isEmpty)
        XCTAssertEqual(store.stored, StoredSettings(awake: [.displaySleep: false]))
    }

    func testFailedAcquireLeavesToggleOffWithReasonAndIsNotStoredAsOn() {
        assertions.failing = [.diskIdle]
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.awake(.diskIdle))
        XCTAssertFalse(coordinator.snapshot.isOn(.awake(.diskIdle)))
        XCTAssertEqual(coordinator.snapshot.lastError[.awake(.diskIdle)], "IOPMAssertionCreateWithName returned e00002bc")
        XCTAssertEqual(store.saveCount, 0)

        assertions.failing = []
        coordinator.toggle(.awake(.diskIdle))
        XCTAssertTrue(coordinator.snapshot.isOn(.awake(.diskIdle)))
        XCTAssertNil(coordinator.snapshot.lastError[.awake(.diskIdle)], "cleared on success")
    }

    // MARK: Lid closed, passwordless machine

    func testLidClosedOnUsesSudoOnlyAndArms() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, [SystemCommands.sudoNonInteractive(SystemCommands.pmsetAwakeProfile[0])])
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetAwakeProfile)
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(true))
        XCTAssertTrue(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, true)
        // After the action the state is re-read: pmset -g, then the two launchd services.
        XCTAssertEqual(Array(runner.calls.suffix(3)), [
            SystemCommands.pmsetRead,
            SystemCommands.launchctlPrint(SyncService.iCloudDrive.rawValue, uid: testUID),
            SystemCommands.launchctlPrint(SyncService.iCloudPhotos.rawValue, uid: testUID),
        ])
    }

    func testLidClosedOffWritesTheFourSaverCallsInScriptOrder() {
        runner.sleepDisabled = true
        store.stored = StoredSettings(lidClosedAwakeArmedByRestwatt: false)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertTrue(coordinator.snapshot.isOn(.lidClosedAwake), "foreign SleepDisabled 1 shows on")
        XCTAssertEqual(runner.privilegedPmsetVectors, [], "launch wrote nothing")

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, SystemCommands.pmsetSaverProfile.map(SystemCommands.sudoNonInteractive))
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
    }

    // MARK: Lid closed, other Macs

    func testLidClosedOnFallsBackToOneAdministratorDialog() throws {
        runner.sudoPasswordless = false
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, [
            SystemCommands.sudoNonInteractive(SystemCommands.pmsetAwakeProfile[0]),
            try SystemCommands.administratorScript(SystemCommands.pmsetAwakeProfile),
        ])
        XCTAssertTrue(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt)
        XCTAssertNil(coordinator.snapshot.lastError[.lidClosedAwake])
    }

    func testLidClosedOffStopsSudoAtTheFirstRefusalThenOneDialogWithAllFour() throws {
        runner.sudoPasswordless = false
        runner.sleepDisabled = true
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, [
            SystemCommands.sudoNonInteractive(SystemCommands.pmsetSaverProfile[0]),
            try SystemCommands.administratorScript(SystemCommands.pmsetSaverProfile),
        ])
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
    }

    /// Ticket 6 (M1): the armed record is write-ahead, so a cancelled dialog leaves a file
    /// behind: first armed (before root was asked), then, settled against the observed
    /// `SleepDisabled 0` after the click, armed=false again. The Mac ends unarmed and unset.
    func testFailedPrivilegeLeavesToggleOffWithReason() throws {
        runner.sudoPasswordless = false
        runner.administratorDialogAccepted = false
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        var armedAtSave: [Bool] = []
        store.onSave = { armedAtSave.append($0.lidClosedAwakeArmedByRestwatt) }

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls.count, 2, "one sudo attempt, one dialog, nothing more")
        XCTAssertEqual(runner.privilegedPmsetVectors, [])
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake], "execution error: User canceled. (-128)")
        XCTAssertEqual(armedAtSave, [true, false], "armed before the dialog, settled to unarmed after it")
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }

    // MARK: Lid closed, write-ahead record (ticket 6, M1)

    /// The record reaches the file BEFORE root touches pmset: at the moment of the save no
    /// privileged vector has run yet.
    func testLidClosedOnPersistsArmedBeforeThePrivilegedWrite() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        var privilegedCallsAtSave: [Int] = []
        var armedAtSave: [Bool] = []
        store.onSave = { [runner] settings in
            privilegedCallsAtSave.append(runner.privilegedPmsetVectors.count)
            armedAtSave.append(settings.lidClosedAwakeArmedByRestwatt)
        }

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(armedAtSave, [true], "one save, armed, and nothing else changed after the write")
        XCTAssertEqual(privilegedCallsAtSave, [0], "the record was on disk before pmset ran")
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetAwakeProfile)
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, true)
    }

    /// Fail-closed: when the record cannot be written, root is never asked; the menu says
    /// why under the toggle and in the store line, the Mac stays as it was.
    func testLidClosedOnWithAFailingStoreWritesNoPmset() {
        store.saveError = "You don't have permission to save the file"
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, [], "no sudo, no dialog")
        XCTAssertEqual(runner.privilegedPmsetVectors, [])
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake],
                       "not written, the settings file could not be saved: You don't have permission to save the file")
        XCTAssertEqual(coordinator.snapshot.storeError, "You don't have permission to save the file")
        XCTAssertEqual(store.saveCount, 1, "one attempt, then nothing more to save")
        XCTAssertNil(store.stored)
    }

    /// Turning off is write-behind on purpose: the record stays armed until the saver profile
    /// has landed, so a crash in between is closed at the next launch.
    func testLidClosedOffKeepsTheRecordUntilTheSaverProfileLanded() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        coordinator.toggle(.lidClosedAwake)
        var armedAtSave: [Bool] = []
        var privilegedCallsAtSave: [Int] = []
        store.onSave = { [runner] settings in
            armedAtSave.append(settings.lidClosedAwakeArmedByRestwatt)
            privilegedCallsAtSave.append(runner.privilegedPmsetVectors.count)
        }

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(armedAtSave, [false])
        XCTAssertEqual(privilegedCallsAtSave, [1 + SystemCommands.pmsetSaverProfile.count],
                       "disarmed only after all four saver calls ran")
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }

    // MARK: Lid closed, launch reconcile, all four combinations (ticket 6)

    func testLaunchArmedAndObservedOneIsOwnedAndTakenBack() {
        runner.sleepDisabled = true
        store.stored = StoredSettings(lidClosedAwakeArmedByRestwatt: true)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }

    /// The write-ahead record survived but the write never landed (crash between the save
    /// and pmset, or a refused dialog followed by a kill): disarm quietly, write nothing.
    func testLaunchArmedAndObservedZeroDisarmsQuietly() {
        runner.sleepDisabled = false
        store.stored = StoredSettings(lidClosedAwakeArmedByRestwatt: true)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(pmsetWriteCalls, [], "no sudo, no dialog")
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertNil(coordinator.snapshot.lastError[.lidClosedAwake])
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testLaunchNotArmedAndObservedOneIsLeftAloneAsSetOutside() {
        runner.sleepDisabled = true
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(pmsetWriteCalls, [])
        XCTAssertTrue(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertTrue(Formatting.settingsRows(coordinator.snapshot).contains { $0.label == Formatting.setOutsideRestwattNote })
        XCTAssertEqual(store.saveCount, 0)
    }

    func testLaunchNotArmedAndObservedZeroDoesNothing() {
        runner.sleepDisabled = false
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(pmsetWriteCalls, [])
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(store.saveCount, 0)
    }

    // MARK: Privileged path, per-vector outcomes (ticket 6, M2)

    /// A pmset key the hardware refuses on a passwordless Mac: the profile stops at that
    /// vector, the row names the vector and pmset's stderr, no dialog opens, the vector
    /// before it is not run again.
    func testCommandFailureStopsTheProfileAndOpensNoDialog() {
        runner.sleepDisabled = true
        runner.pmsetRefusedKeys = ["hibernatemode"]
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, [
            SystemCommands.sudoNonInteractive(SystemCommands.pmsetSaverProfile[0]),
            SystemCommands.sudoNonInteractive(SystemCommands.pmsetSaverProfile[1]),
        ], "sudo ran the first two vectors, the second failed, nothing more")
        XCTAssertEqual(runner.privilegedPmsetVectors, [SystemCommands.pmsetSaverProfile[0]], "only the first landed")
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake],
                       "/usr/bin/pmset -b displaysleep 2 sleep 10 disksleep 10 hibernatemode 3 standby 1 exit 1: "
                       + "pmset: hibernatemode is not supported on this system")
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false), "disablesleep 0 did land")
    }

    /// sudo grants the first two saver vectors and denies the third: the dialog carries only
    /// the two remaining ones, and every vector runs exactly once, in script order.
    func testSudoDenialMidProfileOpensOneDialogWithTheRemainingVectorsOnly() throws {
        runner.sleepDisabled = true
        runner.sudoDeniesAfter = 2
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        let saver = SystemCommands.pmsetSaverProfile
        XCTAssertEqual(pmsetWriteCalls, [
            SystemCommands.sudoNonInteractive(saver[0]),
            SystemCommands.sudoNonInteractive(saver[1]),
            SystemCommands.sudoNonInteractive(saver[2]),
            try SystemCommands.administratorScript(Array(saver[2...])),
        ])
        XCTAssertEqual(runner.privilegedPmsetVectors, saver, "each vector once, in order")
        XCTAssertNil(coordinator.snapshot.lastError[.lidClosedAwake])
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
    }

    /// Tester hardening (ticket 6, M1+M2 together, the brief's headline case): turning ON on a
    /// passwordless Mac whose hardware refuses a key of the awake profile. The write-ahead
    /// record went to disk first, sudo ran the vector as root, pmset refused it: no dialog
    /// opens, the row names the vector and pmset's stderr, and the record is settled back to
    /// unarmed against the observed `SleepDisabled 0`, so no file claims armed for a write
    /// that never landed.
    func testAwakeProfileCommandFailureOnAPasswordlessMacOpensNoDialogAndSettlesTheRecord() {
        runner.pmsetRefusedKeys = ["disablesleep"]
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        var armedAtSave: [Bool] = []
        store.onSave = { armedAtSave.append($0.lidClosedAwakeArmedByRestwatt) }

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, SystemCommands.pmsetAwakeProfile.map(SystemCommands.sudoNonInteractive),
                       "sudo only, no osascript")
        XCTAssertEqual(runner.privilegedPmsetVectors, [], "nothing landed")
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(armedAtSave, [true, false], "write-ahead record, then settled against the observed 0")
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake],
                       "\(SystemCommands.pmsetAwakeProfile[0].commandLine) exit 1: pmset: disablesleep is not supported on this system")
    }

    /// A command failure inside the dialog is reported with osascript's text; the checkmark
    /// follows the observation.
    func testCommandFailureInsideTheDialogIsReported() {
        runner.sudoPasswordless = false
        runner.pmsetRefusedKeys = ["disablesleep"]
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls.count, 2)
        XCTAssertEqual(runner.privilegedPmsetVectors, [])
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake],
                       "execution error: pmset: disablesleep is not supported on this system (1)")
    }

    // MARK: Quit with a refused dialog (ticket 6)

    /// Restwatt armed the setting; at quit the dialog is refused. The record must stay armed
    /// (the next launch closes the gap) and no file may say armed=false.
    func testWillTerminateWithRefusedDialogStaysArmed() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        coordinator.toggle(.lidClosedAwake)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, true)
        runner.sudoPasswordless = false
        runner.administratorDialogAccepted = false
        runner.privilegedPmsetVectors.removeAll()
        var armedAtSave: [Bool] = []
        store.onSave = { armedAtSave.append($0.lidClosedAwakeArmedByRestwatt) }

        coordinator.willTerminate()

        XCTAssertEqual(runner.privilegedPmsetVectors, [], "nothing landed")
        XCTAssertEqual(runner.sleepDisabled, true, "the Mac is still awake")
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, true)
        XCTAssertEqual(armedAtSave, [], "no save at all, so no file with armed=false")
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake], "execution error: User canceled. (-128)")
    }

    func testFailedPrivilegeWithoutTheSleepDisabledLineStillShowsOff() {
        runner.sudoPasswordless = false
        runner.administratorDialogAccepted = false
        runner.pmsetPrintsLineWhenZero = false
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        coordinator.toggle(.lidClosedAwake)
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertNotNil(coordinator.snapshot.lastError[.lidClosedAwake])
    }

    // MARK: Reconcile at launch and quit

    func testFirstLaunchOnManuelsMacWritesNoPmset() {
        runner.sleepDisabled = true
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(pmsetWriteCalls, [])
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(true))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(store.saveCount, 0, "no settings file appears")
    }

    func testCrashGapIsClosedAtLaunch() {
        runner.sleepDisabled = true
        store.stored = StoredSettings(lidClosedAwakeArmedByRestwatt: true)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }

    /// Tester hardening (AC4b): the crash gap is a safety action. It must be closed even when
    /// an unrelated action earlier in the launch list fails, here a stored assertion that IOKit
    /// refuses to re-acquire. Otherwise a refused IOKit call leaves the Mac unable to sleep.
    func testCrashGapIsClosedEvenWhenAnAssertionCannotBeReacquired() {
        runner.sleepDisabled = true
        assertions.failing = [.displaySleep]
        store.stored = StoredSettings(awake: [.displaySleep: true, .diskIdle: true],
                                      lidClosedAwakeArmedByRestwatt: true)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(coordinator.snapshot.lastError[.awake(.displaySleep)],
                       "IOPMAssertionCreateWithName returned e00002bc")
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile,
                       "the saver profile must be written although an assertion failed")
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
        XCTAssertTrue(coordinator.snapshot.isOn(.awake(.diskIdle)),
                      "the other remembered assertion is still re-acquired")
    }

    /// Ticket 6: a remembered assertion the system refuses at launch keeps the stored choice.
    /// The checkmark shows off with the reason, nothing is written, and the next launch tries
    /// again; the other toggles are untouched by that failure.
    func testRefusedStoredAssertionAtLaunchKeepsTheChoiceAndLeavesTheOthersAlone() {
        assertions.failing = [.idleSleep]
        store.stored = StoredSettings(awake: [.idleSleep: true, .displaySleep: true])
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertFalse(coordinator.snapshot.isOn(.awake(.idleSleep)))
        XCTAssertEqual(coordinator.snapshot.lastError[.awake(.idleSleep)], "IOPMAssertionCreateWithName returned e00002bc")
        XCTAssertTrue(coordinator.snapshot.isOn(.awake(.displaySleep)))
        XCTAssertNil(coordinator.snapshot.lastError[.awake(.displaySleep)])
        XCTAssertEqual(store.stored, StoredSettings(awake: [.idleSleep: true, .displaySleep: true]), "the choice is kept")
        XCTAssertEqual(store.saveCount, 0)

        // Next launch, IOKit cooperates: the kept choice is re-acquired without a click.
        assertions.failing = []
        let next = makeCoordinator()
        next.applyStoredAtLaunch()
        XCTAssertTrue(next.snapshot.isOn(.awake(.idleSleep)))
        XCTAssertNil(next.snapshot.lastError[.awake(.idleSleep)])
    }

    func testCrashGapWriteRefusedStaysArmedForTheNextAttempt() {
        runner.sleepDisabled = true
        runner.sudoPasswordless = false
        runner.administratorDialogAccepted = false
        store.stored = StoredSettings(lidClosedAwakeArmedByRestwatt: true)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, true)
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt)
        XCTAssertNotNil(coordinator.snapshot.lastError[.lidClosedAwake])

        // The quit reconcile tries again; this time the dialog is accepted.
        runner.administratorDialogAccepted = true
        coordinator.willTerminate()
        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }

    func testWillTerminateArmedWritesSaverAndDisarms() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        coordinator.toggle(.lidClosedAwake)
        runner.calls.removeAll()
        runner.privilegedPmsetVectors.removeAll()

        coordinator.willTerminate()

        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(runner.sleepDisabled, false)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }

    func testWillTerminateNotArmedRunsNothing() {
        runner.sleepDisabled = true
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        runner.calls.removeAll()

        coordinator.willTerminate()

        XCTAssertEqual(runner.calls, [], "not even a read")
        XCTAssertEqual(runner.sleepDisabled, true, "the foreign setting is left alone")
    }

    // MARK: Sync

    func testSyncOnBootstrapsKickstartsAndReadsBack() {
        runner.loadedServices = []
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(coordinator.snapshot.sync[.iCloudDrive], .off)
        runner.calls.removeAll()

        coordinator.toggle(.sync(.iCloudDrive))

        XCTAssertEqual(Array(runner.calls.prefix(3)), [
            SystemCommands.launchctlBootstrap(.iCloudDrive, uid: testUID),
            SystemCommands.launchctlKickstart(.iCloudDrive, uid: testUID),
            SystemCommands.launchctlPrint("com.apple.bird", uid: testUID),
        ])
        XCTAssertEqual(coordinator.snapshot.sync[.iCloudDrive], .running)
        XCTAssertNil(coordinator.snapshot.lastError[.sync(.iCloudDrive)])
        XCTAssertEqual(store.saveCount, 0, "sync choices are never stored")
    }

    func testSyncOnThatChangesNothingShowsOffWithExitCodes() {
        runner.loadedServices = []
        runner.launchctlWritesApply = false
        runner.launchctlWriteExit = 5
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.sync(.iCloudPhotos))

        XCTAssertEqual(coordinator.snapshot.sync[.iCloudPhotos], .off)
        XCTAssertFalse(coordinator.snapshot.isOn(.sync(.iCloudPhotos)))
        XCTAssertEqual(coordinator.snapshot.lastError[.sync(.iCloudPhotos)], "launchctl exit 5, 113")
    }

    func testSyncOffBootsOutAndReadsBack() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(coordinator.snapshot.sync[.iCloudPhotos], .running)
        runner.calls.removeAll()

        coordinator.toggle(.sync(.iCloudPhotos))

        XCTAssertEqual(Array(runner.calls.prefix(2)), [
            SystemCommands.launchctlBootout(.iCloudPhotos, uid: testUID),
            SystemCommands.launchctlPrint("com.apple.cloudphotod", uid: testUID),
        ])
        XCTAssertEqual(coordinator.snapshot.sync[.iCloudPhotos], .off)
        XCTAssertEqual(coordinator.snapshot.sync[.iCloudDrive], .running, "the other service is untouched")
    }

    func testSyncOffThatFailsKeepsTheCheckmarkOnWithReason() {
        runner.launchctlWritesApply = false
        runner.launchctlWriteExit = 5
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.sync(.iCloudDrive))

        XCTAssertEqual(coordinator.snapshot.sync[.iCloudDrive], .running)
        XCTAssertEqual(coordinator.snapshot.lastError[.sync(.iCloudDrive)], "launchctl exit 5: Boot-out failed: 5: Input/output error")
    }

    func testLoadedIdleServiceCountsAsOn() {
        runner.idleServices = [SyncService.iCloudPhotos.rawValue]
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(coordinator.snapshot.sync[.iCloudPhotos], .loadedIdle)
        XCTAssertTrue(coordinator.snapshot.isOn(.sync(.iCloudPhotos)))
    }

    func testOneDriveOnLaunchesHiddenByBundleIdentifier() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(coordinator.snapshot.sync[.oneDrive], .off)

        coordinator.toggle(.sync(.oneDrive))

        XCTAssertEqual(applications.launchCalls, ["com.microsoft.OneDrive-mac"])
        XCTAssertEqual(coordinator.snapshot.sync[.oneDrive], .running)
    }

    func testOneDriveOffRequestsQuitAndTheCheckmarkFollowsTheObservation() {
        applications.running = ["com.microsoft.OneDrive-mac"]
        applications.quitsImmediately = false
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertEqual(coordinator.snapshot.sync[.oneDrive], .running)

        coordinator.toggle(.sync(.oneDrive))
        XCTAssertEqual(applications.quitCalls, ["com.microsoft.OneDrive-mac"])
        XCTAssertEqual(coordinator.snapshot.sync[.oneDrive], .running, "still running until it actually quits")
        XCTAssertNil(coordinator.snapshot.lastError[.sync(.oneDrive)])

        applications.running = []
        coordinator.refreshObserved()
        XCTAssertEqual(coordinator.snapshot.sync[.oneDrive], .off)
    }

    func testOneDriveUnderItsOtherBundleIdentifierIsRecognised() {
        applications.running = ["com.microsoft.OneDrive"]
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        XCTAssertTrue(coordinator.snapshot.isOn(.sync(.oneDrive)))

        coordinator.toggle(.sync(.oneDrive))
        XCTAssertEqual(applications.quitCalls, ["com.microsoft.OneDrive"])
    }

    /// Ticket 6: both identifiers were tried, the row names the primary one.
    func testOneDriveNotInstalledShowsOffWithThePrimaryIdentifiersReason() {
        applications.installed = []
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.sync(.oneDrive))

        XCTAssertFalse(coordinator.snapshot.isOn(.sync(.oneDrive)))
        XCTAssertEqual(applications.launchCalls, ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"])
        XCTAssertEqual(coordinator.snapshot.lastError[.sync(.oneDrive)], "com.microsoft.OneDrive-mac is not installed")
    }

    // MARK: Store and unreadable state

    func testStoreFailureIsShownAndTheActionStillHappened() {
        store.saveError = "You don't have permission to save the file"
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.awake(.idleSleep))

        XCTAssertTrue(coordinator.snapshot.isOn(.awake(.idleSleep)))
        XCTAssertEqual(coordinator.snapshot.storeError, "You don't have permission to save the file")

        store.saveError = nil
        coordinator.toggle(.awake(.diskIdle))
        XCTAssertNil(coordinator.snapshot.storeError)
        XCTAssertEqual(store.stored, StoredSettings(awake: [.idleSleep: true, .diskIdle: true]))
    }

    func testUnreadablePmsetShowsOffWithReasonAndWritesNothing() {
        runner.sleepDisabled = nil
        store.stored = StoredSettings(lidClosedAwakeArmedByRestwatt: true)
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .unknown("pmset -g exit 1: pmset: could not read settings"))
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertEqual(pmsetWriteCalls, [])
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt, "stays armed for the quit reconcile")
    }

    /// Ticket 6: a click on the off-looking lid toggle while `pmset -g` is unreadable writes
    /// nothing and says why; the awake profile is never written blind.
    func testLidClosedClickWithUnreadablePmsetIsRefusedWithTheReason() {
        runner.sleepDisabled = nil
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls, [])
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake],
                       "not written, could not read pmset: pmset -g exit 1: pmset: could not read settings")
        XCTAssertEqual(store.saveCount, 0)
    }

    /// Off stays possible while unreadable: Restwatt armed it, so the click takes it back.
    func testLidClosedClickWithUnreadablePmsetWhileArmedWritesSaver() {
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()
        coordinator.toggle(.lidClosedAwake)
        runner.sleepDisabled = nil
        coordinator.refreshObserved()
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertTrue(coordinator.snapshot.armedByRestwatt)
        runner.privilegedPmsetVectors.removeAll()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(runner.privilegedPmsetVectors, SystemCommands.pmsetSaverProfile)
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(store.stored?.lidClosedAwakeArmedByRestwatt, false)
    }
}
