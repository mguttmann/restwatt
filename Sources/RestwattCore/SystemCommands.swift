import Foundation

/// An executable path plus its argument list, launched without a shell. Every vector the app
/// runs is built here from constants; no user data ever reaches one.
public struct CommandVector: Equatable, Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The vector as a single line, for error text and documentation.
    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// What a finished command left behind.
public struct CommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(exitStatus: Int32, stdout: String = "", stderr: String = "") {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool {
        exitStatus == 0
    }
}

/// The two `pmset` profiles the lid-closed toggle writes. They are Manuel's scripts verbatim:
/// awake is the one call of Wach-AN, saver the four calls of Wach-AUS (his chosen saver
/// values, not a captured factory default).
public enum PmsetProfile: Equatable, Sendable, CaseIterable {
    case awake
    case saver

    public var vectors: [CommandVector] {
        switch self {
        case .awake: return SystemCommands.pmsetAwakeProfile
        case .saver: return SystemCommands.pmsetSaverProfile
        }
    }
}

public enum PrivilegeError: Error, Equatable, Sendable {
    /// Neither the non-interactive sudo nor the administrator dialog ran the profile; the
    /// text is the head of what the last attempt reported.
    case declinedOrFailed(String)
    /// A token would not survive being quoted into a shell script. Cannot happen with the
    /// constants in this file; guards future edits.
    case invalidToken(String)
}

/// Fixed argument vectors. Absolute paths, no shell, no lookup through PATH.
public enum SystemCommands {
    public static let pmset = "/usr/bin/pmset"
    public static let sudo = "/usr/bin/sudo"
    public static let launchctl = "/bin/launchctl"
    public static let osascript = "/usr/bin/osascript"

    /// Wach-AN, line 5.
    public static let pmsetAwakeProfile: [CommandVector] = [
        CommandVector(pmset, ["-a", "sleep", "0", "displaysleep", "0", "disksleep", "0",
                              "hibernatemode", "0", "standby", "0", "disablesleep", "1"]),
    ]

    /// Wach-AUS, lines 5 to 8, in that order.
    public static let pmsetSaverProfile: [CommandVector] = [
        CommandVector(pmset, ["-a", "disablesleep", "0"]),
        CommandVector(pmset, ["-b", "displaysleep", "2", "sleep", "10", "disksleep", "10",
                              "hibernatemode", "3", "standby", "1"]),
        CommandVector(pmset, ["-c", "displaysleep", "10", "sleep", "30", "disksleep", "10",
                              "hibernatemode", "3", "standby", "1"]),
        CommandVector(pmset, ["-a", "standbydelaylow", "10800", "standbydelayhigh", "86400"]),
    ]

    /// Reads the settings of the current power source plus the system-wide block.
    public static let pmsetRead = CommandVector(pmset, ["-g"])

    public static func launchctlPrint(_ label: String, uid: uid_t) -> CommandVector {
        CommandVector(launchctl, ["print", "gui/\(uid)/\(label)"])
    }

    public static func launchctlBootstrap(_ service: SyncService, uid: uid_t) -> CommandVector? {
        guard let plist = service.launchAgentPlistPath else {
            return nil
        }
        return CommandVector(launchctl, ["bootstrap", "gui/\(uid)", plist])
    }

    public static func launchctlKickstart(_ service: SyncService, uid: uid_t) -> CommandVector? {
        guard service.isLaunchdService else {
            return nil
        }
        return CommandVector(launchctl, ["kickstart", "gui/\(uid)/\(service.rawValue)"])
    }

    public static func launchctlBootout(_ service: SyncService, uid: uid_t) -> CommandVector? {
        guard service.isLaunchdService else {
            return nil
        }
        return CommandVector(launchctl, ["bootout", "gui/\(uid)/\(service.rawValue)"])
    }

    /// `sudo -n`: runs the vector as root when no password is needed, otherwise fails at once
    /// without prompting. The vector itself is passed through unchanged.
    public static func sudoNonInteractive(_ vector: CommandVector) -> CommandVector {
        CommandVector(sudo, ["-n", vector.executable] + vector.arguments)
    }

    /// The native administrator dialog: one `do shell script` that chains every vector of the
    /// profile with `&&`, so a profile costs one dialog. Only `administrator privileges` is
    /// used; the `user name` and `password` parameters never are.
    public static func administratorScript(_ vectors: [CommandVector]) throws -> CommandVector {
        CommandVector(osascript, ["-e", try administratorScriptSource(vectors)])
    }

    /// The AppleScript source of `administratorScript`, for tests and documentation.
    public static func administratorScriptSource(_ vectors: [CommandVector]) throws -> String {
        let commands = try vectors.map { vector in
            try ([vector.executable] + vector.arguments).map(validatedToken).joined(separator: " ")
        }
        return "do shell script \"\(commands.joined(separator: " && "))\" with administrator privileges"
    }

    /// Letters, digits, dot, underscore, slash and hyphen only: the alphabet of the constants
    /// above. Anything else (space, quote, semicolon, dollar) is refused.
    static func validatedToken(_ token: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard !token.isEmpty, token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PrivilegeError.invalidToken(token)
        }
        return token
    }
}
