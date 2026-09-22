import Foundation

/// What Restwatt remembers between launches: the estimator of each flow state and the day's
/// energy per process name. Loaded once, kept in memory, written back at most once per tick
/// and when the app quits, and only when something changed. A write that fails is retried on
/// the next tick and never shown.
public final class EnergyMemory {
    private let store: StatisticsStoring
    private let wallClock: WallClockReading
    private let calendar: Calendar
    private var stored: StoredStatistics
    /// What the store holds, as far as this session knows.
    private var persisted: StoredStatistics
    /// Boot time the file was written under; compared against the current one when a state
    /// is resumed, so a reboot forgets every stored estimator even after the file was
    /// rewritten in this session.
    private let loadedBootTime: Double?

    public init(store: StatisticsStoring, wallClock: WallClockReading, calendar: Calendar) {
        self.store = store
        self.wallClock = wallClock
        self.calendar = calendar
        stored = store.load()
        persisted = stored
        loadedBootTime = stored.bootTime
    }

    /// The estimator to continue with when `key` is shown for the first time this session:
    /// resumed from the file when the staleness rule allows it, fresh otherwise.
    public func resume(_ key: String) -> EnergyFlowEstimator {
        guard let state = stored.estimators[key],
              let memory = state.resumable(
                now: wallClock.now, storedBootTime: loadedBootTime, currentBootTime: wallClock.bootTime) else {
            return EnergyFlowEstimator()
        }
        return EnergyFlowEstimator(resuming: memory)
    }

    /// Note the estimator of `key` as it is right now; the wall clock marks when.
    public func remember(_ estimator: EnergyFlowEstimator, for key: String) {
        guard let memory = estimator.memory else {
            return
        }
        stored.estimators[key] = StoredEstimatorState(
            smoothedWatts: memory.smoothedWatts,
            observedSeconds: memory.observedSeconds,
            sampleCount: memory.sampleCount,
            lastSampleAt: wallClock.now.timeIntervalSince1970)
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

    /// Write the file if anything changed since the last successful write.
    public func saveIfChanged() {
        guard stored != persisted else {
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
