import Foundation

/// All user-visible strings. Kept in the core so tests can pin them down.
public enum Formatting {
    /// Label that marks the process list as the partial estimate it is.
    public static let processListLabel = "Top processes (your processes, CPU energy only, estimate):"
    /// Heading of the day's per-name energy; the same caveats as the live list.
    public static let todayHeading = "Today (your processes, CPU energy only, estimate)"
    /// Label of the day's total line.
    static let todayTotalLabel = "Total today"

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

    /// Energy as whole milliwatt-hours below one watt-hour, `x.xx Wh` from there.
    static func energy(_ wattHours: Double) -> String {
        let milliWattHours = (wattHours * 1000).rounded()
        if milliWattHours < 1000 {
            return "\(Int(milliWattHours)) mWh"
        }
        return String(format: "%.2f Wh", wattHours)
    }

    /// Value of the day's total line: the energy and how long was sampled.
    static func todayTotal(_ statistic: DailyEnergyStatistic) -> String {
        let minutes = Int((statistic.sampledSeconds / 60).rounded())
        return "\(energy(statistic.totalWattHours)) over \(durationString(minutes: minutes)) sampled"
    }

    /// The text in the menu bar.
    public static func menuBarTitle(_ model: DisplayModel) -> String {
        switch model {
        case .unavailable:
            return "No battery"
        case .battery(let status):
            let time = status.estimate?.smoothedMinutes.map(durationString(minutes:))
            switch status.state {
            case .discharging:
                return "\(watts(status.drawWatts))  \(time ?? "--:--")"
            case .drainingOnExternalPower:
                return "\(watts(status.drawWatts))  \(time ?? "--:--")  \(weakSourceMarker)"
            case .charging:
                if let time {
                    return "Charging  \(time)"
                }
                return "Charging"
            case .onExternalPower(let fullyCharged):
                return fullyCharged ? "On AC  \(status.percent) %" : "On AC"
            case .powerSourceChanging:
                return "\(status.percent) %"
            }
        }
    }

    /// Short marker in the title while an external source delivers less than the Mac uses.
    static let weakSourceMarker = "weak source"
    /// Value of the `Power source` row in the same situation.
    static let weakSourceText = "connected, but it delivers less than the Mac uses"
    /// Value of the `Power` row while the gauge reading still predates a plug or unplug event.
    static let powerSourceChangingText = "power source changed, waiting for the gauge"
    static let waitingForGaugeText = "waiting for the first gauge reading"
    static let notYetAvailableText = "not yet available"

    /// The labels of the time block; the same block serves draining and charging.
    struct TimeLabels {
        /// Label of the time at the most recent power.
        let atCurrent: String
        /// Label of the smoothed time.
        let smoothed: String
        /// Label shown while no sample exists yet.
        let waiting: String

        static let toEmpty = TimeLabels(
            atCurrent: "Time left at current draw", smoothed: "Time left, smoothed", waiting: "Time left")
        static let toFull = TimeLabels(
            atCurrent: "Time to full at current power", smoothed: "Time to full, smoothed", waiting: "Time to full")
    }

    static func observedMinutes(_ estimate: Estimate) -> Int {
        Int((estimate.observedSeconds / 60).rounded())
    }

    /// The two time lines of an estimate, or the waiting line without one.
    private static func timeLines(_ estimate: Estimate?, _ labels: TimeLabels) -> [String] {
        guard let estimate else {
            return ["\(labels.waiting): \(waitingForGaugeText)"]
        }
        return [
            "\(labels.atCurrent): " + (estimate.instantMinutes.map(durationString(minutes:)) ?? "n/a"),
            "\(labels.smoothed) (\(observedMinutes(estimate)) min observed, confidence "
                + "\(estimate.confidence.rawValue)): "
                + (estimate.smoothedMinutes.map(durationString(minutes:)) ?? "n/a"),
        ]
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
            case .discharging, .drainingOnExternalPower:
                lines.append("Drawing \(watts(status.drawWatts)) now")
                lines += timeLines(status.estimate, .toEmpty)
                lines.append("macOS estimate: "
                    + (status.systemTimeToEmptyMinutes.map(durationString(minutes:)) ?? notYetAvailableText))
                if status.state == .drainingOnExternalPower {
                    lines.append("Power source: \(weakSourceText)")
                }
            case .charging:
                lines.append("Charging at \(watts(-status.drawWatts))")
                lines += timeLines(status.estimate, .toFull)
                lines.append("macOS estimate: "
                    + (status.avgTimeToFullMinutes.map(durationString(minutes:)) ?? notYetAvailableText))
            case .onExternalPower(let fullyCharged):
                lines.append(fullyCharged ? "On AC power, fully charged" : "On AC power, not charging")
            case .powerSourceChanging:
                lines.append("Power: \(powerSourceChangingText)")
            }
            if let adapterWatts = status.adapterWatts, status.state != .powerSourceChanging {
                lines.append("Source rating: \(adapterWatts) W")
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

    /// The day's per-name energy, `limit` entries plus the total, indented by two spaces;
    /// empty while nothing of the day is sampled.
    public static func todayLines(_ statistic: DailyEnergyStatistic?, limit: Int) -> [String] {
        guard let statistic else {
            return []
        }
        var lines = [todayHeading]
        for entry in statistic.entries.prefix(limit) {
            lines.append("  \(entry.name)  \(energy(entry.wattHours))")
        }
        lines.append("  \(todayTotalLabel) \(todayTotal(statistic))")
        return lines
    }

    /// Multi-line plain-text form of the details (the former tooltip text). Kept as the
    /// reference wording for `detailRows`; not shown by the app itself.
    public static func tooltipText(_ model: DisplayModel) -> String {
        var lines = ["Restwatt"] + summaryLines(model)
        if case .battery(let status) = model {
            lines += processLines(status.processReport, limit: 3)
            lines += todayLines(status.today, limit: 3)
        }
        return lines.joined(separator: "\n")
    }

    /// Item titles for the click menu, top to bottom, without the Quit item.
    public static func menuLines(_ model: DisplayModel, version: String) -> [String] {
        var lines = summaryLines(model)
        if case .battery(let status) = model {
            lines += processLines(status.processReport, limit: 5)
            lines += todayLines(status.today, limit: 5)
        }
        lines.append("Restwatt \(version)")
        return lines
    }
}
