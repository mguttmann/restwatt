import Foundation
import XCTest
import RestwattCore

/// Realistic numbers measured on an Apple silicon MacBook Pro, plus clearly marked synthetic
/// variants for situations nobody had hardware for. No strings from the registry.
enum Fixtures {
    static let discharging7W = BatterySnapshot(
        updateTime: 1_790_005_742,
        voltageMilliVolts: 12590,
        amperageMilliAmps: -567,
        batteryPowerMilliWatts: -7138,
        remainingCapacityMilliAmpHours: 5002,
        fullChargeCapacityMilliAmpHours: 5578,
        designCapacityMilliAmpHours: 6249,
        currentCapacityPercent: 95,
        isCharging: false,
        externalConnected: false,
        fullyCharged: false,
        avgTimeToEmptyMinutes: 541,
        avgTimeToFullMinutes: nil,
        systemTimeToEmptyMinutes: 466
    )

    static var charging: BatterySnapshot {
        var snapshot = discharging7W
        snapshot.amperageMilliAmps = 2000
        snapshot.batteryPowerMilliWatts = 25180
        snapshot.isCharging = true
        snapshot.externalConnected = true
        snapshot.avgTimeToEmptyMinutes = nil
        snapshot.avgTimeToFullMinutes = 65
        snapshot.systemTimeToEmptyMinutes = nil
        return snapshot
    }

    static var onExternalPowerFull: BatterySnapshot {
        var snapshot = discharging7W
        snapshot.amperageMilliAmps = 0
        snapshot.batteryPowerMilliWatts = 0
        snapshot.externalConnected = true
        snapshot.fullyCharged = true
        snapshot.currentCapacityPercent = 100
        snapshot.remainingCapacityMilliAmpHours = 5578
        snapshot.avgTimeToEmptyMinutes = nil
        snapshot.systemTimeToEmptyMinutes = nil
        return snapshot
    }

    /// MEASURED on a 96 W USB-C PD charger (ioreg dump of 2026-09-21, 75 %, 3.9 A into the
    /// battery, gauge time to full 50 min, gauge time to empty unknown).
    static let charging96W = BatterySnapshot(
        updateTime: 1_790_036_481,
        voltageMilliVolts: 12640,
        amperageMilliAmps: 3881,
        batteryPowerMilliWatts: 49055,
        remainingCapacityMilliAmpHours: 4093,
        fullChargeCapacityMilliAmpHours: 5531,
        designCapacityMilliAmpHours: 6249,
        currentCapacityPercent: 75,
        isCharging: true,
        externalConnected: true,
        fullyCharged: false,
        avgTimeToEmptyMinutes: nil,
        avgTimeToFullMinutes: 50,
        systemTimeToEmptyMinutes: nil,
        adapterWatts: 96
    )

    /// SYNTHETIC: a weak source (a power bank, say) that covers most but not all of the Mac's
    /// draw, so the battery still supplies about 2.3 W. Flags as macOS is expected to report
    /// them ("not charging"); not measured on real hardware.
    static var weakSourceDraining: BatterySnapshot {
        var snapshot = discharging7W
        snapshot.amperageMilliAmps = -180
        snapshot.batteryPowerMilliWatts = -2266
        snapshot.externalConnected = true
        snapshot.adapterWatts = 30
        return snapshot
    }

    /// SYNTHETIC: a weak source that delivers a little more than the Mac uses, so the battery
    /// charges at about 1.5 W and the gauge has no time to full yet. Not measured on real
    /// hardware.
    static var weakSourceSlowCharge: BatterySnapshot {
        var snapshot = discharging7W
        snapshot.amperageMilliAmps = 120
        snapshot.batteryPowerMilliWatts = 1510
        snapshot.isCharging = true
        snapshot.externalConnected = true
        snapshot.avgTimeToEmptyMinutes = nil
        snapshot.systemTimeToEmptyMinutes = nil
        snapshot.adapterWatts = 30
        return snapshot
    }

    /// SYNTHETIC: a source that exactly covers the Mac's draw, the battery sees a trickle of
    /// about 0.4 W inside the dead band. Not measured on real hardware.
    static var nearZeroFlowOnExternal: BatterySnapshot {
        var snapshot = discharging7W
        snapshot.amperageMilliAmps = 30
        snapshot.batteryPowerMilliWatts = 378
        snapshot.externalConnected = true
        snapshot.avgTimeToEmptyMinutes = nil
        snapshot.systemTimeToEmptyMinutes = nil
        snapshot.adapterWatts = 96
        return snapshot
    }

    static func process(_ pid: Int32, _ name: String, joules: Double, cpuSeconds: Double) -> ProcessEnergySample {
        ProcessEnergySample(
            pid: pid, name: name, energyNanoJoules: UInt64(joules * 1e9), cpuTimeSeconds: cpuSeconds)
    }
}

final class ManualClock: ClockReading {
    var now: TimeInterval

    init(now: TimeInterval = 0) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}

final class FakeBattery: BatteryReading {
    var result: Result<BatterySnapshot, BatteryReadError>

    init(_ snapshot: BatterySnapshot) {
        result = .success(snapshot)
    }

    init(error: BatteryReadError) {
        result = .failure(error)
    }

    func readBattery() throws -> BatterySnapshot {
        try result.get()
    }
}

final class FakeProcesses: ProcessReading {
    var samples: [ProcessEnergySample]

    init(_ samples: [ProcessEnergySample] = []) {
        self.samples = samples
    }

    func readProcesses() -> [ProcessEnergySample] {
        samples
    }
}

// MARK: Settings doubles

/// The uid every settings test runs with; the command runner refuses any other domain.
let testUID: uid_t = 503

/// System outputs as measured on 2026-09-21 (`$T5/pmset-g-wach-an.txt`, analyst-facts
/// section 5); the `0` and missing-line variants are synthetic because writing pmset was
/// forbidden during the run.
enum SystemFixtures {
    static let pmsetSleepDisabled1 = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              0
     Sleep On Power Button 1
     SleepServices        0
     hibernatefile        /var/vm/sleepimage
     powernap             0
     networkoversleep     0
     disksleep            0
     sleep                0 (sleep prevented by sharingd, powerd, caffeinate, Claude, mds_stores, coreaudiod, caffeinate, caffeinate)
     hibernatemode        0
     ttyskeepawake        1
     displaysleep         0 (display sleep prevented by caffeinate, caffeinate)
     tcpkeepalive         1
     powermode            2
     womp                 1

    """

    static let pmsetSleepDisabled0 = pmsetSleepDisabled1.replacingOccurrences(
        of: " SleepDisabled\t\t1", with: " SleepDisabled\t\t0")

    static let pmsetWithoutSleepDisabledLine = pmsetSleepDisabled1.replacingOccurrences(
        of: "System-wide power settings:\n SleepDisabled\t\t1\n", with: "")

    static func launchctlRunning(_ label: String, pid: Int = 18643) -> String {
        """
        gui/503/\(label) = {
        \tactive count = 6
        \tpath = /System/Library/LaunchAgents/\(label).plist
        \ttype = LaunchAgent
        \tstate = running

        \tprogram = /System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird
        \tpid = \(pid)
        \truns = 1
        }

        """
    }

    static func launchctlNotRunning(_ label: String) -> String {
        """
        gui/503/\(label) = {
        \tactive count = 0
        \tpath = /System/Library/LaunchAgents/\(label).plist
        \ttype = LaunchAgent
        \tstate = not running

        \truns = 4
        \tlast exit code = 0
        }

        """
    }

    static func launchctlNotFound(_ label: String) -> CommandResult {
        CommandResult(exitStatus: 113, stdout: "",
                      stderr: "Bad request.\nCould not find service \"\(label)\" in domain for user gui: 503\n")
    }
}

final class FakeAssertions: PowerAssertionHolding {
    var failing: Set<AwakeAssertion> = []
    var held: [UInt32: AwakeAssertion] = [:]
    var acquireCalls: [(assertion: AwakeAssertion, name: String)] = []
    var releaseCalls: [UInt32] = []
    private var nextToken: UInt32 = 100

    func acquire(_ assertion: AwakeAssertion, name: String) throws -> UInt32 {
        acquireCalls.append((assertion, name))
        if failing.contains(assertion) {
            throw SettingsFailure("IOPMAssertionCreateWithName returned e00002bc")
        }
        nextToken += 1
        held[nextToken] = assertion
        return nextToken
    }

    func release(_ token: UInt32) {
        releaseCalls.append(token)
        held[token] = nil
    }
}

/// Behaves like the system the vectors are aimed at: `sudo -n pmset` and the administrator
/// dialog change the simulated `SleepDisabled`, launchctl loads and unloads simulated
/// services, `pmset -g` and `launchctl print` report the simulated state. Any vector the
/// simulation does not know fails the test: no real process is ever started.
final class ScriptedCommandRunner: CommandRunning {
    var calls: [CommandVector] = []
    /// Vectors that ran as root, through either path, in order.
    var privilegedPmsetVectors: [CommandVector] = []

    var sudoPasswordless = true
    var administratorDialogAccepted = true
    /// Nil makes `pmset -g` fail.
    var sleepDisabled: Bool? = false
    var pmsetPrintsLineWhenZero = true
    var loadedServices: Set<String> = [SyncService.iCloudDrive.rawValue, SyncService.iCloudPhotos.rawValue]
    var idleServices: Set<String> = []
    /// False simulates launchctl accepting the call but changing nothing.
    var launchctlWritesApply = true
    var launchctlWriteExit: Int32 = 0

    func run(_ vector: CommandVector) -> CommandResult {
        calls.append(vector)
        let args = vector.arguments
        switch vector.executable {
        case SystemCommands.pmset where args == ["-g"]:
            return pmsetRead()

        case SystemCommands.sudo:
            guard args.count > 2, args[0] == "-n", args[1] == SystemCommands.pmset else {
                return unscripted(vector)
            }
            if !sudoPasswordless {
                return CommandResult(exitStatus: 1, stderr: "sudo: a password is required\n")
            }
            return applyPmset(CommandVector(args[1], Array(args[2...])))

        case SystemCommands.osascript:
            guard args.count == 2, args[0] == "-e" else {
                return unscripted(vector)
            }
            if !administratorDialogAccepted {
                return CommandResult(exitStatus: 1, stderr: "execution error: User canceled. (-128)\n")
            }
            for profile in PmsetProfile.allCases
            where (try? SystemCommands.administratorScriptSource(profile.vectors)) == args[1] {
                var last = CommandResult(exitStatus: 0)
                for pmsetVector in profile.vectors {
                    last = applyPmset(pmsetVector)
                }
                return last
            }
            return unscripted(vector)

        case SystemCommands.launchctl:
            return launchctl(vector)

        default:
            return unscripted(vector)
        }
    }

    private func pmsetRead() -> CommandResult {
        switch sleepDisabled {
        case nil:
            return CommandResult(exitStatus: 1, stderr: "pmset: could not read settings\n")
        case true?:
            return CommandResult(exitStatus: 0, stdout: SystemFixtures.pmsetSleepDisabled1)
        case false?:
            return CommandResult(exitStatus: 0, stdout: pmsetPrintsLineWhenZero
                                 ? SystemFixtures.pmsetSleepDisabled0
                                 : SystemFixtures.pmsetWithoutSleepDisabledLine)
        }
    }

    private func applyPmset(_ vector: CommandVector) -> CommandResult {
        privilegedPmsetVectors.append(vector)
        let args = vector.arguments
        if let index = args.firstIndex(of: "disablesleep"), index + 1 < args.count {
            sleepDisabled = args[index + 1] == "1"
        }
        return CommandResult(exitStatus: 0)
    }

    private func launchctl(_ vector: CommandVector) -> CommandResult {
        let args = vector.arguments
        let domainPrefix = "gui/\(testUID)/"
        switch args.first {
        case "print" where args.count == 2 && args[1].hasPrefix(domainPrefix):
            let label = String(args[1].dropFirst(domainPrefix.count))
            guard loadedServices.contains(label) else {
                return SystemFixtures.launchctlNotFound(label)
            }
            return CommandResult(exitStatus: 0, stdout: idleServices.contains(label)
                                 ? SystemFixtures.launchctlNotRunning(label)
                                 : SystemFixtures.launchctlRunning(label))
        case "bootstrap" where args.count == 3 && args[1] == "gui/\(testUID)"
                && args[2].hasPrefix("/System/Library/LaunchAgents/") && args[2].hasSuffix(".plist"):
            let label = String(args[2].dropFirst("/System/Library/LaunchAgents/".count).dropLast(".plist".count))
            if launchctlWritesApply {
                loadedServices.insert(label)
                idleServices.insert(label)
            }
            return CommandResult(exitStatus: launchctlWriteExit)
        case "kickstart" where args.count == 2 && args[1].hasPrefix(domainPrefix):
            let label = String(args[1].dropFirst(domainPrefix.count))
            if launchctlWritesApply {
                idleServices.remove(label)
            }
            return CommandResult(exitStatus: loadedServices.contains(label) ? 0 : 113)
        case "bootout" where args.count == 2 && args[1].hasPrefix(domainPrefix):
            let label = String(args[1].dropFirst(domainPrefix.count))
            if launchctlWritesApply {
                loadedServices.remove(label)
                idleServices.remove(label)
            }
            return CommandResult(exitStatus: launchctlWriteExit, stderr: launchctlWriteExit == 0 ? "" : "Boot-out failed: 5: Input/output error\n")
        default:
            return unscripted(vector)
        }
    }

    private func unscripted(_ vector: CommandVector) -> CommandResult {
        XCTFail("unscripted command: \(vector.commandLine)")
        return CommandResult(exitStatus: 127, stderr: "unscripted")
    }
}

final class MemorySettingsStore: SettingsStoring {
    var stored: StoredSettings?
    var saveError: String?
    var saveCount = 0

    init(_ stored: StoredSettings? = nil) {
        self.stored = stored
    }

    func load() -> StoredSettings {
        stored ?? StoredSettings()
    }

    func save(_ settings: StoredSettings) throws {
        saveCount += 1
        if let saveError {
            throw SettingsFailure(saveError)
        }
        stored = settings
    }
}

final class FakeApplications: ApplicationControlling {
    var installed: Set<String> = [SyncService.oneDrive.rawValue]
    var running: Set<String> = []
    /// The real quit request returns before the application has quit; false keeps it running.
    var quitsImmediately = true
    var launchCalls: [String] = []
    var quitCalls: [String] = []

    func isRunning(bundleIdentifier: String) -> Bool {
        running.contains(bundleIdentifier)
    }

    func launchHidden(bundleIdentifier: String) throws {
        launchCalls.append(bundleIdentifier)
        guard installed.contains(bundleIdentifier) else {
            throw SettingsFailure("\(bundleIdentifier) is not installed")
        }
        running.insert(bundleIdentifier)
    }

    func requestQuit(bundleIdentifier: String) throws {
        quitCalls.append(bundleIdentifier)
        guard running.contains(bundleIdentifier) else {
            throw SettingsFailure("\(bundleIdentifier) is not running")
        }
        if quitsImmediately {
            running.remove(bundleIdentifier)
        }
    }
}
