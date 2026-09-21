import Foundation

/// All user-visible strings. Kept in the core so tests can pin them down.
public enum Formatting {
    /// Label that marks the process list as the partial estimate it is.
    public static let processListLabel = "Top processes (your processes, CPU energy only, estimate):"

    /// `h:mm`, or "> 99 h" at the estimator cap.
    public static func durationString(minutes: Int) -> String {
        if minutes >= PowerMath.maximumMinutes {
            return "> 99 h"
        }
        let clamped = max(0, minutes)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    public static func watts(_ value: Double) -> String {
        String(format: "%.1f W", value)
    }

    static func wattsFine(_ value: Double) -> String {
        String(format: "%.2f W", value)
    }

    /// The text in the menu bar.
    public static func menuBarTitle(_ model: DisplayModel) -> String {
        switch model {
        case .unavailable:
            return "No battery"
        case .battery(let status):
            switch status.state {
            case .discharging:
                let time = status.estimate?.smoothedMinutes.map(durationString(minutes:)) ?? "--:--"
                return "\(watts(status.drawWatts))  \(time)"
            case .charging:
                if let minutes = status.avgTimeToFullMinutes {
                    return "Charging  \(durationString(minutes: minutes))"
                }
                return "Charging"
            case .onExternalPower(let fullyCharged):
                return fullyCharged ? "On AC  \(status.percent) %" : "On AC"
            }
        }
    }

    /// The plain-text lines of the battery details, without the process list. The app
    /// renders `detailRows` instead; these lines are the wording the rows mirror.
    public static func summaryLines(_ model: DisplayModel) -> [String] {
        switch model {
        case .unavailable(let reason):
            return [reason]
        case .battery(let status):
            var lines = [
                "Battery \(status.percent) %, \(String(format: "%.1f", status.remainingWattHours)) Wh remaining"
            ]
            switch status.state {
            case .discharging:
                lines.append("Drawing \(watts(status.drawWatts)) now")
                if let estimate = status.estimate {
                    lines.append("Time left at current draw: "
                        + (estimate.instantMinutes.map(durationString(minutes:)) ?? "n/a"))
                    let observedMinutes = Int((estimate.observedSeconds / 60).rounded())
                    lines.append("Time left, smoothed (\(observedMinutes) min observed, confidence "
                        + "\(estimate.confidence.rawValue)): "
                        + (estimate.smoothedMinutes.map(durationString(minutes:)) ?? "n/a"))
                } else {
                    lines.append("Time left: waiting for the first gauge reading")
                }
                lines.append("macOS estimate: "
                    + (status.systemTimeToEmptyMinutes.map(durationString(minutes:)) ?? "not yet available"))
            case .charging:
                lines.append("Charging at \(watts(-status.drawWatts))")
                lines.append("Time to full (macOS estimate): "
                    + (status.avgTimeToFullMinutes.map(durationString(minutes:)) ?? "not yet available"))
            case .onExternalPower(let fullyCharged):
                lines.append(fullyCharged ? "On AC power, fully charged" : "On AC power, not charging")
            }
            return lines
        }
    }

    /// The process list, `limit` entries, indented by two spaces.
    public static func processLines(_ report: ProcessEnergyReport, limit: Int) -> [String] {
        var lines = [processListLabel]
        if report.isWarmingUp {
            lines.append("  collecting the first interval")
            return lines
        }
        if report.entries.isEmpty {
            lines.append("  no process used measurable energy")
        }
        for entry in report.entries.prefix(limit) {
            let suffix = entry.processCount > 1 ? " (\(entry.processCount) processes)" : ""
            lines.append("  \(entry.name)\(suffix)  \(wattsFine(entry.watts))")
        }
        var total = "  Visible total \(wattsFine(report.visibleTotalWatts)) over \(report.processCount) processes"
        if let unaccounted = report.unaccountedWatts {
            total += ", unaccounted \(wattsFine(unaccounted))"
        }
        lines.append(total)
        return lines
    }

    /// Multi-line plain-text form of the details (the former tooltip text). Kept as the
    /// reference wording for `detailRows`; not shown by the app itself.
    public static func tooltipText(_ model: DisplayModel) -> String {
        var lines = ["Restwatt"] + summaryLines(model)
        if case .battery(let status) = model {
            lines += processLines(status.processReport, limit: 3)
        }
        return lines.joined(separator: "\n")
    }

    /// Item titles for the click menu, top to bottom, without the Quit item.
    public static func menuLines(_ model: DisplayModel, version: String) -> [String] {
        var lines = summaryLines(model)
        if case .battery(let status) = model {
            lines += processLines(status.processReport, limit: 5)
        }
        lines.append("Restwatt \(version)")
        return lines
    }
}
