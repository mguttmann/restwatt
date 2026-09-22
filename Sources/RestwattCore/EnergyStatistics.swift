import Foundation

/// Where the statistics file lives, next to the settings file. The app layer resolves the
/// Library folder; the README quotes this path.
public enum StatisticsStoreLocation {
    public static let directoryName = SettingsStoreLocation.directoryName
    public static let fileName = "statistics.json"
    /// The path as documented in the README.
    public static let documentedPath = "~/Library/Application Support/Restwatt/statistics.json"
}

/// The statistics file.
public protocol StatisticsStoring {
    /// Defaults when there is no file or it cannot be read.
    func load() -> StoredStatistics
    func save(_ statistics: StoredStatistics) throws
}

/// One flow state's estimator as the last session left it.
public struct StoredEstimatorState: Equatable, Sendable {
    public var smoothedWatts: Double
    public var observedSeconds: TimeInterval
    public var sampleCount: Int
    /// Wall-clock time (unix seconds) of the last tick that showed this state.
    public var lastSampleAt: Double

    public init(smoothedWatts: Double, observedSeconds: TimeInterval, sampleCount: Int, lastSampleAt: Double) {
        self.smoothedWatts = smoothedWatts
        self.observedSeconds = observedSeconds
        self.sampleCount = sampleCount
        self.lastSampleAt = lastSampleAt
    }

    /// The staleness rule: what of this entry a new session may resume, or nil when it is
    /// better forgotten.
    ///
    /// A reboot (boot times known on both sides and further apart than
    /// `StoredStatistics.bootTimeTolerance`) forgets it: the workload is new. A clock that ran
    /// backwards forgets it. Otherwise the pause eats the observation window second for second,
    /// starting from at most `EnergyFlowEstimator.maximumRememberedObservation`: a restart after
    /// a few minutes keeps almost everything, a pause of an hour or more leaves nothing. What
    /// remains is the smoothed power with the shortened window, so a lower confidence and a
    /// smaller time constant.
    public func resumable(now: Date, storedBootTime: Double?, currentBootTime: Date?) -> EnergyFlowEstimator.Memory? {
        if let storedBootTime, let currentBootTime,
           abs(currentBootTime.timeIntervalSince1970 - storedBootTime) > StoredStatistics.bootTimeTolerance {
            return nil
        }
        guard smoothedWatts > 0, smoothedWatts.isFinite, sampleCount > 0 else {
            return nil
        }
        let gap = now.timeIntervalSince1970 - lastSampleAt
        guard gap >= 0 else {
            return nil
        }
        let remembered = min(observedSeconds, EnergyFlowEstimator.maximumRememberedObservation) - gap
        guard remembered > 0 else {
            return nil
        }
        return EnergyFlowEstimator.Memory(
            smoothedWatts: smoothedWatts, observedSeconds: remembered, sampleCount: sampleCount)
    }
}

/// Energy attributed to one process name over the day.
public struct DailyEnergyEntry: Equatable, Sendable {
    public var name: String
    public var wattHours: Double

    public init(name: String, wattHours: Double) {
        self.name = name
        self.wattHours = wattHours
    }
}

/// CPU energy per process name, summed over the sampled intervals of one local calendar day.
public struct DailyEnergyStatistic: Equatable, Sendable {
    /// Names kept; the smallest beyond this are folded into `otherWattHours` after every tick.
    public static let maximumNames = 20

    /// Local calendar day as `YYYY-MM-DD`.
    public var day: String
    /// Sorted by energy, descending, ties by name; at most `maximumNames`.
    public var entries: [DailyEnergyEntry]
    /// Energy of names that were evicted, so the total stays right.
    public var otherWattHours: Double
    /// Sum of the interval lengths that were counted.
    public var sampledSeconds: TimeInterval

    public init(day: String, entries: [DailyEnergyEntry] = [], otherWattHours: Double = 0,
                sampledSeconds: TimeInterval = 0) {
        self.day = day
        self.entries = entries
        self.otherWattHours = otherWattHours
        self.sampledSeconds = sampledSeconds
    }

    public var totalWattHours: Double {
        entries.reduce(otherWattHours) { $0 + $1.wattHours }
    }

    /// The day `date` falls on in `calendar`, as `YYYY-MM-DD`.
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Add one interval: `watts * dt` per name, then keep the `maximumNames` largest.
    public mutating func record(_ interval: [ProcessEnergyEntry], dt: TimeInterval) {
        guard dt > 0 else {
            return
        }
        var byName: [String: Double] = [:]
        for entry in entries {
            byName[entry.name] = entry.wattHours
        }
        for entry in interval {
            byName[entry.name, default: 0] += entry.watts * dt / 3600
        }
        let sorted = byName.map { DailyEnergyEntry(name: $0.key, wattHours: $0.value) }
            .sorted { lhs, rhs in
                if lhs.wattHours != rhs.wattHours {
                    return lhs.wattHours > rhs.wattHours
                }
                return lhs.name < rhs.name
            }
        entries = Array(sorted.prefix(Self.maximumNames))
        for evicted in sorted.dropFirst(Self.maximumNames) {
            otherWattHours += evicted.wattHours
        }
        sampledSeconds += dt
    }
}

/// What the statistics file remembers between launches. Never a log: three estimator entries
/// at most, one day of per-name energy, and two timestamps.
public struct StoredStatistics: Equatable, Sendable {
    /// Format version of the file; bumped when keys change meaning.
    public static let currentVersion = 1
    /// Boot times further apart than this mean a reboot happened in between.
    public static let bootTimeTolerance: TimeInterval = 60

    public var version: Int
    /// Wall-clock boot time (unix seconds) of the session that wrote the file, if known.
    public var bootTime: Double?
    /// Wall-clock time (unix seconds) of the write.
    public var savedAt: Double?
    /// Keyed by `PowerState.memoryKey`.
    public var estimators: [String: StoredEstimatorState]
    public var today: DailyEnergyStatistic?

    public init(version: Int = StoredStatistics.currentVersion,
                bootTime: Double? = nil,
                savedAt: Double? = nil,
                estimators: [String: StoredEstimatorState] = [:],
                today: DailyEnergyStatistic? = nil) {
        self.version = version
        self.bootTime = bootTime
        self.savedAt = savedAt
        self.estimators = estimators
        self.today = today
    }
}

/// JSON encoding of `StoredStatistics`. Tolerant on the way in: unknown keys are ignored,
/// missing keys mean defaults, unreadable data means defaults. Deterministic on the way out.
/// Timestamps are plain unix seconds, not Foundation's reference-date encoding of `Date`.
public enum StatisticsCodec {
    private struct EstimatorDocument: Codable {
        var smoothedWatts: Double?
        var observedSeconds: Double?
        var sampleCount: Int?
        var lastSampleAt: Double?
    }

    private struct EntryDocument: Codable {
        var name: String?
        var wattHours: Double?
    }

    private struct DayDocument: Codable {
        var day: String?
        var entries: [EntryDocument]?
        var otherWattHours: Double?
        var sampledSeconds: Double?
    }

    private struct Document: Codable {
        var version: Int?
        var bootTime: Double?
        var savedAt: Double?
        var estimators: [String: EstimatorDocument]?
        var today: DayDocument?
    }

    public static func encode(_ statistics: StoredStatistics) -> Data {
        var estimators: [String: EstimatorDocument] = [:]
        for (key, state) in statistics.estimators {
            estimators[key] = EstimatorDocument(
                smoothedWatts: state.smoothedWatts, observedSeconds: state.observedSeconds,
                sampleCount: state.sampleCount, lastSampleAt: state.lastSampleAt)
        }
        let today = statistics.today.map { day in
            DayDocument(
                day: day.day,
                entries: day.entries.map { EntryDocument(name: $0.name, wattHours: $0.wattHours) },
                otherWattHours: day.otherWattHours,
                sampledSeconds: day.sampledSeconds)
        }
        let document = Document(
            version: statistics.version, bootTime: statistics.bootTime, savedAt: statistics.savedAt,
            estimators: estimators, today: today)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of finite plain values cannot fail; an empty Data would decode to
        // defaults.
        return (try? encoder.encode(document)) ?? Data()
    }

    public static func decode(_ data: Data) -> StoredStatistics {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return StoredStatistics()
        }
        var estimators: [String: StoredEstimatorState] = [:]
        for (key, state) in document.estimators ?? [:] {
            estimators[key] = StoredEstimatorState(
                smoothedWatts: state.smoothedWatts ?? 0,
                observedSeconds: state.observedSeconds ?? 0,
                sampleCount: state.sampleCount ?? 0,
                lastSampleAt: state.lastSampleAt ?? 0)
        }
        var today: DailyEnergyStatistic?
        if let day = document.today?.day {
            today = DailyEnergyStatistic(
                day: day,
                entries: (document.today?.entries ?? []).compactMap { entry in
                    entry.name.map { DailyEnergyEntry(name: $0, wattHours: entry.wattHours ?? 0) }
                },
                otherWattHours: document.today?.otherWattHours ?? 0,
                sampledSeconds: document.today?.sampledSeconds ?? 0)
        }
        return StoredStatistics(
            version: document.version ?? StoredStatistics.currentVersion,
            bootTime: document.bootTime,
            savedAt: document.savedAt,
            estimators: estimators,
            today: today)
    }
}
