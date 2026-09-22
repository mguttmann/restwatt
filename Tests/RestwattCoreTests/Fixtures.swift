import Foundation
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
