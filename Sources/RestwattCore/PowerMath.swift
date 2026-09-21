import Foundation

/// Pure arithmetic on a `BatterySnapshot`. Positive watts mean the battery is being drained.
public enum PowerMath {
    /// Below this draw a time-to-empty is meaningless (idle noise, or charging).
    public static let minimumDrawWatts: Double = 0.1
    /// Time-to-empty values are capped here; formatting shows "> 99 h" at the cap.
    public static let maximumMinutes = 5999
    /// If the gauge's own power figure and voltage times amperage disagree by more than this
    /// fraction, voltage times amperage wins (defensive against a semantic change of the key).
    public static let powerPlausibilityTolerance = 0.10

    /// Current battery draw in watts. Positive while discharging, negative while charging.
    public static func drawWatts(_ snapshot: BatterySnapshot) -> Double {
        let fromVoltageAndCurrent =
            Double(snapshot.voltageMilliVolts) * Double(snapshot.amperageMilliAmps) / 1000.0
        guard let reported = snapshot.batteryPowerMilliWatts else {
            return -fromVoltageAndCurrent / 1000.0
        }
        let reportedMilliWatts = Double(reported)
        let tolerance = abs(fromVoltageAndCurrent) * powerPlausibilityTolerance
        if abs(reportedMilliWatts - fromVoltageAndCurrent) > tolerance {
            return -fromVoltageAndCurrent / 1000.0
        }
        return -reportedMilliWatts / 1000.0
    }

    /// Energy left in the cell in watt-hours, from remaining charge and the present voltage.
    /// Deliberately not derived from the percentage: `FullChargeCapacity` drifts between reads.
    public static func remainingWattHours(_ snapshot: BatterySnapshot) -> Double {
        Double(snapshot.remainingCapacityMilliAmpHours) * Double(snapshot.voltageMilliVolts) / 1_000_000.0
    }

    /// Minutes until empty at a constant draw, or nil if the draw is too small to say.
    public static func minutesToEmpty(remainingWattHours: Double, watts: Double) -> Int? {
        guard watts >= minimumDrawWatts, remainingWattHours >= 0 else {
            return nil
        }
        let minutes = remainingWattHours / watts * 60.0
        if minutes >= Double(maximumMinutes) {
            return maximumMinutes
        }
        return Int(minutes.rounded())
    }
}
