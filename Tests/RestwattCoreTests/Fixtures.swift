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

    // MARK: Statistics

    /// The machine's zone (measured 2026-09-22) and UTC, so day rollover tests prove the
    /// calendar is injected rather than taken from the process.
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wall-clock instant most statistics tests run at: 2026-09-22 08:00:00 UTC, which is
    /// 04:00 in New York, the same calendar day in both zones.
    static let wallNow = Date(timeIntervalSince1970: 1_790_064_000)
    /// A boot about 18 hours before `wallNow`.
    static let bootTime = Date(timeIntervalSince1970: 1_789_998_856)

    /// A day of sampling: three names, some evicted energy, 4:12 h sampled, 1.742 Wh total.
    static let todayStatistic = DailyEnergyStatistic(
        day: "2026-09-22",
        entries: [
            DailyEnergyEntry(name: "Discord Helper (Renderer)", wattHours: 1.02),
            DailyEnergyEntry(name: "node", wattHours: 0.31),
            DailyEnergyEntry(name: "Restwatt", wattHours: 0.012),
        ],
        otherWattHours: 0.4,
        sampledSeconds: 15120)

    // MARK: Power log

    /// SYNTHETIC: invented power source lines in the measured shape of `pmset -g log` (column
    /// layout, tabs and trailing blanks, the five spellings of the power source), on a fictional
    /// 2031-06-10 to 2031-06-11 in America/New_York (-0400, daylight saving time as in the
    /// measured log). No line comes from a real log. Among them the cut-off Assertions lines
    /// `Using AC(Char`, `Using Batt(Charge:` and `Using Batt(Charge: 1`, and a boot marker while
    /// on AC. The last AC line before the final battery period is at 12:14:45, the first battery
    /// line after it at 12:17:21 with 100 %, and the last line is the plug-in at 18:05:12.
    static let powerLogLines: [String] = [
        "2031-06-10 19:12:05 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using Batt(Charge: 100)          ",
        "2031-06-10 19:12:06 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 2400 secs ",
        "2031-06-10 19:52:07 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 12 secs    ",
        "2031-06-10 19:52:08 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser SRPrevSleep kCPU kDisp] Using Batt(Charge: 100)          ",
        "2031-06-10 19:52:19 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 3300 secs ",
        "2031-06-10 20:47:20 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 8 secs    ",
        "2031-06-10 20:47:28 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 1800 secs ",
        "2031-06-10 21:17:29 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 2 secs    ",
        "2031-06-10 21:17:30 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp PrevSleep DeclUser BGTask SRPrevSleep kCPU kDisp] Using AC(Char          ",
        "2031-06-10 21:17:31 -0400 Wake                \tDarkWake to FullWake from Deep Idle [CDNVA] : due to Notification Using AC (Charge:100%)           ",
        "2031-06-10 22:40:12 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser BGTask kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 01:05:44 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 03:02:10 -0400 Start               \tpowerd process is started                                                  \t          ",
        "2031-06-11 03:02:41 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser BGTask kCPU kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 06:30:03 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 07:48:15 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser NetAcc kCPU kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 07:55:40 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 08:20:02 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using Batt(Charge: 98)          ",
        "2031-06-11 08:20:05 -0400 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:98%) 300 secs ",
        "2031-06-11 08:25:06 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:98%) 10 secs    ",
        "2031-06-11 08:25:07 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser SRPrevSleep kCPU kDisp] Using Batt(Charge: 98)          ",
        "2031-06-11 08:25:16 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:98%) 2900 secs ",
        "2031-06-11 09:13:37 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:98%) 14 secs    ",
        "2031-06-11 09:13:51 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:98%) 600 secs ",
        "2031-06-11 09:23:52 -0400 Wake                \tWake from Deep Idle [CDNVA] : due to UserActivity Using BATT (Charge:98%)           ",
        "2031-06-11 09:23:54 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using Batt(Charge: 98)          ",
        "2031-06-11 10:31:09 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser BGTask kDisp] Using AC(Charge: 81)          ",
        "2031-06-11 11:02:46 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser BGTask kCPU kDisp] Using AC(Charge: 94)          ",
        "2031-06-11 11:02:47 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using AC(Charge: 94)          ",
        "2031-06-11 11:40:18 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser IntPrevDisp kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 11:40:29 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser IntPrevDisp kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 11:52:03 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 12:14:37 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser IntPrevDisp kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 12:14:45 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser BGTask IntPrevDisp kDisp] Using AC(Charge: 100)          ",
        "2031-06-11 12:17:21 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 12:31:08 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser SysAct IntPrevDisp kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 12:31:08 -0400 Sleep               \tEntering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 640 secs ",
        "2031-06-11 12:41:49 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 9 secs    ",
        "2031-06-11 12:41:53 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser SRPrevSleep kCPU kDisp] Using Batt(Charge:          ",
        "2031-06-11 12:41:58 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 1500 secs ",
        "2031-06-11 13:06:59 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 17 secs    ",
        "2031-06-11 13:07:16 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser IntPrevDisp kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 13:07:16 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 1300 secs ",
        "2031-06-11 13:28:57 -0400 DarkWake            \tDarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 8 secs    ",
        "2031-06-11 13:28:58 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser SRPrevSleep IntPrevDisp kCPU kDisp] Using Batt(Charge:          ",
        "2031-06-11 13:29:05 -0400 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 2000 secs ",
        "2031-06-11 14:21:47 -0400 Wake                \tWake from Deep Idle [CDNVA] : due to UserActivity Using BATT (Charge:100%)           ",
        "2031-06-11 14:21:49 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser IntPrevDisp kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 14:22:30 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser IntPrevDisp kCPU kDisp] Using Batt(Charge: 1          ",
        "2031-06-11 14:24:53 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using Batt(Charge: 100)          ",
        "2031-06-11 15:41:02 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser BGTask kDisp] Using Batt(Charge: 61)          ",
        "2031-06-11 18:05:12 -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using AC(Charge: 12)          ",
    ]

    static var powerLogExcerpt: String {
        powerLogLines.joined(separator: "\n") + "\n"
    }
}

final class ManualWallClock: WallClockReading {
    var now: Date
    var bootTime: Date?

    init(now: Date = Fixtures.wallNow, bootTime: Date? = Fixtures.bootTime) {
        self.now = now
        self.bootTime = bootTime
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

final class MemoryStatisticsStore: StatisticsStoring {
    var stored: StoredStatistics?
    var saveError: String?
    var saveCount = 0

    init(_ stored: StoredStatistics? = nil) {
        self.stored = stored
    }

    func load() -> StoredStatistics {
        stored ?? StoredStatistics()
    }

    func save(_ statistics: StoredStatistics) throws {
        saveCount += 1
        if let saveError {
            throw SettingsFailure(saveError)
        }
        stored = statistics
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

    /// `pmset -g custom` as measured on 2026-09-22 (`$T11/pmset-custom.txt`): one block per
    /// source, header without a leading space, value lines with one. A nil value drops the
    /// `powermode` line (pmset omits the key when the mode is off, per outside documentation);
    /// a source absent from `modes` has no block.
    static func pmsetCustom(_ modes: [PowerSource: Int?]) -> String {
        var text = ""
        for source in PowerSource.allCases {
            guard let mode = modes[source] else {
                continue
            }
            text += "\(source.rawValue):\n Sleep On Power Button 1\n"
            if let mode {
                text += " powermode            \(mode)\n"
            }
            text += " standby              1\n ttyskeepawake        1\n hibernatemode        3\n"
            text += " powernap             0\n hibernatefile        /var/vm/sleepimage\n"
            text += source == .battery ? " displaysleep         2\n womp                 0\n" : " displaysleep         10\n womp                 1\n"
            text += " networkoversleep     0\n sleep                \(source == .battery ? 10 : 30)\n tcpkeepalive         1\n"
            if source == .battery {
                text += " lessbright           1\n"
            }
            text += " disksleep            10\n SleepServices        0\n"
        }
        return text
    }

    /// The VERBATIM `pmset -g custom` dump of Manuel's Mac, 2026-09-22 (`$T11/pmset-custom.txt`,
    /// on battery, powermode 1 / AC 2). `pmsetCustom([.battery: 1, .ac: 2])` must reproduce it
    /// byte for byte so the generated variants stay in the measured shape.
    static let pmsetCustomMeasured = """
Battery Power:
 Sleep On Power Button 1
 powermode            1
 standby              1
 ttyskeepawake        1
 hibernatemode        3
 powernap             0
 hibernatefile        /var/vm/sleepimage
 displaysleep         2
 womp                 0
 networkoversleep     0
 sleep                10
 tcpkeepalive         1
 lessbright           1
 disksleep            10
 SleepServices        0
AC Power:
 Sleep On Power Button 1
 powermode            2
 standby              1
 ttyskeepawake        1
 hibernatemode        3
 powernap             0
 hibernatefile        /var/vm/sleepimage
 displaysleep         10
 womp                 1
 networkoversleep     0
 sleep                30
 tcpkeepalive         1
 disksleep            10
 SleepServices        0\n
"""

    /// `pmset -g cap` as measured on 2026-09-22 (analyst-facts section 1.4).
    static func pmsetCap(source: String, highPower: Bool) -> String {
        var text = "Capabilities for \(source):\n displaysleep\n disksleep\n sleep\n womp\n lessbright\n standby\n"
        text += " powernap\n ttyskeepawake\n hibernatemode\n hibernatefile\n tcpkeepalive\n lowpowermode\n"
        if highPower {
            text += " highpowermode\n"
        }
        return text
    }

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
    /// When set, `sudo -n` runs this many pmset vectors and denies the next one: the
    /// passwordless rule ran out mid-profile (a timestamp expiring, a rule per command).
    var sudoDeniesAfter: Int?
    private var sudoGranted = 0
    var administratorDialogAccepted = true
    /// When set, `sudo -n` fails on its own account with this stderr and exit 1 before pmset
    /// runs (a broken sudo configuration, a `nosuid` mount): neither a grant nor a plain denial.
    var sudoFailureStderr: String?
    /// With `sudoFailureStderr`: how many vectors sudo grants before it breaks (nil: none).
    var sudoFailsAfter: Int?
    /// pmset keys the simulated hardware refuses: the call exits 1 with pmset's own stderr,
    /// through sudo and inside the dialog alike.
    var pmsetRefusedKeys: Set<String> = []
    /// True makes a refused pmset call exit 1 without printing anything.
    var pmsetRefusesSilently = false
    /// Nil makes `pmset -g` fail.
    var sleepDisabled: Bool? = false
    var pmsetPrintsLineWhenZero = true
    var loadedServices: Set<String> = [SyncService.iCloudDrive.rawValue, SyncService.iCloudPhotos.rawValue]
    var idleServices: Set<String> = []
    /// False simulates launchctl accepting the call but changing nothing.
    var launchctlWritesApply = true
    var launchctlWriteExit: Int32 = 0
    /// Simulated `powermode` per source as `pmset -g custom` prints it; Manuel's Mac on
    /// 2026-09-22 (Battery 1, AC 2). A nil value is a block without the line; a missing
    /// source has no block.
    var energyModes: [PowerSource: Int?] = [.battery: 1, .ac: 2]
    /// The source `pmset -g cap` names; `capSourceName` overrides the name (`UPS Power`).
    var currentSource: PowerSource = .battery
    var capSourceName: String?
    var highPowerCapable = true
    var capReadFails = false
    var customReadFails = false
    /// Energy Mode values the simulated pmset refuses with exit 1 and its own stderr.
    var refusedEnergyModeValues: Set<Int> = []
    /// False simulates pmset accepting `lowpowermode N` but changing nothing.
    var energyModeWritesApply = true

    func run(_ vector: CommandVector) -> CommandResult {
        calls.append(vector)
        let args = vector.arguments
        switch vector.executable {
        case SystemCommands.pmset where args == ["-g"]:
            return pmsetRead()

        case SystemCommands.pmset where args == ["-g", "cap"]:
            if capReadFails {
                return CommandResult(exitStatus: 1, stderr: "pmset: could not read capabilities\n")
            }
            return CommandResult(exitStatus: 0, stdout: SystemFixtures.pmsetCap(
                source: capSourceName ?? currentSource.rawValue, highPower: highPowerCapable))

        case SystemCommands.pmset where args == ["-g", "custom"]:
            if customReadFails {
                return CommandResult(exitStatus: 1, stderr: "pmset: could not read settings\n")
            }
            return CommandResult(exitStatus: 0, stdout: SystemFixtures.pmsetCustom(energyModes))

        case SystemCommands.sudo:
            guard args.count > 2, args[0] == "-n", args[1] == SystemCommands.pmset else {
                return unscripted(vector)
            }
            if !sudoPasswordless || sudoDeniesAfter.map({ sudoGranted >= $0 }) == true {
                return CommandResult(exitStatus: 1, stderr: "sudo: a password is required\n")
            }
            if let stderr = sudoFailureStderr, sudoFailsAfter.map({ sudoGranted >= $0 }) ?? true {
                return CommandResult(exitStatus: 1, stderr: stderr)
            }
            sudoGranted += 1
            return applyPmset(CommandVector(args[1], Array(args[2...])))

        case SystemCommands.osascript:
            guard args.count == 2, args[0] == "-e" else {
                return unscripted(vector)
            }
            if !administratorDialogAccepted {
                return CommandResult(exitStatus: 1, stderr: "execution error: User canceled. (-128)\n")
            }
            // The dialog may carry a whole profile or the tail of one; `&&` stops at the
            // first failing call and osascript reports that failure.
            for profile in PmsetProfile.allCases {
                for start in profile.vectors.indices
                where (try? SystemCommands.administratorScriptSource(Array(profile.vectors[start...]))) == args[1] {
                    for pmsetVector in profile.vectors[start...] {
                        let result = applyPmset(pmsetVector)
                        if !result.succeeded {
                            return CommandResult(exitStatus: result.exitStatus,
                                                 stderr: "execution error: \(result.stderr.trimmingCharacters(in: .newlines)) (\(result.exitStatus))\n")
                        }
                    }
                    return CommandResult(exitStatus: 0)
                }
            }
            // An Energy Mode row puts exactly one vector into the dialog.
            for energyVector in SystemCommands.energyModeVectors
            where (try? SystemCommands.administratorScriptSource([energyVector])) == args[1] {
                let result = applyPmset(energyVector)
                if !result.succeeded {
                    return CommandResult(exitStatus: result.exitStatus,
                                         stderr: "execution error: \(result.stderr.trimmingCharacters(in: .newlines)) (\(result.exitStatus))\n")
                }
                return CommandResult(exitStatus: 0)
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
        let args = vector.arguments
        if let refused = args.first(where: pmsetRefusedKeys.contains) {
            return CommandResult(exitStatus: 1,
                                 stderr: pmsetRefusesSilently ? "" : "pmset: \(refused) is not supported on this system\n")
        }
        if args.count == 3, args[1] == SystemCommands.energyModeKey, let value = Int(args[2]) {
            // `pmset -b lowpowermode N` / `pmset -c lowpowermode N`.
            if refusedEnergyModeValues.contains(value) {
                return CommandResult(exitStatus: 1, stderr: "pmset: \(args[1]) \(value) is not supported on this system\n")
            }
            guard let source = PowerSource.allCases.first(where: { $0.pmsetFlag == args[0] }) else {
                return unscripted(vector)
            }
            privilegedPmsetVectors.append(vector)
            if energyModeWritesApply {
                energyModes[source] = .some(value)
            }
            return CommandResult(exitStatus: 0)
        }
        privilegedPmsetVectors.append(vector)
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
    /// Called with every settings the coordinator hands over, before the outcome; lets a
    /// test pin the order of a save against other calls.
    var onSave: ((StoredSettings) -> Void)?

    init(_ stored: StoredSettings? = nil) {
        self.stored = stored
    }

    func load() -> StoredSettings {
        stored ?? StoredSettings()
    }

    func save(_ settings: StoredSettings) throws {
        saveCount += 1
        onSave?(settings)
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
