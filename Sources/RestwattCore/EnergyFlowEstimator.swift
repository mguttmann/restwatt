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
///
/// An estimator can be resumed from a `Memory` (smoothed power, observation window, sample
/// count) that an earlier session left behind. The first sample after a resume only sets the
/// instant values and the session time anchor; it does not move the smoothed power, because
/// no in-session `dt` exists yet. From the second sample on the smoothing continues with the
/// time constant the remembered window implies. Before that first sample `estimate` is nil.
public struct EnergyFlowEstimator: Equatable, Sendable {
    /// What survives between sessions: the smoothed power and the observation behind it.
    /// Times are not part of it; the session clock is uptime, which does not survive a reboot.
    public struct Memory: Equatable, Sendable {
        public var smoothedWatts: Double
        public var observedSeconds: TimeInterval
        public var sampleCount: Int

        public init(smoothedWatts: Double, observedSeconds: TimeInterval, sampleCount: Int) {
            self.smoothedWatts = smoothedWatts
            self.observedSeconds = observedSeconds
            self.sampleCount = sampleCount
        }
    }

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
    /// Observation beyond this changes nothing (tau is at `tauMax`), so no more than this is
    /// worth remembering across sessions.
    public static let maximumRememberedObservation: TimeInterval = tauMax * rampDivisor

    private var smoothedWatts: Double = 0
    private var latestWatts: Double = 0
    private var latestEnergyWattHours: Double = 0
    private var observedSeconds: TimeInterval = 0
    private var lastSampleTime: TimeInterval?
    private var sampleCount = 0

    public init() {}

    /// Continue an earlier session's smoothing. The latest values stay empty and there is no
    /// session time anchor until the first sample arrives.
    public init(resuming memory: Memory) {
        smoothedWatts = memory.smoothedWatts
        observedSeconds = memory.observedSeconds
        sampleCount = memory.sampleCount
    }

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
        } else if sampleCount == 0 {
            smoothedWatts = watts
            observedSeconds = 0
        }
        latestWatts = watts
        latestEnergyWattHours = energyWattHours
        lastSampleTime = time
        sampleCount += 1
    }

    /// Current estimate, or nil before the first accepted sample of this session.
    public var estimate: Estimate? {
        guard sampleCount > 0, lastSampleTime != nil else {
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

    /// What a later session can resume from; nil while no sample has ever been accepted.
    public var memory: Memory? {
        guard sampleCount > 0 else {
            return nil
        }
        return Memory(smoothedWatts: smoothedWatts, observedSeconds: observedSeconds, sampleCount: sampleCount)
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
