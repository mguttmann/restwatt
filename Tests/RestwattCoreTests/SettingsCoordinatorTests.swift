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

    func testFailedPrivilegeLeavesToggleOffWithReason() throws {
        runner.sudoPasswordless = false
        runner.administratorDialogAccepted = false
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.lidClosedAwake)

        XCTAssertEqual(pmsetWriteCalls.count, 2, "one sudo attempt, one dialog, nothing more")
        XCTAssertEqual(runner.privilegedPmsetVectors, [])
        XCTAssertEqual(coordinator.snapshot.sleepDisabled, .known(false))
        XCTAssertFalse(coordinator.snapshot.isOn(.lidClosedAwake))
        XCTAssertFalse(coordinator.snapshot.armedByRestwatt)
        XCTAssertEqual(coordinator.snapshot.lastError[.lidClosedAwake], "execution error: User canceled. (-128)")
        XCTAssertNil(store.stored, "a failed write arms nothing and writes no file")
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

    /// Fix round 1: a remembered assertion the system refuses at launch is stored as off, so
    /// the file no longer claims a state the checkmark does not show; the other toggles are
    /// untouched by that failure.
    func testRefusedStoredAssertionAtLaunchIsStoredOffAndLeavesTheOthersAlone() {
        assertions.failing = [.idleSleep]
        store.stored = StoredSettings(awake: [.idleSleep: true, .displaySleep: true])
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        XCTAssertFalse(coordinator.snapshot.isOn(.awake(.idleSleep)))
        XCTAssertNotNil(coordinator.snapshot.lastError[.awake(.idleSleep)])
        XCTAssertTrue(coordinator.snapshot.isOn(.awake(.displaySleep)))
        XCTAssertNil(coordinator.snapshot.lastError[.awake(.displaySleep)])
        XCTAssertEqual(store.stored, StoredSettings(awake: [.idleSleep: false, .displaySleep: true]))
        XCTAssertEqual(store.saveCount, 1)
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

    func testOneDriveNotInstalledShowsOffWithReason() {
        applications.installed = []
        let coordinator = makeCoordinator()
        coordinator.applyStoredAtLaunch()

        coordinator.toggle(.sync(.oneDrive))

        XCTAssertFalse(coordinator.snapshot.isOn(.sync(.oneDrive)))
        XCTAssertEqual(coordinator.snapshot.lastError[.sync(.oneDrive)], "com.microsoft.OneDrive is not installed")
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
}
