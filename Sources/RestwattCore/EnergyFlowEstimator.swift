import Foundation

/// How much observation backs the smoothed estimate.
public enum Confidence: String, Equatable, Sendable {
    case low
    case medium
    case high
}

/// The estimator's current answer.
public struct Estimate: Equatable, Sendable {
    /// Power of the most recent sample, in watts (always positive; the direction is the
    /// monitor's business).
    public var instantWatts: Double
    /// Adaptively smoothed power, in watts.
    public var smoothedWatts: Double
    /// Minutes until the target (empty while draining, full while charging) at the most recent
    /// power ("if it keeps going like right now").
    public var instantMinutes: Int?
    /// Minutes until the target at the smoothed power. Shown in the menu bar.
    public var smoothedMinutes: Int?
    /// Seconds between the first and the latest accepted sample.
    public var observedSeconds: TimeInterval
    /// Number of accepted samples.
    public var sampleCount: Int
    public var confidence: Confidence
}

/// Adaptive exponentially weighted moving average of the energy flow through the battery,
/// in either direction: fed with the draw and the remaining energy while draining, with the
/// charging power and the missing energy while charging.
///
/// The very first sample is taken as is, so the first estimate equals "at current power".
/// The time constant grows with the observation window (`observed / rampDivisor`, clamped to
/// `[tauMin, tauMax]`), so early samples move the estimate a lot and, after half an hour,
/// a single noisy gauge reading barely moves it. A lasting change in power still shows up
/// within a few multiples of `tauMax`.
public struct EnergyFlowEstimator: Equatable, Sendable {
    /// Smallest time constant, used while the observation window is short.
    public static let tauMin: TimeInterval = 60
    /// Largest time constant, reached after `tauMax * rampDivisor` seconds of observation.
    public static let tauMax: TimeInterval = 1800
    /// The time constant is the observation window divided by this.
    public static let rampDivisor: Double = 2
    /// Observation needed for medium confidence, in seconds.
    public static let mediumConfidenceSeconds: TimeInterval = 300
    /// Observation needed for high confidence, in seconds.
    public static let highConfidenceSeconds: TimeInterval = 1800

    private var smoothedWatts: Double = 0
    private var latestWatts: Double = 0
    private var latestEnergyWattHours: Double = 0
    private var observedSeconds: TimeInterval = 0
    private var lastSampleTime: TimeInterval?
    private var sampleCount = 0

    public init() {}

    /// Feed one sample: the energy still to be moved and the power moving it, both positive.
    /// Samples with a non-positive power, or not later than the previous one, are ignored.
    public mutating func add(time: TimeInterval, energyWattHours: Double, watts: Double) {
        guard watts > 0 else {
            return
        }
        if let last = lastSampleTime {
            let dt = time - last
            guard dt > 0 else {
                return
            }
            observedSeconds += dt
            let tau = min(max(observedSeconds / Self.rampDivisor, Self.tauMin), Self.tauMax)
            let alpha = 1 - exp(-dt / tau)
            smoothedWatts += alpha * (watts - smoothedWatts)
        } else {
            smoothedWatts = watts
            observedSeconds = 0
        }
        latestWatts = watts
        latestEnergyWattHours = energyWattHours
        lastSampleTime = time
        sampleCount += 1
    }

    /// Current estimate, or nil before the first accepted sample.
    public var estimate: Estimate? {
        guard sampleCount > 0 else {
            return nil
        }
        return Estimate(
            instantWatts: latestWatts,
            smoothedWatts: smoothedWatts,
            instantMinutes: PowerMath.minutes(energyWattHours: latestEnergyWattHours, watts: latestWatts),
            smoothedMinutes: PowerMath.minutes(energyWattHours: latestEnergyWattHours, watts: smoothedWatts),
            observedSeconds: observedSeconds,
            sampleCount: sampleCount,
            confidence: Self.confidence(observedSeconds: observedSeconds)
        )
    }

    /// Forget everything, for example when the direction of the energy flow flips.
    public mutating func reset() {
        self = EnergyFlowEstimator()
    }

    static func confidence(observedSeconds: TimeInterval) -> Confidence {
        if observedSeconds < mediumConfidenceSeconds {
            return .low
        }
        if observedSeconds < highConfidenceSeconds {
            return .medium
        }
        return .high
    }
}
