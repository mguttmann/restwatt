import Foundation

/// One label/value pair of the battery details, as shown in the hover popover and the
/// click menu. The strings are final user-visible text; the app layer only lays them out.
public struct DetailRow: Equatable, Sendable {
    public enum Emphasis: Equatable, Sendable {
        /// The figures to read at a glance: current draw and the two time-left values.
        case primary
        /// Supporting information.
        case secondary
        /// A section title without a value.
        case heading
    }

    public var label: String
    /// Empty for headings.
    public var value: String
    public var emphasis: Emphasis

    public init(_ label: String, _ value: String = "", emphasis: Emphasis = .secondary) {
        self.label = label
        self.value = value
        self.emphasis = emphasis
    }
}

extension Formatting {
    /// The battery summary as label/value rows, top to bottom, without the process list.
    /// Same data as `summaryLines`, split for a two-column layout.
    public static func detailRows(_ model: DisplayModel) -> [DetailRow] {
        switch model {
        case .unavailable(let reason):
            return [DetailRow(reason, emphasis: .heading)]
        case .battery(let status):
            var rows = [
                DetailRow("Battery", "\(status.percent) %, \(String(format: "%.1f", status.remainingWattHours)) Wh")
            ]
            switch status.state {
            case .discharging:
                rows.append(DetailRow("Drawing now", watts(status.drawWatts), emphasis: .primary))
                if let estimate = status.estimate {
                    rows.append(DetailRow(
                        "Time left at current draw",
                        estimate.instantMinutes.map(durationString(minutes:)) ?? "n/a",
                        emphasis: .primary))
                    rows.append(DetailRow(
                        "Time left, smoothed",
                        estimate.smoothedMinutes.map(durationString(minutes:)) ?? "n/a",
                        emphasis: .primary))
                    let observedMinutes = Int((estimate.observedSeconds / 60).rounded())
                    rows.append(DetailRow(
                        "Smoothing", "\(observedMinutes) min observed, confidence \(estimate.confidence.rawValue)"))
                } else {
                    rows.append(DetailRow("Time left", "waiting for the first gauge reading", emphasis: .primary))
                }
                rows.append(DetailRow(
                    "macOS estimate",
                    status.systemTimeToEmptyMinutes.map(durationString(minutes:)) ?? "not yet available"))
            case .charging:
                rows.append(DetailRow("Charging at", watts(-status.drawWatts), emphasis: .primary))
                rows.append(DetailRow(
                    "Time to full (macOS estimate)",
                    status.avgTimeToFullMinutes.map(durationString(minutes:)) ?? "not yet available",
                    emphasis: .primary))
            case .onExternalPower(let fullyCharged):
                rows.append(DetailRow(
                    "Power", fullyCharged ? "On AC, fully charged" : "On AC, not charging", emphasis: .primary))
            }
            return rows
        }
    }

    /// The process list as rows: a heading, `limit` process entries, and the total.
    /// Same data as `processLines`.
    public static func processRows(_ report: ProcessEnergyReport, limit: Int) -> [DetailRow] {
        var rows = [DetailRow(processListHeading, emphasis: .heading)]
        if report.isWarmingUp {
            rows.append(DetailRow("collecting the first interval"))
            return rows
        }
        if report.entries.isEmpty {
            rows.append(DetailRow("no process used measurable energy"))
        }
        for entry in report.entries.prefix(limit) {
            let suffix = entry.processCount > 1 ? " (\(entry.processCount) processes)" : ""
            rows.append(DetailRow("\(entry.name)\(suffix)", wattsFine(entry.watts)))
        }
        var total = "\(wattsFine(report.visibleTotalWatts)) over \(report.processCount) processes"
        if let unaccounted = report.unaccountedWatts {
            total += ", unaccounted \(wattsFine(unaccounted))"
        }
        rows.append(DetailRow("Visible total", total))
        return rows
    }

    /// Heading of the process rows; `processListLabel` without the trailing colon.
    public static var processListHeading: String {
        var heading = processListLabel
        if heading.hasSuffix(":") {
            heading.removeLast()
        }
        return heading
    }
}
