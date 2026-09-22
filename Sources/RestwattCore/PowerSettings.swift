import Foundation

/// A power assertion the app holds in its own process. It costs no privileges and dies with
/// the process, which is the safe failure mode. Raw values are the IOPM assertion type
/// strings (`IOPMLib.h`, the modern `kIOPMAssertPrevent...` names).
public enum AwakeAssertion: String, CaseIterable, Codable, Sendable {
    /// Keep awake: the system does not go to idle sleep. The lid closing still sleeps it.
    case idleSleep = "PreventUserIdleSystemSleep"
    /// Keep display awake: the display does not dim or sleep on idle.
    case displaySleep = "PreventUserIdleDisplaySleep"
    /// Keep disk awake: disks do not spin down on idle; the system may still sleep.
    case diskIdle = "PreventDiskIdle"

    /// Menu label.
    public var label: String {
        switch self {
        case .idleSleep: return "Keep awake"
        case .displaySleep: return "Keep display awake"
        case .diskIdle: return "Keep disk awake"
        }
    }

    /// The assertion name shown by `pmset -g assertions` while it is held.
    public var assertionName: String {
        "Restwatt: \(label)"
    }
}

/// A sync service the menu can start and stop. The first two are launchd agents in the
/// user's `gui` domain (raw value = launchd label); OneDrive is an application (raw value =
/// bundle identifier).
public enum SyncService: String, CaseIterable, Sendable {
    case iCloudDrive = "com.apple.bird"
    case iCloudPhotos = "com.apple.cloudphotod"
    case oneDrive = "com.microsoft.OneDrive-mac"

    public var label: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .iCloudPhotos: return "iCloud Photos"
        case .oneDrive: return "OneDrive"
        }
    }

    /// True for services launchd owns; false for OneDrive, which is a regular application.
    public var isLaunchdService: Bool {
        self != .oneDrive
    }

    /// The system LaunchAgent plist `launchctl bootstrap` loads. Nil for OneDrive.
    public var launchAgentPlistPath: String? {
        guard isLaunchdService else {
            return nil
        }
        return "/System/Library/LaunchAgents/\(rawValue).plist"
    }

    /// Bundle identifiers that count as this service when it is an application, the primary
    /// one first. Empty for launchd services.
    public var bundleIdentifiers: [String] {
        switch self {
        case .oneDrive: return [rawValue, "com.microsoft.OneDrive"]
        case .iCloudDrive, .iCloudPhotos: return []
        }
    }
}

/// One toggle in the settings section of the click menu.
public enum SettingKey: Hashable, Sendable {
    /// Process-scoped: held as an IOPM assertion, remembered in the settings file and
    /// re-acquired at launch.
    case awake(AwakeAssertion)
    /// System-persistent: written with `pmset` as root, survives the app, reconciled at
    /// launch and quit.
    case lidClosedAwake
    /// Immediate action on the running system; the checkmark shows the observed state and
    /// nothing is stored.
    case sync(SyncService)
    /// One radio row of Apple's Energy Mode for the current power source: written with
    /// `pmset` as root, the checkmark shows the value read back, nothing is stored.
    case energyMode(EnergyMode)

    public var label: String {
        switch self {
        case .awake(let assertion): return assertion.label
        case .lidClosedAwake: return "Stay awake with the lid closed"
        case .sync(let service): return service.label
        case .energyMode(let mode): return mode.label
        }
    }
}

/// What the settings file remembers between launches. Sync choices are deliberately absent.
public struct StoredSettings: Equatable, Sendable {
    /// Format version of the file; bumped when keys change meaning.
    public static let currentVersion = 1

    public var version: Int
    /// The user's choice per process-scoped assertion. Missing means off.
    public var awake: [AwakeAssertion: Bool]
    /// True from the moment Restwatt itself wrote `disablesleep 1` until it wrote the saver
    /// profile back. Never set by a state Restwatt merely observed.
    public var lidClosedAwakeArmedByRestwatt: Bool

    public init(version: Int = StoredSettings.currentVersion,
                awake: [AwakeAssertion: Bool] = [:],
                lidClosedAwakeArmedByRestwatt: Bool = false) {
        self.version = version
        self.awake = awake
        self.lidClosedAwakeArmedByRestwatt = lidClosedAwakeArmedByRestwatt
    }

    public func isOn(_ assertion: AwakeAssertion) -> Bool {
        awake[assertion] ?? false
    }
}

/// Where the settings file lives, relative to the user's Library folder. The app layer
/// resolves the Library folder; the README quotes this path.
public enum SettingsStoreLocation {
    public static let directoryName = "Restwatt"
    public static let fileName = "settings.json"
    /// The path as documented in the README.
    public static let documentedPath = "~/Library/Application Support/Restwatt/settings.json"
}

/// JSON encoding of `StoredSettings`. Tolerant on the way in: unknown keys are ignored,
/// missing keys mean false, unreadable data means defaults. Deterministic on the way out.
public enum SettingsCodec {
    private struct Document: Codable {
        var version: Int?
        var awake: [String: Bool]?
        var lidClosedAwakeArmedByRestwatt: Bool?
    }

    public static func encode(_ settings: StoredSettings) -> Data {
        var awake: [String: Bool] = [:]
        for assertion in AwakeAssertion.allCases {
            awake[assertion.rawValue] = settings.isOn(assertion)
        }
        let document = Document(version: settings.version, awake: awake,
                                lidClosedAwakeArmedByRestwatt: settings.lidClosedAwakeArmedByRestwatt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of plain values cannot fail; an empty Data would decode to defaults.
        return (try? encoder.encode(document)) ?? Data()
    }

    public static func decode(_ data: Data) -> StoredSettings {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return StoredSettings()
        }
        var awake: [AwakeAssertion: Bool] = [:]
        for (key, value) in document.awake ?? [:] {
            if let assertion = AwakeAssertion(rawValue: key) {
                awake[assertion] = value
            }
        }
        return StoredSettings(
            version: document.version ?? StoredSettings.currentVersion,
            awake: awake,
            lidClosedAwakeArmedByRestwatt: document.lidClosedAwakeArmedByRestwatt ?? false)
    }
}

/// The observed state of a sync service.
public enum ServiceState: Equatable, Sendable {
    /// launchd reports a running instance, or the application is running.
    case running
    /// launchd has the service loaded but no instance runs right now (it starts on demand).
    case loadedIdle
    /// Not loaded, or the application is not running.
    case off
    /// The state could not be read; the text says why.
    case unknown(String)

    /// The checkmark: loaded counts as on because on-demand services idle between requests.
    public var isOn: Bool {
        switch self {
        case .running, .loadedIdle: return true
        case .off, .unknown: return false
        }
    }
}

/// A value read from the system, or the reason it could not be read.
public enum Observation<Value: Equatable & Sendable>: Equatable, Sendable {
    case known(Value)
    case unknown(String)
}

/// Everything the settings section renders from. Checkmarks come from held tokens and
/// observed system state, never from a stored intention.
public struct SettingsSnapshot: Equatable, Sendable {
    /// True while the app holds the assertion token.
    public var awake: [AwakeAssertion: Bool]
    /// `SleepDisabled` as `pmset -g` reports it.
    public var sleepDisabled: Observation<Bool>
    /// Mirror of `StoredSettings.lidClosedAwakeArmedByRestwatt`.
    public var armedByRestwatt: Bool
    /// Mirror of `StoredSettings.awake`, the remembered choice per assertion. Never decides
    /// a checkmark; it decides what a click on an off-looking, remembered assertion means.
    public var rememberedAwake: [AwakeAssertion: Bool]
    public var sync: [SyncService: ServiceState]
    /// Energy Mode of the current power source as `pmset -g custom` and `pmset -g cap` report it.
    public var energyMode: Observation<EnergyModeObservation>
    /// Reason the last action on a toggle failed; cleared when the next action succeeds.
    public var lastError: [SettingKey: String]
    /// Reason the settings file could not be written; nil after a successful write.
    public var storeError: String?

    public init(awake: [AwakeAssertion: Bool] = [:],
                sleepDisabled: Observation<Bool> = .unknown("not read yet"),
                armedByRestwatt: Bool = false,
                rememberedAwake: [AwakeAssertion: Bool] = [:],
                sync: [SyncService: ServiceState] = [:],
                energyMode: Observation<EnergyModeObservation> = .unknown("not read yet"),
                lastError: [SettingKey: String] = [:],
                storeError: String? = nil) {
        self.awake = awake
        self.sleepDisabled = sleepDisabled
        self.armedByRestwatt = armedByRestwatt
        self.rememberedAwake = rememberedAwake
        self.sync = sync
        self.energyMode = energyMode
        self.lastError = lastError
        self.storeError = storeError
    }

    public func isOn(_ key: SettingKey) -> Bool {
        switch key {
        case .awake(let assertion):
            return awake[assertion] ?? false
        case .lidClosedAwake:
            return sleepDisabled == .known(true)
        case .sync(let service):
            return sync[service]?.isOn ?? false
        case .energyMode(let mode):
            guard case .known(let observed) = energyMode else {
                return false
            }
            return observed.mode == mode
        }
    }
}
