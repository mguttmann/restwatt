import Foundation

/// What Restwatt remembers between launches: the estimator of each flow state and the day's
/// energy per process name. Loaded once, kept in memory, written back at most once per tick
/// and when the app quits, and only when something changed. A write that fails is retried on
/// the next tick and never shown.
///
/// A reboot is judged once, at load: when the file's boot time and the current one are both
/// known and further apart than `StoredStatistics.bootTimeTolerance`, every estimator entry
/// is dropped from the loaded model, so the first write of this session no longer carries
/// pre-reboot entries under the new boot time. A file written by a newer Restwatt is read as
/// empty and never written.
public final class EnergyMemory {
    private let store: StatisticsStoring
    private let wallClock: WallClockReading
    private let calendar: Calendar
    private var stored: StoredStatistics
    /// What the store holds, as far as this session knows.
    private var persisted: StoredStatistics
    /// The file belongs to a newer format; this session keeps its statistic in memory only.
    private let readOnly: Bool

    public init(store: StatisticsStoring, wallClock: WallClockReading, calendar: Calendar) {
        self.store = store
        self.wallClock = wallClock
        self.calendar = calendar
        stored = store.load()
        persisted = stored
        readOnly = stored.isNewerFormat
        if let storedBootTime = stored.bootTime, let currentBootTime = wallClock.bootTime,
           abs(currentBootTime.timeIntervalSince1970 - storedBootTime) > StoredStatistics.bootTimeTolerance {
            stored.estimators = [:]
        }
    }

    /// The estimator to continue with when `key` is shown for the first time this session:
    /// resumed from the file when the staleness rule allows it, fresh otherwise.
    public func resume(_ key: String) -> EnergyFlowEstimator {
        guard let state = stored.estimators[key],
              let memory = state.resumable(
                now: wallClock.now, storedBootTime: stored.bootTime, currentBootTime: wallClock.bootTime) else {
            return EnergyFlowEstimator()
        }
        return EnergyFlowEstimator(resuming: memory)
    }

    /// Note the estimator of `key` as it is right now; the wall clock marks when.
    ///
    /// An entry already remembered for `key` is kept while a resume right now would give it a
    /// longer observation window than this estimator carries: a short flip within the session
    /// (plug in for a minute, unplug) restarts the estimator but must not erase an hour of
    /// remembered observation. The remembered entry ages second for second while the fresh
    /// one grows, so the fresh one takes over as soon as its window is the longer.
    public func remember(_ estimator: EnergyFlowEstimator, for key: String) {
        guard let memory = estimator.memory else {
            return
        }
        let now = wallClock.now
        if let current = stored.estimators[key],
           min(memory.observedSeconds, EnergyFlowEstimator.maximumRememberedObservation) < current.resumableSeconds(now: now) {
            return
        }
        stored.estimators[key] = StoredEstimatorState(
            smoothedWatts: memory.smoothedWatts,
            observedSeconds: memory.observedSeconds,
            sampleCount: memory.sampleCount,
            lastSampleAt: now.timeIntervalSince1970)
    }

    /// Count one interval of per-name power into the current day. The first interval of a new
    /// calendar day starts a fresh statistic; the interval that spans midnight counts to the
    /// new day.
    public func record(_ interval: [ProcessEnergyEntry], dt: TimeInterval) {
        guard dt > 0 else {
            return
        }
        let day = DailyEnergyStatistic.dayKey(for: wallClock.now, calendar: calendar)
        var today = stored.today.flatMap { $0.day == day ? $0 : nil } ?? DailyEnergyStatistic(day: day)
        today.record(interval, dt: dt)
        stored.today = today
    }

    /// The current day's statistic, or nil while nothing of this day has been sampled.
    public var today: DailyEnergyStatistic? {
        guard let today = stored.today, today.sampledSeconds > 0,
              today.day == DailyEnergyStatistic.dayKey(for: wallClock.now, calendar: calendar) else {
            return nil
        }
        return today
    }

    /// Write the file if anything changed since the last successful write; never over a file
    /// of a newer format.
    public func saveIfChanged() {
        guard !readOnly, stored != persisted else {
            return
        }
        var document = stored
        document.version = StoredStatistics.currentVersion
        document.bootTime = wallClock.bootTime?.timeIntervalSince1970
        document.savedAt = wallClock.now.timeIntervalSince1970
        do {
            try store.save(document)
            stored = document
            persisted = document
        } catch {
            // Retried on the next tick; the statistic lives on in memory meanwhile.
        }
    }
}
