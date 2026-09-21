import Foundation

/// How much observation backs the smoothed estimate.
public enum Confidence: String, Equatable, Sendable {
    case low
    case medium
    case high
}

/// The estimator's current answer.
public struct Estimate: Equatable, Sendable {
    /// Draw of the most recent sample, in watts.
    public var instantWatts: Double
    /// Adaptively smoothed draw, in watts.
    public var smoothedWatts: Double
    /// Minutes to empty at the most recent draw ("if it keeps drawing like right now").
    public var instantMinutes: Int?
    /// Minutes to empty at the smoothed draw. Shown in the menu bar.
    public var smoothedMinutes: Int?
    /// Seconds between the first and the latest accepted sample.
    public var observedSeconds: TimeInterval
    /// Number of accepted samples.
    public var sampleCount: Int
    public var confidence: Confidence
}

/// Adaptive exponentially weighted moving average of the battery draw.
///
/// The very first sample is taken as is, so the first estimate equals "at current draw".
/// The time constant grows with the observation window (`observed / rampDivisor`, clamped to
/// `[tauMin, tauMax]`), so early samples move the estimate a lot and, after half an hour,
/// a single noisy gauge reading barely moves it. A lasting change in draw still shows up
/// within a few multiples of `tauMax`.
public struct TimeToEmptyEstimator: Equatable, Sendable {
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
    private var latestRemainingWattHours: Double = 0
    private var observedSeconds: TimeInterval = 0
    private var lastSampleTime: TimeInterval?
    private var sampleCount = 0

    public init() {}

    /// Feed one discharge sample. Samples with a non-positive draw, or not later than the
    /// previous one, are ignored.
    public mutating func add(time: TimeInterval, remainingWattHours: Double, drawWatts: Double) {
        guard drawWatts > 0 else {
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
            smoothedWatts += alpha * (drawWatts - smoothedWatts)
        } else {
            smoothedWatts = drawWatts
            observedSeconds = 0
        }
        latestWatts = drawWatts
        latestRemainingWattHours = remainingWattHours
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
            instantMinutes: PowerMath.minutesToEmpty(
                remainingWattHours: latestRemainingWattHours, watts: latestWatts),
            smoothedMinutes: PowerMath.minutesToEmpty(
                remainingWattHours: latestRemainingWattHours, watts: smoothedWatts),
            observedSeconds: observedSeconds,
            sampleCount: sampleCount,
            confidence: Self.confidence(observedSeconds: observedSeconds)
        )
    }

    /// Forget everything, for example when the Mac is plugged in.
    public mutating func reset() {
        self = TimeToEmptyEstimator()
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
