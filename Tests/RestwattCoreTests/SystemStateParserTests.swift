import XCTest
@testable import RestwattCore

final class SystemStateParserTests: XCTestCase {
    func testMeasuredPmsetOutputReportsSleepDisabled() {
        XCTAssertEqual(SystemStateParser.parseSleepDisabled(pmsetOutput: SystemFixtures.pmsetSleepDisabled1), true)
    }

    func testSleepDisabledZeroLine() {
        XCTAssertEqual(SystemStateParser.parseSleepDisabled(pmsetOutput: SystemFixtures.pmsetSleepDisabled0), false)
    }

    func testMissingSleepDisabledLineMeansNotDisabled() {
        XCTAssertFalse(SystemFixtures.pmsetWithoutSleepDisabledLine.contains("SleepDisabled"))
        XCTAssertEqual(SystemStateParser.parseSleepDisabled(pmsetOutput: SystemFixtures.pmsetWithoutSleepDisabledLine), false)
    }

    func testEmptyOutputIsNoStatement() {
        XCTAssertNil(SystemStateParser.parseSleepDisabled(pmsetOutput: ""))
        XCTAssertNil(SystemStateParser.parseSleepDisabled(pmsetOutput: "\n\n"))
    }

    /// The `sleep 0 (sleep prevented by ...)` line in the other block must not be mistaken for
    /// the system-wide flag, and a `SleepDisabled` outside the system-wide block is ignored.
    func testOnlyTheSystemWideBlockCounts() {
        let output = """
        Currently in use:
         SleepDisabled\t\t1
         sleep                0 (sleep prevented by sharingd)

        """
        XCTAssertEqual(SystemStateParser.parseSleepDisabled(pmsetOutput: output), false)
    }

    func testSpacesInsteadOfTabsStillParse() {
        XCTAssertEqual(SystemStateParser.parseSleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled    1\n"), true)
    }

    func testLaunchctlRunning() {
        let result = CommandResult(exitStatus: 0, stdout: SystemFixtures.launchctlRunning("com.apple.bird"))
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(result), .running)
    }

    /// Tester hardening: the real `launchctl print gui/503/com.apple.bird` (measured
    /// 2026-09-21) carries nested `state = active` lines and a `job state = running` line
    /// further down; only the top-level `state` line may decide.
    func testMeasuredLaunchctlPrintWithNestedStateLinesReportsTheTopLevelState() {
        let realShape = """
        gui/503/com.apple.bird = {
        \tactive count = 6
        \tpath = /System/Library/LaunchAgents/com.apple.bird.plist
        \ttype = LaunchAgent
        \tstate = not running

        \tprogram = /System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird
        \tendpoints = {
        \t\t"com.apple.bird" = {
        \t\t\tport = 0x4d603
        \t\t\tactive = 0
        \t\t\tmanaged = 1
        \t\t\treset = 0
        \t\t\thide = 0
        \t\t\twatching = 0
        \t\t}
        \t}
        \tevent channels = {
        \t\t"com.apple.xpc.activity" = {
        \t\t\tport = 0x4d703
        \t\t\tactive = 0
        \t\t\tmanaged = 1
        \t\t\treset = 0
        \t\t\thide = 0
        \t\t\tstate = active
        \t\t}
        \t}
        \tjob state = running
        }

        """
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(CommandResult(exitStatus: 0, stdout: realShape)), .loadedIdle)
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(CommandResult(
            exitStatus: 0, stdout: realShape.replacingOccurrences(of: "\tstate = not running", with: "\tstate = running"))), .running)
    }

    func testLaunchctlLoadedButIdle() {
        let result = CommandResult(exitStatus: 0, stdout: SystemFixtures.launchctlNotRunning("com.apple.cloudphotod"))
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(result), .loadedIdle)
        XCTAssertTrue(ServiceState.loadedIdle.isOn)
    }

    func testLaunchctlNotLoadedIsOff() {
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(SystemFixtures.launchctlNotFound("com.apple.bird")), .off)
    }

    func testLaunchctlOtherFailureIsUnknownWithReason() {
        let result = CommandResult(exitStatus: 1, stderr: "Could not connect to launchd\nmore\n")
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(result),
                       .unknown("launchctl print exit 1: Could not connect to launchd"))
        XCTAssertFalse(SystemStateParser.parseLaunchctlPrint(result).isOn)
    }

    func testLaunchctlSuccessWithoutStateIsUnknown() {
        let result = CommandResult(exitStatus: 0, stdout: "gui/503/x = {\n}\n")
        XCTAssertEqual(SystemStateParser.parseLaunchctlPrint(result), .unknown("launchctl print reported no state"))
    }

    // MARK: sudo denial vs command failure (ticket 6, M2)

    func testSudoRefusingWithoutAPasswordIsADenial() {
        XCTAssertTrue(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 1, stderr: "sudo: a password is required\n")))
        XCTAssertTrue(SystemStateParser.isSudoDenial(CommandResult(
            exitStatus: 1,
            stderr: "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\n")))
    }

    func testAPmsetFailureUnderSudoIsNotADenial() {
        XCTAssertFalse(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 1, stderr: "pmset: hibernatemode is not supported on this system\n")))
        XCTAssertFalse(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 1, stderr: "Usage: pmset <options>\n")))
        XCTAssertFalse(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 2, stderr: "sudo: a password is required\n")), "sudo denies with exit 1")
        XCTAssertFalse(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 1)), "silence is not a denial")
        XCTAssertFalse(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 0, stderr: "sudo: a password is required\n")))
        XCTAssertFalse(SystemStateParser.isSudoDenial(CommandResult(exitStatus: 1, stderr: "pmset: a password is required\n")), "the sudo: prefix is part of the marker")
    }

    /// Ticket 7 (a): sudo failing on its own account is told from pmset failing by the
    /// `sudo:` prefix on stderr; without it, or with another exit status, the failure is the
    /// command's (the conservative reading: no dialog for a line that would fail again).
    func testASudoLineOnStderrIsASudoFailureDenialOrNot() {
        XCTAssertTrue(SystemStateParser.isSudoFailure(CommandResult(exitStatus: 1, stderr: "sudo: a password is required\n")))
        XCTAssertTrue(SystemStateParser.isSudoFailure(CommandResult(
            exitStatus: 1, stderr: "sudo: effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid' option set or an NFS file system without root privileges?\n")))
        XCTAssertTrue(SystemStateParser.isSudoFailure(CommandResult(exitStatus: 1, stderr: "sudo: /etc/sudoers is owned by uid 501, should be 0\nsudo: no valid sudoers sources found, quitting\n")))
        XCTAssertFalse(SystemStateParser.isSudoFailure(CommandResult(exitStatus: 1, stderr: "pmset: hibernatemode is not supported on this system\n")))
        XCTAssertFalse(SystemStateParser.isSudoFailure(CommandResult(exitStatus: 1)), "silence is the command's failure")
        XCTAssertFalse(SystemStateParser.isSudoFailure(CommandResult(exitStatus: 2, stderr: "sudo: a password is required\n")))
        XCTAssertFalse(SystemStateParser.isSudoFailure(CommandResult(exitStatus: 1, stderr: "Usage: pmset <options>\nsee sudo: for details\n")), "the prefix is the marker")
    }

    func testACancelledDialogIsToldFromAFailedOne() {
        XCTAssertTrue(SystemStateParser.isDialogCancelled(CommandResult(exitStatus: 1, stderr: "execution error: User canceled. (-128)\n")))
        XCTAssertFalse(SystemStateParser.isDialogCancelled(CommandResult(exitStatus: 1, stderr: "execution error: pmset: hibernatemode is not supported on this system (1)\n")))
        XCTAssertFalse(SystemStateParser.isDialogCancelled(CommandResult(exitStatus: 0)))
    }

    /// Ticket 6 minor: `kIOReturnNoMemory` style codes have the high bit set and rendered as
    /// a negative hex string before; the eight IOKit digits are what the fixture shows.
    func testIOReturnRendersAsUnsignedHex() {
        XCTAssertEqual(SystemStateParser.ioReturnHex(Int32(bitPattern: 0xe00002bc)), "e00002bc")
        XCTAssertEqual(SystemStateParser.ioReturnHex(-536870212), "e00002bc")
        XCTAssertEqual(SystemStateParser.ioReturnHex(0), "0")
        XCTAssertFalse(SystemStateParser.ioReturnHex(Int32.min).hasPrefix("-"))
    }

    func testHeadTakesTheFirstLineAndCutsLongText() {
        XCTAssertEqual(SystemStateParser.head("  first line \nsecond"), "first line")
        XCTAssertEqual(SystemStateParser.head(String(repeating: "x", count: 200)).count, 120)
        XCTAssertEqual(SystemStateParser.head(""), "")
    }
}
