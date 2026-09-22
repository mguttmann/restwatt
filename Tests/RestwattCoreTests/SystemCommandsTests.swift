import XCTest
@testable import RestwattCore

/// Pins the argument vectors to Manuel's two scripts (Wach-AN.command line 5, Wach-AUS.command
/// lines 5 to 8 and 17 to 20) and the two privilege wrappers.
final class SystemCommandsTests: XCTestCase {
    func testAwakeProfileIsTheOneCallOfWachAN() {
        XCTAssertEqual(SystemCommands.pmsetAwakeProfile, [
            CommandVector("/usr/bin/pmset", ["-a", "sleep", "0", "displaysleep", "0", "disksleep", "0",
                                             "hibernatemode", "0", "standby", "0", "disablesleep", "1"]),
        ])
        XCTAssertEqual(PmsetProfile.awake.vectors, SystemCommands.pmsetAwakeProfile)
    }

    func testSaverProfileIsTheFourCallsOfWachAUSInOrder() {
        XCTAssertEqual(SystemCommands.pmsetSaverProfile, [
            CommandVector("/usr/bin/pmset", ["-a", "disablesleep", "0"]),
            CommandVector("/usr/bin/pmset", ["-b", "displaysleep", "2", "sleep", "10", "disksleep", "10",
                                             "hibernatemode", "3", "standby", "1"]),
            CommandVector("/usr/bin/pmset", ["-c", "displaysleep", "10", "sleep", "30", "disksleep", "10",
                                             "hibernatemode", "3", "standby", "1"]),
            CommandVector("/usr/bin/pmset", ["-a", "standbydelaylow", "10800", "standbydelayhigh", "86400"]),
        ])
        XCTAssertEqual(PmsetProfile.saver.vectors, SystemCommands.pmsetSaverProfile)
    }

    func testPmsetReadVector() {
        XCTAssertEqual(SystemCommands.pmsetRead, CommandVector("/usr/bin/pmset", ["-g"]))
    }

    func testLaunchctlVectorsMatchTheScripts() {
        XCTAssertEqual(SystemCommands.launchctlBootstrap(.iCloudDrive, uid: 503),
                       CommandVector("/bin/launchctl", ["bootstrap", "gui/503", "/System/Library/LaunchAgents/com.apple.bird.plist"]))
        XCTAssertEqual(SystemCommands.launchctlKickstart(.iCloudDrive, uid: 503),
                       CommandVector("/bin/launchctl", ["kickstart", "gui/503/com.apple.bird"]))
        XCTAssertEqual(SystemCommands.launchctlBootout(.iCloudPhotos, uid: 503),
                       CommandVector("/bin/launchctl", ["bootout", "gui/503/com.apple.cloudphotod"]))
        XCTAssertEqual(SystemCommands.launchctlPrint("com.apple.cloudphotod", uid: 503),
                       CommandVector("/bin/launchctl", ["print", "gui/503/com.apple.cloudphotod"]))
        XCTAssertEqual(SystemCommands.launchctlBootstrap(.iCloudPhotos, uid: 501)?.arguments[2],
                       "/System/Library/LaunchAgents/com.apple.cloudphotod.plist")
    }

    func testOneDriveIsNotALaunchdServiceAndHasNoLaunchctlVectors() {
        XCTAssertFalse(SyncService.oneDrive.isLaunchdService)
        XCTAssertNil(SystemCommands.launchctlBootstrap(.oneDrive, uid: 503))
        XCTAssertNil(SystemCommands.launchctlKickstart(.oneDrive, uid: 503))
        XCTAssertNil(SystemCommands.launchctlBootout(.oneDrive, uid: 503))
        XCTAssertEqual(SyncService.oneDrive.bundleIdentifiers, ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"])
    }

    func testRawValuesAreTheSystemIdentifiers() {
        XCTAssertEqual(AwakeAssertion.idleSleep.rawValue, "PreventUserIdleSystemSleep")
        XCTAssertEqual(AwakeAssertion.displaySleep.rawValue, "PreventUserIdleDisplaySleep")
        XCTAssertEqual(AwakeAssertion.diskIdle.rawValue, "PreventDiskIdle")
        XCTAssertEqual(SyncService.iCloudDrive.rawValue, "com.apple.bird")
        XCTAssertEqual(SyncService.iCloudPhotos.rawValue, "com.apple.cloudphotod")
    }

    func testSudoNonInteractivePrefixesAndKeepsTheVector() {
        let vector = SystemCommands.pmsetSaverProfile[0]
        XCTAssertEqual(SystemCommands.sudoNonInteractive(vector),
                       CommandVector("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]))
    }

    func testAdministratorScriptChainsTheSaverProfileIntoOneDialog() throws {
        let script = try SystemCommands.administratorScript(SystemCommands.pmsetSaverProfile)
        XCTAssertEqual(script.executable, "/usr/bin/osascript")
        XCTAssertEqual(script.arguments.count, 2)
        XCTAssertEqual(script.arguments[0], "-e")
        XCTAssertEqual(script.arguments[1],
                       "do shell script \"/usr/bin/pmset -a disablesleep 0 && "
                       + "/usr/bin/pmset -b displaysleep 2 sleep 10 disksleep 10 hibernatemode 3 standby 1 && "
                       + "/usr/bin/pmset -c displaysleep 10 sleep 30 disksleep 10 hibernatemode 3 standby 1 && "
                       + "/usr/bin/pmset -a standbydelaylow 10800 standbydelayhigh 86400\" with administrator privileges")
        XCTAssertFalse(script.arguments[1].contains("user name"))
        XCTAssertFalse(script.arguments[1].contains("password"))
    }

    func testAdministratorScriptForTheAwakeProfile() throws {
        let source = try SystemCommands.administratorScriptSource(SystemCommands.pmsetAwakeProfile)
        XCTAssertEqual(source, "do shell script \"/usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 "
                       + "hibernatemode 0 standby 0 disablesleep 1\" with administrator privileges")
    }

    /// Ticket 6 (M2): the dialog carries only the vectors sudo did not run.
    func testAdministratorScriptForTheTailOfAProfile() throws {
        let source = try SystemCommands.administratorScriptSource(Array(SystemCommands.pmsetSaverProfile[2...]))
        XCTAssertEqual(source, "do shell script \"/usr/bin/pmset -c displaysleep 10 sleep 30 disksleep 10 hibernatemode 3 standby 1 && "
                       + "/usr/bin/pmset -a standbydelaylow 10800 standbydelayhigh 86400\" with administrator privileges")
    }

    func testTokenValidationRefusesShellMetacharacters() {
        for bad in ["a b", "x\"y", "a;b", "$HOME", "", "a'b", "a\nb", "a&&b", "`id`"] {
            XCTAssertThrowsError(try SystemCommands.validatedToken(bad), "accepted \(bad.debugDescription)") { error in
                XCTAssertEqual(error as? PrivilegeError, .invalidToken(bad))
            }
        }
        XCTAssertEqual(try SystemCommands.validatedToken("/usr/bin/pmset"), "/usr/bin/pmset")
        XCTAssertEqual(try SystemCommands.validatedToken("standbydelaylow"), "standbydelaylow")
    }

    func testAdministratorScriptRefusesAVectorWithABadToken() {
        let vector = CommandVector("/usr/bin/pmset", ["-a", "disablesleep 0; rm -rf /"])
        XCTAssertThrowsError(try SystemCommands.administratorScript([vector]))
    }

    /// Nothing but pmset with fixed keys ever runs as root, and no vector mentions sudoers or
    /// feeds a password on stdin.
    func testOnlyPmsetRunsPrivilegedAndNothingTouchesSudoers() throws {
        for profile in PmsetProfile.allCases {
            for vector in profile.vectors {
                XCTAssertEqual(vector.executable, "/usr/bin/pmset")
                let sudo = SystemCommands.sudoNonInteractive(vector)
                XCTAssertEqual(sudo.arguments[0], "-n")
                XCTAssertEqual(sudo.arguments[1], "/usr/bin/pmset")
                XCTAssertFalse(sudo.arguments.contains("-S"))
                XCTAssertFalse(sudo.arguments.contains("-A"))
                for token in [vector.executable] + vector.arguments {
                    XCTAssertFalse(token.lowercased().contains("sudoers"), token)
                    XCTAssertFalse(token.lowercased().contains("visudo"), token)
                }
            }
            let script = try SystemCommands.administratorScriptSource(profile.vectors)
            XCTAssertFalse(script.contains("sudo"))
            XCTAssertFalse(script.contains("sudoers"))
            XCTAssertEqual(script.components(separatedBy: "/usr/bin/pmset").count - 1, profile.vectors.count)
        }
    }

    func testCommandLineRendering() {
        XCTAssertEqual(SystemCommands.pmsetSaverProfile[3].commandLine,
                       "/usr/bin/pmset -a standbydelaylow 10800 standbydelayhigh 86400")
    }
}
