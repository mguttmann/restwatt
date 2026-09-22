import Foundation

/// Pure arithmetic on a `BatterySnapshot`. Positive watts mean the battery is being drained.
public enum PowerMath {
    /// Below this power a time estimate is meaningless (idle noise).
    public static let minimumDrawWatts: Double = 0.1
    /// Net flow within this band around zero counts as neither draining nor charging while
    /// an external source is connected. Chosen without a measurement between zero and the
    /// smallest observed real discharge: at battery voltage it is tens of milliamps, far
    /// above the gauge's resolution and far below any observed real draw or charge, and it
    /// lies entirely where a time figure would already sit at the display cap.
    public static let flowDeadBandWatts: Double = 0.5
    /// Time estimates are capped here; formatting shows "> 99 h" at the cap.
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

    /// Energy still missing to a full charge in watt-hours, from the gap between full-charge
    /// and remaining capacity at the present voltage. Never negative: the gauge's
    /// `FullChargeCapacity` drifts and can briefly sit below the remaining charge.
    public static func missingWattHours(_ snapshot: BatterySnapshot) -> Double {
        let missing = max(0, snapshot.fullChargeCapacityMilliAmpHours - snapshot.remainingCapacityMilliAmpHours)
        return Double(missing) * Double(snapshot.voltageMilliVolts) / 1_000_000.0
    }

    /// Minutes until `energyWattHours` is moved at a constant power (to empty while draining,
    /// to full while charging), or nil if the power is too small to say.
    public static func minutes(energyWattHours: Double, watts: Double) -> Int? {
        guard watts >= minimumDrawWatts, energyWattHours >= 0 else {
            return nil
        }
        let minutes = energyWattHours / watts * 60.0
        if minutes >= Double(maximumMinutes) {
            return maximumMinutes
        }
        return Int(minutes.rounded())
    }
}
