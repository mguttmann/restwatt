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

    func testHeadTakesTheFirstLineAndCutsLongText() {
        XCTAssertEqual(SystemStateParser.head("  first line \nsecond"), "first line")
        XCTAssertEqual(SystemStateParser.head(String(repeating: "x", count: 200)).count, 120)
        XCTAssertEqual(SystemStateParser.head(""), "")
    }
}
