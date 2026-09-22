import Foundation

/// One line of the settings section in the click menu. Separate from `DetailRow` because the
/// popover never shows settings and these rows carry a checkmark state.
public struct SettingsRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading
        /// A clickable toggle; `isOn` is the observed or held state, never a stored intention.
        case toggle(SettingKey, isOn: Bool)
        /// The Open at Login item; `isOn` is the status read from the system.
        case openAtLogin(isOn: Bool)
        /// Indented explanation under a toggle.
        case note
        /// Indented failure text under a toggle.
        case warning
    }

    public var kind: Kind
    public var label: String
    /// Right-hand text (state of a sync service); empty when there is none.
    public var detail: String

    public init(_ kind: Kind, _ label: String, detail: String = "") {
        self.kind = kind
        self.label = label
        self.detail = detail
    }
}

extension Formatting {
    /// Shown under the lid-closed toggle at all times.
    public static let lidClosedNote = "system-wide, needs administrator, restored when Restwatt quits"
    /// Shown when `SleepDisabled 1` is observed but Restwatt did not set it.
    public static let setOutsideRestwattNote = "set outside Restwatt"
    public static let powerHeading = "Power"
    public static let syncHeading = "Sync"
    /// Apple's group title in its own battery menu.
    public static let energyModeHeading = "Energy Mode"
    /// Apple's line naming the source the Energy Mode applies to.
    public static let powerSourceNotePrefix = "Power Source: "

    /// The settings section, top to bottom.
    public static func settingsRows(_ snapshot: SettingsSnapshot) -> [SettingsRow] {
        var rows: [SettingsRow] = [SettingsRow(.heading, powerHeading)]
        for assertion in AwakeAssertion.allCases {
            let key = SettingKey.awake(assertion)
            rows.append(SettingsRow(.toggle(key, isOn: snapshot.isOn(key)), key.label))
            rows.append(contentsOf: warningRows(snapshot, key))
        }

        let lid = SettingKey.lidClosedAwake
        rows.append(SettingsRow(.toggle(lid, isOn: snapshot.isOn(lid)), lid.label))
        rows.append(SettingsRow(.note, lidClosedNote))
        switch snapshot.sleepDisabled {
        case .known(true) where !snapshot.armedByRestwatt:
            rows.append(SettingsRow(.note, setOutsideRestwattNote))
        case .unknown(let reason):
            rows.append(SettingsRow(.note, "could not read pmset: \(reason)"))
        case .known:
            break
        }
        rows.append(contentsOf: warningRows(snapshot, lid))

        rows.append(contentsOf: energyModeRows(snapshot))

        rows.append(SettingsRow(.heading, syncHeading))
        for service in SyncService.allCases {
            let key = SettingKey.sync(service)
            rows.append(SettingsRow(.toggle(key, isOn: snapshot.isOn(key)), key.label,
                                    detail: serviceDetail(snapshot.sync[service], service)))
            rows.append(contentsOf: warningRows(snapshot, key))
        }

        if let storeError = snapshot.storeError {
            rows.append(SettingsRow(.warning, "settings could not be saved: \(storeError)"))
        }
        return rows
    }

    /// The Energy Mode group: the source the change applies to, one radio row per mode with
    /// its raw `powermode` value, and a note whenever the checkmark rests on an inference or
    /// on nothing. Exactly the row whose value was read back is marked; never a stored one.
    private static func energyModeRows(_ snapshot: SettingsSnapshot) -> [SettingsRow] {
        var rows: [SettingsRow] = [SettingsRow(.heading, energyModeHeading)]
        var offered: [EnergyMode] = [.automatic, .lowPower]
        var notes: [SettingsRow] = []
        switch snapshot.energyMode {
        case .known(let observed):
            rows.append(SettingsRow(.note, powerSourceNotePrefix + observed.source.label))
            if observed.offersHighPower {
                offered.append(.highPower)
            }
            if let rawValue = observed.rawValue {
                if observed.mode == nil {
                    notes.append(SettingsRow(.note, "powermode \(rawValue) is not a known energy mode"))
                }
            } else {
                notes.append(SettingsRow(.note, "pmset lists no powermode for \(observed.source.rawValue), read as Automatic"))
            }
        case .unknown(let reason):
            rows.append(SettingsRow(.note, powerSourceNotePrefix + "unknown"))
            notes.append(SettingsRow(.note, "could not read energy mode: \(reason)"))
        }
        for mode in offered {
            let key = SettingKey.energyMode(mode)
            rows.append(SettingsRow(.toggle(key, isOn: snapshot.isOn(key)), key.label, detail: mode.rawDetail))
            rows.append(contentsOf: warningRows(snapshot, key))
        }
        rows.append(contentsOf: notes)
        return rows
    }

    private static func warningRows(_ snapshot: SettingsSnapshot, _ key: SettingKey) -> [SettingsRow] {
        guard let reason = snapshot.lastError[key] else {
            return []
        }
        return [SettingsRow(.warning, "could not change: \(reason)")]
    }

    static func serviceDetail(_ state: ServiceState?, _ service: SyncService) -> String {
        switch state {
        case .running:
            return "running"
        case .loadedIdle:
            return "idle, starts on demand"
        case .off, nil:
            return service.isLaunchdService ? "off" : "not running"
        case .unknown(let reason):
            return "state unknown: \(reason)"
        }
    }
}
