import Foundation
import RestwattCore

/// Realistic numbers measured on an Apple silicon MacBook Pro. No strings from the registry.
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
