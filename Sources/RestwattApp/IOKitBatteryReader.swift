import Foundation
import IOKit
import IOKit.ps
import RestwattCore

/// Reads the AppleSmartBattery registry entry and the IOPowerSources time estimate.
/// Only the keys listed here are read (including `AdapterDetails.Watts`, the external
/// source's rating); nothing is logged.
struct IOKitBatteryReader: BatteryReading {
    /// The gauge reports this value when a time is unknown.
    private static let unknownMinutes = 65535

    func readBattery() throws -> BatterySnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            throw BatteryReadError.noBattery
        }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            throw BatteryReadError.noBattery
        }
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        // `AdapterDetails` exists without a source too, but then carries no `Watts` key.
        // `PowerOutDetails` has a `Watts` key as well; that one is USB port telemetry, not it.
        let adapterDetails = properties["AdapterDetails"] as? [String: Any] ?? [:]

        // Top-level CurrentCapacity is a percentage on Apple silicon Macs; the gauge key
        // semantics were only verified there. A value outside 0...100 is treated as
        // unreadable rather than shown as a percentage.
        let currentCapacityPercent = try Self.int(properties, "CurrentCapacity")
        guard (0...100).contains(currentCapacityPercent) else {
            throw BatteryReadError.malformed(key: "CurrentCapacity")
        }

        return BatterySnapshot(
            updateTime: try Self.int(properties, "UpdateTime"),
            voltageMilliVolts: try Self.int(properties, "Voltage"),
            amperageMilliAmps: try Self.int(properties, "Amperage"),
            batteryPowerMilliWatts: batteryData["BatteryPower"] as? Int,
            remainingCapacityMilliAmpHours: try Self.int(batteryData, "RemainingCapacity"),
            fullChargeCapacityMilliAmpHours: try Self.int(batteryData, "FullChargeCapacity"),
            designCapacityMilliAmpHours: try Self.int(batteryData, "DesignCapacity"),
            currentCapacityPercent: currentCapacityPercent,
            isCharging: properties["IsCharging"] as? Bool ?? false,
            externalConnected: properties["ExternalConnected"] as? Bool ?? false,
            fullyCharged: properties["FullyCharged"] as? Bool ?? false,
            avgTimeToEmptyMinutes: Self.knownMinutes(properties["AvgTimeToEmpty"]),
            avgTimeToFullMinutes: Self.knownMinutes(properties["AvgTimeToFull"]),
            systemTimeToEmptyMinutes: Self.systemTimeToEmptyMinutes(),
            adapterWatts: adapterDetails["Watts"] as? Int
        )
    }

    private static func int(_ dictionary: [String: Any], _ key: String) throws -> Int {
        guard let value = dictionary[key] as? Int else {
            throw BatteryReadError.malformed(key: key)
        }
        return value
    }

    private static func knownMinutes(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes >= 0, minutes != unknownMinutes else {
            return nil
        }
        return minutes
    }

    /// `kIOPSTimeToEmptyKey` of the first internal battery; nil while macOS is still computing.
    private static func systemTimeToEmptyMinutes() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let minutes = description[kIOPSTimeToEmptyKey] as? Int else {
                continue
            }
            return minutes >= 0 ? minutes : nil
        }
        return nil
    }
}
