import Foundation

/// The unplug Restwatt knows about: when the last external source went away, as unix seconds,
/// and the charge at that moment. Persisted in the statistics file.
public struct UnplugRecord: Equatable, Sendable {
    public enum Precision: String, Equatable, Sendable {
        /// The unplug itself: seen live, or bracketed closely by the power log.
        case exact
        /// The Mac has been on battery at least since then; the unplug may be earlier.
        case lowerBound
    }

    /// How far in the future a record may lie before it is taken as the product of a clock
    /// that was set back.
    public static let futureTolerance: TimeInterval = 60

    public var unpluggedAt: Double
    /// Only known for an exact record.
    public var percent: Int?
    public var precision: Precision

    public init(unpluggedAt: Double, percent: Int? = nil, precision: Precision) {
        self.unpluggedAt = unpluggedAt
        self.percent = percent
        self.precision = precision
    }

    /// Finite, not before 1970, and a charge of 0 to 100 if there is one. The codec drops a
    /// record that is not.
    public var isPlausible: Bool {
        unpluggedAt.isFinite && unpluggedAt >= 0 && (percent.map { (0...100).contains($0) } ?? true)
    }

    /// Plausible and not more than `futureTolerance` after `now`.
    public func isPlausible(now: Date) -> Bool {
        isPlausible && unpluggedAt <= now.timeIntervalSince1970 + Self.futureTolerance
    }
}

/// What the popover and the click menu show while no external source is connected.
public struct OnBatteryPeriod: Equatable, Sendable {
    public var since: Date
    public var now: Date
    /// Charge at the unplug; only for an exact period.
    public var percentAtUnplug: Int?
    public var precision: UnplugRecord.Precision
    /// Calendar for the clock time and the day of `since`.
    public var calendar: Calendar

    public init(since: Date, now: Date, percentAtUnplug: Int?, precision: UnplugRecord.Precision, calendar: Calendar) {
        self.since = since
        self.now = now
        self.percentAtUnplug = percentAtUnplug
        self.precision = precision
        self.calendar = calendar
    }
}

/// Keeps track of the current battery period on the wall clock, sleep included.
///
/// An unplug seen live (a tick with an external source, then one without, at most
/// `maximumObservationGap` apart) is exact and carries the charge of the first battery tick.
/// Every tick with an external source, a weak one included, clears the record. A session that
/// starts on battery, an unplug seen only across a longer gap, and a charge that rose while on
/// battery across such a gap (plugged in while asleep) show the honest lower bound "since the
/// first battery tick" and ask once for the power log, which may refine it. A record from an
/// earlier session is never shown before the log confirms that no external source and no
/// unvetted boot came after it, and never when this session's first battery tick reads a
/// higher charge than it. A read that fails says nothing either way: a reboot alone does not
/// invalidate that record, so it is kept unless the first tick refuted it. The log's own
/// exact start is vetted the same way: it needs a known charge that this session's first
/// battery tick does not exceed, or it is only a lower bound.
public final class BatteryPeriodTracker {
    /// Two ticks: a longer wall-clock gap between the last external tick and the first battery
    /// tick means the unplug was not watched (the Mac slept in between).
    public static let maximumObservationGap: TimeInterval = 2 * Sampling.interval

    private let wallClock: WallClockReading
    private let calendar: Calendar
    private let memory: EnergyMemory?

    /// The record of this session's current period.
    private var record: UnplugRecord?
    /// An exact record of an earlier session, waiting for the log to confirm it.
    private var storedCandidate: UnplugRecord?
    private var onExternal = false
    private var lastExternalSeenAt: Date?
    private var lastBatteryTick: (at: Date, percent: Int)?
    private var sessionBatteryStart: Date?
    /// Charge of the first battery tick of the period in this session.
    private var sessionBatteryStartPercent: Int?
    private var periodID = 0
    private var logRequestedInPeriod = false
    private var pendingRequest: PowerLogRequest?

    public init(wallClock: WallClockReading, calendar: Calendar, memory: EnergyMemory?) {
        self.wallClock = wallClock
        self.calendar = calendar
        self.memory = memory
        if let stored = memory?.unplug, stored.precision == .exact {
            storedCandidate = stored
        }
    }

    /// One successful battery reading.
    public func observe(externalConnected: Bool, percent: Int) {
        let now = wallClock.now
        if externalConnected {
            if !onExternal {
                startNewPeriod()
            }
            onExternal = true
            storedCandidate = nil
            record = nil
            lastExternalSeenAt = now
            lastBatteryTick = nil
            persist()
            return
        }
        let wasOnExternal = onExternal
        onExternal = false
        defer {
            lastBatteryTick = (now, percent)
        }
        if let lastBatteryTick, let start = sessionBatteryStart {
            let gap = now.timeIntervalSince(lastBatteryTick.at)
            if gap > Self.maximumObservationGap, percent > lastBatteryTick.percent {
                // The charge rose while no tick watched: an external source came and went.
                startNewPeriod()
                storedCandidate = nil
                beginUnobserved(at: now, percent: percent)
                return
            }
            if let record, record.unpluggedAt > now.timeIntervalSince1970 + UnplugRecord.futureTolerance
                || start.timeIntervalSince1970 > now.timeIntervalSince1970 + UnplugRecord.futureTolerance {
                // The clock was set back; only the present is certain.
                sessionBatteryStart = now
                self.record = UnplugRecord(unpluggedAt: now.timeIntervalSince1970, precision: .lowerBound)
                persist()
            }
            return
        }
        if wasOnExternal, let lastExternalSeenAt,
           (0...Self.maximumObservationGap).contains(now.timeIntervalSince(lastExternalSeenAt)) {
            sessionBatteryStart = now
            sessionBatteryStartPercent = percent
            record = UnplugRecord(unpluggedAt: now.timeIntervalSince1970, percent: percent, precision: .exact)
            storedCandidate = nil
            persist()
            return
        }
        if let candidate = storedCandidate, let unplugPercent = candidate.percent, percent > unplugPercent {
            // Charged since the earlier session's unplug: an external source came after it.
            storedCandidate = nil
        }
        beginUnobserved(at: now, percent: percent)
    }

    /// The read to run, at most once per period; nil when none is due.
    public func takePowerLogRequest() -> PowerLogRequest? {
        defer {
            pendingRequest = nil
        }
        return pendingRequest
    }

    /// The answer to `request`; ignored when the period has ended since.
    public func apply(_ outcome: PowerLogOutcome, for request: PowerLogRequest) {
        guard request.periodID == periodID, !onExternal, sessionBatteryStart != nil else {
            return
        }
        let start = request.sessionBatteryStart.timeIntervalSince1970
        let candidate = storedCandidate
        storedCandidate = nil
        let fallback = UnplugRecord(unpluggedAt: start, precision: .lowerBound)
        guard case .summary(let summary) = outcome else {
            // A failed read observed no plug-in; the first tick did not refute the candidate
            // either, or it would be gone. That counter-signal can only fire below 100 %: at a
            // full battery a charge while off leaves no trace, so such a candidate is not kept.
            // (A charge limit below 100 % is not known here and stays a documented gap.)
            if let candidate, candidate.unpluggedAt <= start, Self.counterSignalCanFire(for: candidate) {
                record = candidate
            } else {
                record = fallback
            }
            persist()
            return
        }
        guard summary.endsOnBattery, let batterySince = summary.batterySince else {
            record = fallback
            persist()
            return
        }
        if let lastExternalAt = summary.lastExternalAt, lastExternalAt > start {
            // An external source came and went while the log was read; the log saw it.
            record = UnplugRecord(unpluggedAt: batterySince, percent: summary.percent, precision: summary.precision)
            persist()
            return
        }
        // The earlier session watched the unplug live; the log has to show that no boot it did
        // not vet came after its last external line and that no external source came after the
        // candidate. A log that does not reach back to an external line confirms nothing.
        if let candidate, Self.logConfirms(candidate, summary: summary, start: start) {
            record = candidate
            persist()
            return
        }
        let since = min(batterySince, start)
        let precision = summary.precision(since: since)
        if precision == .exact, since == batterySince {
            guard let logPercent = summary.percent else {
                // No charge at the log's start to hold this session's first tick against.
                record = UnplugRecord(unpluggedAt: since, precision: .lowerBound)
                persist()
                return
            }
            // Held against the last charge the log saw in the period, not the start charge: a
            // first tick above it means a charge after that line the log did not record.
            if let first = sessionBatteryStartPercent, first > (summary.lastPercent ?? logPercent) {
                // Charged after the log's last battery line without the log seeing it: the
                // log's lines are no evidence, only this session's first tick is.
                record = fallback
                persist()
                return
            }
        }
        record = UnplugRecord(
            unpluggedAt: since, percent: precision == .exact && since == batterySince ? summary.percent : nil,
            precision: precision)
        persist()
    }

    /// Whether the first-tick counter-signal (a higher charge than at the unplug) could have
    /// revealed a charge while off: only when the recorded charge is known and below 100 %.
    static func counterSignalCanFire(for candidate: UnplugRecord) -> Bool {
        guard let percent = candidate.percent else {
            return false
        }
        return percent < 100
    }

    /// Whether the log backs an earlier session's live unplug: the candidate lies before this
    /// session's first battery tick, the log has an external line, the scanner reports no
    /// unvetted boot after that line (the one signal for an unwatched restart), and that line
    /// is not after the candidate.
    static func logConfirms(_ candidate: UnplugRecord, summary: PowerLogSummary, start: Double) -> Bool {
        guard candidate.unpluggedAt <= start, let lastExternalAt = summary.lastExternalAt,
              !summary.unvettedBootAfterExternal else {
            return false
        }
        return lastExternalAt <= candidate.unpluggedAt + UnplugRecord.futureTolerance
    }

    /// The period to show; nil while an external source is connected or before the first tick.
    public var current: OnBatteryPeriod? {
        guard !onExternal, let record else {
            return nil
        }
        return OnBatteryPeriod(
            since: Date(timeIntervalSince1970: record.unpluggedAt), now: wallClock.now,
            percentAtUnplug: record.precision == .exact ? record.percent : nil,
            precision: record.precision, calendar: calendar)
    }

    private func startNewPeriod() {
        periodID += 1
        sessionBatteryStart = nil
        sessionBatteryStartPercent = nil
        logRequestedInPeriod = false
        pendingRequest = nil
    }

    /// A battery period whose start no tick watched: the lower bound now, and one log read.
    private func beginUnobserved(at now: Date, percent: Int) {
        sessionBatteryStart = now
        sessionBatteryStartPercent = percent
        record = UnplugRecord(unpluggedAt: now.timeIntervalSince1970, precision: .lowerBound)
        if !logRequestedInPeriod {
            logRequestedInPeriod = true
            pendingRequest = PowerLogRequest(periodID: periodID, sessionBatteryStart: now)
        }
        persist()
    }

    /// The file holds the confirmed record, or, while the log is still out, the earlier
    /// session's candidate, so quitting before the answer loses nothing.
    private func persist() {
        memory?.unplug = storedCandidate ?? record
    }
}
