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

    /// `powermode` per power source from `pmset -g custom`. Each source is a block headed by
    /// its name (`Battery Power:`, `AC Power:`, no leading space), followed by value lines
    /// with one leading space. A source whose block is present but carries no `powermode`
    /// line (or a non-numeric one) maps to nil; a source without a block is absent from the
    /// dictionary; a block of an unknown source (`UPS Power:`) is skipped. Nil when the output
    /// carries no block header at all, so a failed read is never mistaken for a setting.
    public static func parsePowerModes(pmsetCustomOutput: String) -> [PowerSource: Int?]? {
        var sawHeader = false
        var modes: [PowerSource: Int?] = [:]
        var current: PowerSource?
        for rawLine in pmsetCustomOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if !line.hasPrefix(" ") {
                let header = line.trimmingCharacters(in: .whitespaces)
                guard header.hasSuffix(":") else {
                    current = nil
                    continue
                }
                sawHeader = true
                current = PowerSource(rawValue: String(header.dropLast()))
                if let current, modes[current] == nil {
                    modes[current] = .some(nil)
                }
                continue
            }
            guard let current else {
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 2, tokens[0] == "powermode" else {
                continue
            }
            modes[current] = .some(Int(tokens[1]))
        }
        return sawHeader ? modes : nil
    }

    /// `pmset -g cap`: the source named in `Capabilities for <name>:` and the keys listed
    /// under it, one per line with a leading space. `source` is nil for a name the app does
    /// not address (`UPS Power`). Nil when the header is missing.
    public static func parseCapabilities(pmsetCapOutput: String) -> (source: PowerSource?, keys: Set<String>)? {
        let headerPrefix = "Capabilities for "
        var source: PowerSource?
        var sawHeader = false
        var keys: Set<String> = []
        for rawLine in pmsetCapOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if !line.hasPrefix(" ") {
                let header = line.trimmingCharacters(in: .whitespaces)
                guard header.hasPrefix(headerPrefix), header.hasSuffix(":") else {
                    continue
                }
                sawHeader = true
                source = PowerSource(rawValue: String(header.dropFirst(headerPrefix.count).dropLast()))
                continue
            }
            guard sawHeader else {
                continue
            }
            let key = line.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                keys.insert(key)
            }
        }
        return sawHeader ? (source, keys) : nil
    }

    /// What `sudo -n` prints on its own stderr when it would have to ask for a password. Any
    /// other failure of a `sudo -n pmset ...` call is the command's own and never a denial.
    public static let sudoDenialMarkers = ["a password is required", "a terminal is required"]

    /// True when a `sudo -n <command>` result is sudo refusing to run without a password:
    /// exit status 1 and a `sudo:` line naming one of the denial markers. A `pmset` that ran
    /// as root and failed exits with its own status and its own stderr and is not a denial.
    public static func isSudoDenial(_ result: CommandResult) -> Bool {
        guard result.exitStatus == 1 else {
            return false
        }
        return result.stderr.split(separator: "\n").contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("sudo:") && sudoDenialMarkers.contains { line.contains($0) }
        }
    }

    /// True when a `sudo -n <command>` result is sudo failing on its own account, denial or
    /// not: exit status 1 and a line on stderr that sudo prefixed with `sudo:` (a broken
    /// sudo configuration, a `nosuid` mount, a denial). Deliberately conservative: `pmset` prefixes
    /// its own messages with `pmset:` and a silent exit 1 says nothing, so both count as the
    /// command's failure, never as sudo's.
    public static func isSudoFailure(_ result: CommandResult) -> Bool {
        guard result.exitStatus == 1 else {
            return false
        }
        return result.stderr.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("sudo:")
        }
    }

    /// What `osascript` reports when the administrator dialog is cancelled: AppleScript's
    /// `User canceled` error, number -128. Nothing ran as root then.
    public static let dialogCancelledMarker = "(-128)"

    /// True when a failed administrator dialog was cancelled rather than run.
    public static func isDialogCancelled(_ result: CommandResult) -> Bool {
        !result.succeeded && result.stderr.contains(dialogCancelledMarker)
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

    /// An `IOReturn` as the eight hex digits IOKit documents it with (`e00002bc`), never as a
    /// negative number: the code is a signed 32-bit value whose high bit is set for errors.
    public static func ioReturnHex(_ code: Int32) -> String {
        String(UInt32(bitPattern: code), radix: 16)
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
