import Foundation

/// Reads the two system outputs the settings section depends on. Pure string work.
public enum SystemStateParser {
    /// `SleepDisabled` from `pmset -g`. The value lives in the block headed
    /// `System-wide power settings:`, as ` SleepDisabled<whitespace>N`. A `1` means sleep is
    /// disabled; `0` or a missing line means it is not. Nil when the output carries no
    /// settings at all (empty or unrecognisable), so a failed read is never mistaken for off.
    public static func parseSleepDisabled(pmsetOutput: String) -> Bool? {
        var sawSettings = false
        var inSystemWideBlock = false
        for rawLine in pmsetOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if !line.hasPrefix(" ") {
                // A block header such as `System-wide power settings:` or `Currently in use:`.
                inSystemWideBlock = line.trimmingCharacters(in: .whitespaces) == "System-wide power settings:"
                if line.hasSuffix(":") {
                    sawSettings = true
                }
                continue
            }
            sawSettings = true
            guard inSystemWideBlock else {
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 2, tokens[0] == "SleepDisabled" else {
                continue
            }
            return tokens[1] == "1"
        }
        return sawSettings ? false : nil
    }

    /// The text `launchctl print` and `bootout`/`bootstrap` print for a label that is not
    /// loaded in the domain.
    public static let launchctlNotFoundMarker = "Could not find service"

    /// `launchctl print gui/<uid>/<label>`: `state = running` means an instance runs,
    /// `state = not running` means loaded and idle, a not-found error means not loaded.
    public static func parseLaunchctlPrint(_ result: CommandResult) -> ServiceState {
        guard result.succeeded else {
            if result.stderr.contains(launchctlNotFoundMarker) {
                return .off
            }
            return .unknown("launchctl print exit \(result.exitStatus): \(head(result.stderr))")
        }
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "state = not running" {
                return .loadedIdle
            }
            if line == "state = running" {
                return .running
            }
        }
        return .unknown("launchctl print reported no state")
    }

    /// The first line of a message, cut to a length that fits a menu row.
    public static func head(_ text: String, limit: Int = 120) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= limit {
            return trimmed
        }
        return String(trimmed.prefix(limit))
    }
}
