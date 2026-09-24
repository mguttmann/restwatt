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
    /// Generous physical ceilings for a file entry; the largest USB-C adapter delivers 240 W,
    /// and no estimator observes longer than a year. Anything beyond is not a measurement.
    public static let maximumSmoothedWatts: Double = 1000
    public static let maximumObservedSeconds: TimeInterval = 366 * 86400
    /// One sample per second for a year.
    public static let maximumSampleCount = Int(maximumObservedSeconds)

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

    /// Whether every figure is finite, non-negative and within its ceiling; the codec drops
    /// entries that are not, so nothing downstream converts an absurd value.
    public var isPlausible: Bool {
        (0...Self.maximumSmoothedWatts).contains(smoothedWatts)
            && (0...Self.maximumObservedSeconds).contains(observedSeconds)
            && (0...Self.maximumSampleCount).contains(sampleCount)
            && lastSampleAt.isFinite && lastSampleAt >= 0
    }

    /// The observation window a resume at `now` would get, or 0 when the entry is expired.
    /// This is the currency in which two entries for the same state are compared.
    func resumableSeconds(now: Date) -> TimeInterval {
        resumable(now: now, storedBootTime: nil, currentBootTime: nil)?.observedSeconds ?? 0
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

    /// Longest name kept; `proc_name` never returns more than this many bytes.
    public static let maximumNameBytes = 255

    /// A non-empty name of at most `maximumNameBytes`, and a finite, non-negative energy
    /// within `DailyEnergyStatistic.maximumWattHours`.
    public var isPlausible: Bool {
        !name.isEmpty && name.utf8.count <= Self.maximumNameBytes
            && (0...DailyEnergyStatistic.maximumWattHours).contains(wattHours)
    }
}

/// CPU energy per process name, summed over the sampled intervals of one local calendar day.
public struct DailyEnergyStatistic: Equatable, Sendable {
    /// Names kept; the smallest beyond this are folded into `otherWattHours` after every tick.
    public static let maximumNames = 20
    /// Generous physical ceilings for a file entry: a kilowatt for a whole day per figure, and
    /// no more sampled seconds than a week holds. Anything beyond is not a measurement.
    public static let maximumWattHours: Double = 1000 * 24
    public static let maximumSampledSeconds: TimeInterval = 7 * 86400

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

    /// Whether the day key has the `YYYY-MM-DD` shape and the day's own figures are finite,
    /// non-negative and within their ceilings. The entries are judged one by one by
    /// `DailyEnergyEntry.isPlausible`.
    public var isPlausible: Bool {
        Self.isDayKey(day)
            && (0...Self.maximumWattHours).contains(otherWattHours)
            && (0...Self.maximumSampledSeconds).contains(sampledSeconds)
    }

    /// `YYYY-MM-DD`: ten ASCII characters, digits with hyphens at the two expected places.
    static func isDayKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 10 else {
            return false
        }
        for (index, scalar) in scalars.enumerated() {
            let expectHyphen = index == 4 || index == 7
            if expectHyphen ? scalar != "-" : !("0"..."9").contains(scalar) {
                return false
            }
        }
        return true
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
        entries = byName.map { DailyEnergyEntry(name: $0.key, wattHours: $0.value) }
        bound()
        sampledSeconds += dt
    }

    /// Sort the entries by energy, descending, ties by name, and fold everything beyond
    /// `maximumNames` into `otherWattHours`. `record` does this after every tick; the codec
    /// does it to a file that carries more names than this app writes.
    public mutating func bound() {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.wattHours != rhs.wattHours {
                return lhs.wattHours > rhs.wattHours
            }
            return lhs.name < rhs.name
        }
        entries = Array(sorted.prefix(Self.maximumNames))
        for evicted in sorted.dropFirst(Self.maximumNames) {
            otherWattHours += evicted.wattHours
        }
    }
}

/// What the statistics file remembers between launches. Never a log: three estimator entries
/// at most, one day of per-name energy, the current unplug, and two timestamps.
public struct StoredStatistics: Equatable, Sendable {
    /// Format version of the file; bumped when keys change meaning. A key that is only added
    /// (as `unplug` in 0.4.0) keeps the version: an older Restwatt ignores it and drops it on
    /// its next write.
    public static let currentVersion = 1
    /// Boot times further apart than this mean a reboot happened in between.
    public static let bootTimeTolerance: TimeInterval = 60

    /// Written by a newer Restwatt: nothing of it is read, and this app must not overwrite
    /// it either.
    public var isNewerFormat: Bool {
        version > Self.currentVersion
    }

    public var version: Int
    /// Wall-clock boot time (unix seconds) of the session that wrote the file, if known.
    public var bootTime: Double?
    /// Wall-clock time (unix seconds) of the write.
    public var savedAt: Double?
    /// Keyed by `PowerState.memoryKey`.
    public var estimators: [String: StoredEstimatorState]
    public var today: DailyEnergyStatistic?
    /// The last unplug while the Mac is still on battery; nil while on an external source.
    public var unplug: UnplugRecord?

    public init(version: Int = StoredStatistics.currentVersion,
                bootTime: Double? = nil,
                savedAt: Double? = nil,
                estimators: [String: StoredEstimatorState] = [:],
                today: DailyEnergyStatistic? = nil,
                unplug: UnplugRecord? = nil) {
        self.version = version
        self.bootTime = bootTime
        self.savedAt = savedAt
        self.estimators = estimators
        self.today = today
        self.unplug = unplug
    }
}

/// JSON encoding of `StoredStatistics`. Tolerant on the way in: unknown keys are ignored,
/// missing keys mean defaults, unreadable data means defaults. Strict about what it keeps:
/// an estimator entry under a key no `PowerState` uses, or with a figure that is not finite,
/// negative or beyond its ceiling, is dropped; a day with a malformed key or absurd totals is
/// dropped, an absurd name entry is dropped, and more names than `maximumNames` are folded
/// as `record` would fold them. An unplug record with a time that is not finite or before
/// 1970, a charge that is not a whole number from 0 to 100, or an unknown precision is dropped
/// on its own. A file with a newer format version yields defaults plus that
/// version, so the memory knows not to overwrite it. Deterministic on the way out.
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

    /// The charge is read as a number of any kind, so a fraction or a huge value drops the
    /// record instead of failing the whole decode.
    private struct UnplugDocument: Codable {
        var at: Double?
        var percent: Double?
        var precision: String?
    }

    private struct Document: Codable {
        var version: Int?
        var bootTime: Double?
        var savedAt: Double?
        var estimators: [String: EstimatorDocument]?
        var today: DayDocument?
        var unplug: UnplugDocument?
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
        let unplug = statistics.unplug.map { record in
            UnplugDocument(at: record.unpluggedAt, percent: record.percent.map(Double.init),
                           precision: record.precision.rawValue)
        }
        let document = Document(
            version: statistics.version, bootTime: statistics.bootTime, savedAt: statistics.savedAt,
            estimators: estimators, today: today, unplug: unplug)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of finite plain values cannot fail; an empty Data would decode to
        // defaults.
        return (try? encoder.encode(document)) ?? Data()
    }

    /// A hand-edited file may repeat a name or carry one no process can have. Duplicates are
    /// summed as `record` would sum them; empty or overlong names and absurd figures are
    /// dropped, before and after the summing.
    private static func foldedEntries(_ entries: [EntryDocument]) -> [DailyEnergyEntry] {
        var byName: [String: Double] = [:]
        for entry in entries {
            guard let name = entry.name else {
                continue
            }
            let candidate = DailyEnergyEntry(name: name, wattHours: entry.wattHours ?? 0)
            if candidate.isPlausible {
                byName[name, default: 0] += candidate.wattHours
            }
        }
        return byName.map { DailyEnergyEntry(name: $0.key, wattHours: $0.value) }.filter(\.isPlausible)
    }

    /// Read only the version first: a newer format may have changed the type of any other
    /// key, so the full decode below may fail on it without hiding that the file is newer.
    private struct VersionProbe: Decodable {
        var version: Double?
    }

    public static func decode(_ data: Data) -> StoredStatistics {
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           let version = probe.version, version.isFinite,
           version > Double(StoredStatistics.currentVersion) {
            return StoredStatistics(version: Int(min(version.rounded(.up), 1_000_000)))
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return StoredStatistics()
        }
        let version = document.version ?? StoredStatistics.currentVersion
        guard version <= StoredStatistics.currentVersion else {
            return StoredStatistics(version: version)
        }
        var estimators: [String: StoredEstimatorState] = [:]
        for (key, state) in document.estimators ?? [:] where PowerState.memoryKeys.contains(key) {
            let candidate = StoredEstimatorState(
                smoothedWatts: state.smoothedWatts ?? 0,
                observedSeconds: state.observedSeconds ?? 0,
                sampleCount: state.sampleCount ?? 0,
                lastSampleAt: state.lastSampleAt ?? 0)
            if candidate.isPlausible {
                estimators[key] = candidate
            }
        }
        var today: DailyEnergyStatistic?
        if let day = document.today?.day {
            var candidate = DailyEnergyStatistic(
                day: day,
                entries: Self.foldedEntries(document.today?.entries ?? []),
                otherWattHours: document.today?.otherWattHours ?? 0,
                sampledSeconds: document.today?.sampledSeconds ?? 0)
            if candidate.isPlausible {
                candidate.bound()
                today = candidate
            }
        }
        return StoredStatistics(
            version: version,
            bootTime: document.bootTime.flatMap { $0.isFinite ? $0 : nil },
            savedAt: document.savedAt.flatMap { $0.isFinite ? $0 : nil },
            estimators: estimators,
            today: today,
            unplug: document.unplug.flatMap(Self.unplugRecord))
    }

    private static func unplugRecord(_ document: UnplugDocument) -> UnplugRecord? {
        guard let at = document.at,
              let precision = document.precision.flatMap(UnplugRecord.Precision.init(rawValue:)) else {
            return nil
        }
        var percent: Int?
        if let value = document.percent {
            guard value.isFinite, value.rounded() == value, (0...100).contains(value) else {
                return nil
            }
            percent = Int(value)
        }
        let record = UnplugRecord(unpluggedAt: at, percent: percent, precision: precision)
        return record.isPlausible ? record : nil
    }
}
