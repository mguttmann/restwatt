import Foundation

/// One label/value pair of the battery details, as shown in the hover popover and the
/// click menu. The strings are final user-visible text; the app layer only lays them out.
public struct DetailRow: Equatable, Sendable {
    public enum Emphasis: Equatable, Sendable {
        /// The figures to read at a glance: the current draw or charging power, the two time
        /// values, and the one-line state notes (weak source, source changing, on AC).
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
            case .discharging, .drainingOnExternalPower:
                rows.append(DetailRow("Drawing now", watts(status.drawWatts), emphasis: .primary))
                rows += timeRows(status.estimate, .toEmpty)
                rows.append(DetailRow(
                    "macOS estimate",
                    status.systemTimeToEmptyMinutes.map(durationString(minutes:)) ?? notYetAvailableText))
                if status.state == .drainingOnExternalPower {
                    rows.append(DetailRow("Power source", weakSourceText, emphasis: .primary))
                }
            case .charging:
                rows.append(DetailRow("Charging at", watts(-status.drawWatts), emphasis: .primary))
                rows += timeRows(status.estimate, .toFull)
                rows.append(DetailRow(
                    "macOS estimate",
                    status.avgTimeToFullMinutes.map(durationString(minutes:)) ?? notYetAvailableText))
            case .onExternalPower(let fullyCharged):
                rows.append(DetailRow(
                    "Power", fullyCharged ? "On AC, fully charged" : "On AC, not charging", emphasis: .primary))
            case .powerSourceChanging:
                rows.append(DetailRow("Power", powerSourceChangingText, emphasis: .primary))
            }
            if let adapterWatts = status.adapterWatts, status.state != .powerSourceChanging {
                rows.append(DetailRow("Source rating", "\(adapterWatts) W"))
            }
            return rows
        }
    }

    /// The time rows of an estimate (both times primary, the smoothing note secondary), or
    /// the waiting row without one. Mirrors `timeLines`.
    private static func timeRows(_ estimate: Estimate?, _ labels: TimeLabels) -> [DetailRow] {
        guard let estimate else {
            return [DetailRow(labels.waiting, waitingForGaugeText, emphasis: .primary)]
        }
        return [
            DetailRow(labels.atCurrent, estimate.instantMinutes.map(durationString(minutes:)) ?? "n/a",
                      emphasis: .primary),
            DetailRow(labels.smoothed, estimate.smoothedMinutes.map(durationString(minutes:)) ?? "n/a",
                      emphasis: .primary),
            DetailRow("Smoothing", "\(observedMinutes(estimate)) min observed, confidence \(estimate.confidence.rawValue)"),
        ]
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
