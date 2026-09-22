import Foundation

/// Energy attributed to all processes sharing one name, over the last interval.
public struct ProcessEnergyEntry: Equatable, Sendable {
    public var name: String
    /// Average power over the interval, in watts.
    public var watts: Double
    /// CPU seconds per wall-clock second (1.0 = one core fully busy).
    public var cpuShare: Double
    /// How many pids were aggregated into this entry.
    public var processCount: Int

    public init(name: String, watts: Double, cpuShare: Double, processCount: Int) {
        self.name = name
        self.watts = watts
        self.cpuShare = cpuShare
        self.processCount = processCount
    }
}

/// Ranking of the user's own processes by kernel-reported CPU energy. This is a partial
/// picture: root and system processes, the display and the rest of the SoC are not in it.
public struct ProcessEnergyReport: Equatable, Sendable {
    /// Sorted by watts, descending, at most `limit` entries.
    public var entries: [ProcessEnergyEntry]
    /// Sum over all visible processes, not only the listed entries.
    public var visibleTotalWatts: Double
    /// Number of pids that contributed a valid delta.
    public var processCount: Int
    /// Battery draw not explained by visible processes; nil unless the battery is the only
    /// source (with an external source connected the battery draw is not the system draw).
    public var unaccountedWatts: Double?
    /// True until two consecutive readings exist.
    public var isWarmingUp: Bool

    public init(
        entries: [ProcessEnergyEntry],
        visibleTotalWatts: Double,
        processCount: Int,
        unaccountedWatts: Double?,
        isWarmingUp: Bool
    ) {
        self.entries = entries
        self.visibleTotalWatts = visibleTotalWatts
        self.processCount = processCount
        self.unaccountedWatts = unaccountedWatts
        self.isWarmingUp = isWarmingUp
    }

    public static let warmingUp = ProcessEnergyReport(
        entries: [], visibleTotalWatts: 0, processCount: 0, unaccountedWatts: nil, isWarmingUp: true)
}

/// Every name with a valid delta over one interval, before any limit is applied. The report
/// shows the top of it; the daily statistic counts all of it.
public struct ProcessEnergyAggregation: Equatable, Sendable {
    /// Sorted by watts, descending, ties by name.
    public var entries: [ProcessEnergyEntry]
    /// Number of pids that contributed a valid delta.
    public var processCount: Int
    /// Sum over all entries.
    public var totalWatts: Double

    public init(entries: [ProcessEnergyEntry], processCount: Int, totalWatts: Double) {
        self.entries = entries
        self.processCount = processCount
        self.totalWatts = totalWatts
    }

    /// The report of this interval: the top `limit` names plus the totals.
    public func report(drawWatts: Double, batteryIsOnlySource: Bool,
                       limit: Int = ProcessEnergyRanker.defaultLimit) -> ProcessEnergyReport {
        ProcessEnergyReport(
            entries: Array(entries.prefix(limit)),
            visibleTotalWatts: totalWatts,
            processCount: processCount,
            unaccountedWatts: batteryIsOnlySource ? max(0, drawWatts - totalWatts) : nil,
            isWarmingUp: false
        )
    }
}

public enum ProcessEnergyRanker {
    /// Default number of entries kept in a report.
    public static let defaultLimit = 5

    /// Rank by energy delta between two readings taken `dt` seconds apart.
    ///
    /// A pid counts only if it appears in both readings with a non-decreasing energy counter
    /// (a decrease means the pid was reused by a new process). Entries are aggregated by name.
    public static func rank(
        previous: [ProcessEnergySample],
        current: [ProcessEnergySample],
        dt: TimeInterval,
        drawWatts: Double,
        batteryIsOnlySource: Bool,
        limit: Int = defaultLimit
    ) -> ProcessEnergyReport {
        guard let aggregation = aggregate(previous: previous, current: current, dt: dt) else {
            return .warmingUp
        }
        return aggregation.report(drawWatts: drawWatts, batteryIsOnlySource: batteryIsOnlySource, limit: limit)
    }

    /// All names with a valid delta, or nil while there is no previous reading yet.
    public static func aggregate(
        previous: [ProcessEnergySample],
        current: [ProcessEnergySample],
        dt: TimeInterval
    ) -> ProcessEnergyAggregation? {
        guard dt > 0, !previous.isEmpty else {
            return nil
        }
        var previousByPid: [Int32: ProcessEnergySample] = [:]
        for sample in previous {
            previousByPid[sample.pid] = sample
        }

        var byName: [String: ProcessEnergyEntry] = [:]
        var processCount = 0
        var total = 0.0
        for sample in current {
            guard let before = previousByPid[sample.pid],
                  sample.energyNanoJoules >= before.energyNanoJoules else {
                continue
            }
            let watts = Double(sample.energyNanoJoules - before.energyNanoJoules) / dt / 1e9
            let cpuShare = max(0, sample.cpuTimeSeconds - before.cpuTimeSeconds) / dt
            processCount += 1
            total += watts
            if var entry = byName[sample.name] {
                entry.watts += watts
                entry.cpuShare += cpuShare
                entry.processCount += 1
                byName[sample.name] = entry
            } else {
                byName[sample.name] = ProcessEnergyEntry(
                    name: sample.name, watts: watts, cpuShare: cpuShare, processCount: 1)
            }
        }

        let sorted = byName.values.sorted { lhs, rhs in
            if lhs.watts != rhs.watts {
                return lhs.watts > rhs.watts
            }
            return lhs.name < rhs.name
        }
        return ProcessEnergyAggregation(entries: sorted, processCount: processCount, totalWatts: total)
    }
}
