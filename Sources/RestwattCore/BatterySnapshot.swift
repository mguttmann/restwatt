import Foundation

/// One reading of the battery gauge. Field names follow the IOKit AppleSmartBattery keys
/// they are filled from; the app layer maps the registry, this type carries plain numbers.
public struct BatterySnapshot: Equatable, Sendable {
    /// Gauge `UpdateTime` in unix seconds. The gauge refreshes about once a minute and all
    /// other values change only together with it, so this is the dedupe key for samples.
    public var updateTime: Int
    /// `Voltage` in millivolts.
    public var voltageMilliVolts: Int
    /// `Amperage` in milliamps, signed: negative while discharging.
    public var amperageMilliAmps: Int
    /// `BatteryData.BatteryPower` in milliwatts, signed like the amperage; nil if absent.
    public var batteryPowerMilliWatts: Int?
    /// `BatteryData.RemainingCapacity` in mAh.
    public var remainingCapacityMilliAmpHours: Int
    /// `BatteryData.FullChargeCapacity` in mAh (re-estimated by the gauge, drifts slightly).
    public var fullChargeCapacityMilliAmpHours: Int
    /// `BatteryData.DesignCapacity` in mAh.
    public var designCapacityMilliAmpHours: Int
    /// Top-level `CurrentCapacity`, a percentage on Apple silicon Macs.
    public var currentCapacityPercent: Int
    /// `IsCharging`.
    public var isCharging: Bool
    /// `ExternalConnected`.
    public var externalConnected: Bool
    /// `FullyCharged`.
    public var fullyCharged: Bool
    /// `AvgTimeToEmpty` in minutes; nil when the gauge reports 65535 or the key is absent.
    public var avgTimeToEmptyMinutes: Int?
    /// `AvgTimeToFull` in minutes; nil when the gauge reports 65535 or the key is absent.
    public var avgTimeToFullMinutes: Int?
    /// IOPowerSources `Time to Empty` in minutes (the estimate `pmset` shows); nil if negative.
    public var systemTimeToEmptyMinutes: Int?
    /// `AdapterDetails.Watts`, the external source's rating in watts; nil when no source is
    /// connected or the key is absent (a non-PD source may not report it).
    public var adapterWatts: Int?

    public init(
        updateTime: Int,
        voltageMilliVolts: Int,
        amperageMilliAmps: Int,
        batteryPowerMilliWatts: Int?,
        remainingCapacityMilliAmpHours: Int,
        fullChargeCapacityMilliAmpHours: Int,
        designCapacityMilliAmpHours: Int,
        currentCapacityPercent: Int,
        isCharging: Bool,
        externalConnected: Bool,
        fullyCharged: Bool,
        avgTimeToEmptyMinutes: Int?,
        avgTimeToFullMinutes: Int?,
        systemTimeToEmptyMinutes: Int?,
        adapterWatts: Int? = nil
    ) {
        self.updateTime = updateTime
        self.voltageMilliVolts = voltageMilliVolts
        self.amperageMilliAmps = amperageMilliAmps
        self.batteryPowerMilliWatts = batteryPowerMilliWatts
        self.remainingCapacityMilliAmpHours = remainingCapacityMilliAmpHours
        self.fullChargeCapacityMilliAmpHours = fullChargeCapacityMilliAmpHours
        self.designCapacityMilliAmpHours = designCapacityMilliAmpHours
        self.currentCapacityPercent = currentCapacityPercent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.avgTimeToEmptyMinutes = avgTimeToEmptyMinutes
        self.avgTimeToFullMinutes = avgTimeToFullMinutes
        self.systemTimeToEmptyMinutes = systemTimeToEmptyMinutes
        self.adapterWatts = adapterWatts
    }

    /// Where the Mac draws its power from right now, decided by the net energy flow of the
    /// battery rather than by the gauge's flags alone: a source that delivers less than the
    /// Mac uses leaves the battery draining even though `ExternalConnected` is set.
    /// `.powerSourceChanging` is never derived here; the monitor produces it (see there).
    public var powerState: PowerState {
        if !externalConnected {
            return .discharging
        }
        let net = PowerMath.drawWatts(self)
        if net >= PowerMath.flowDeadBandWatts {
            return .drainingOnExternalPower
        }
        if net <= -PowerMath.flowDeadBandWatts {
            return .charging
        }
        return .onExternalPower(fullyCharged: fullyCharged)
    }
}

/// Derived from `ExternalConnected` and the net energy flow; `FullyCharged` only matters
/// inside the dead band around zero flow.
public enum PowerState: Equatable, Sendable {
    /// No external source; the battery supplies everything.
    case discharging
    /// An external source is connected but delivers less than the Mac uses; the battery
    /// supplies the difference.
    case drainingOnExternalPower
    /// Energy flows into the battery.
    case charging
    /// An external source is connected and the net flow is inside the dead band.
    case onExternalPower(fullyCharged: Bool)
    /// The source was just plugged in or unplugged and the gauge reading still predates the
    /// change, so the flow figures do not describe the new situation yet.
    case powerSourceChanging

    /// Energy leaves the battery, with or without an external source.
    public var isDraining: Bool {
        self == .discharging || self == .drainingOnExternalPower
    }

    /// The battery is the only source, so its draw is the whole system draw.
    public var isOnBatteryOnly: Bool {
        self == .discharging
    }
}

/// Cumulative per-process counters from `proc_pid_rusage` (RUSAGE_INFO_V6).
public struct ProcessEnergySample: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    /// `ri_energy_nj`, cumulative energy the kernel attributes to the process, in nanojoules.
    public var energyNanoJoules: UInt64
    /// `ri_user_time + ri_system_time`, converted to seconds.
    public var cpuTimeSeconds: Double

    public init(pid: Int32, name: String, energyNanoJoules: UInt64, cpuTimeSeconds: Double) {
        self.pid = pid
        self.name = name
        self.energyNanoJoules = energyNanoJoules
        self.cpuTimeSeconds = cpuTimeSeconds
    }
}

/// Thrown by a `BatteryReading` when there is nothing to read.
public enum BatteryReadError: Error, Equatable, Sendable {
    /// No AppleSmartBattery service (desktop Mac, virtual machine, CI runner).
    case noBattery
    /// The service exists but a required key is missing or has an unexpected type.
    case malformed(key: String)
}

/// Hardware access sits behind these protocols so the core can be tested with doubles.
public protocol BatteryReading {
    func readBattery() throws -> BatterySnapshot
}

public protocol ProcessReading {
    func readProcesses() -> [ProcessEnergySample]
}

public protocol ClockReading {
    /// Seconds since an arbitrary fixed reference; only differences are used.
    var now: TimeInterval { get }
}
