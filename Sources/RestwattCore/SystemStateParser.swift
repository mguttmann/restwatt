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
