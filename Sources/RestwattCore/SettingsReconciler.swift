import Foundation

/// One step the coordinator performs. The reconciler decides the list; the coordinator runs
/// every step and records each failure on its own toggle: no step is skipped because an
/// unrelated earlier step failed (the crash-gap reset must not hang on an IOKit refusal).
/// The only dependency there is, "armed and the pmset write belong together", lives inside
/// one step: `writePmset` carries the armed flag.
public enum SettingsAction: Equatable, Sendable {
    case acquire(AwakeAssertion)
    case release(AwakeAssertion)
    /// Writes the profile as root. `thenArmed: true` is write-ahead: the armed record is
    /// persisted BEFORE the root write and the write is refused when the file cannot be
    /// saved, so a crash in between leaves a record, never an unrecorded `disablesleep 1`.
    /// `thenArmed: false` is recorded after the write succeeded, so a crash in between keeps
    /// the record and the next launch takes the setting back again.
    case writePmset(PmsetProfile, thenArmed: Bool)
    /// Records the armed flag without a write (the system is already in the wanted state).
    case setArmed(Bool)
    /// Refuses to write the awake profile because `SleepDisabled` could not be read; the text
    /// is the reason the read failed and lands under the lid-closed toggle.
    case refuseLidClosedWrite(String)
    case bootstrapAndKickstart(SyncService)
    case bootout(SyncService)
    case launchApplication(SyncService)
    case quitApplication(SyncService)
    /// Writes the Energy Mode of the given source as root, one fixed vector, and judges
    /// success by the value read back. Nothing is stored and nothing is armed.
    case writeEnergyMode(EnergyMode, PowerSource)
    /// Refuses to write the Energy Mode because the current power source could not be read;
    /// the text is the reason and lands under the clicked row.
    case refuseEnergyModeWrite(EnergyMode, String)
}

/// Pure decisions: what the stored choice and the observed system state imply.
///
/// The lid-closed toggle is not stored as a choice but as the fact "Restwatt itself set
/// `disablesleep 1` and has not reset it". Only that fact ever triggers a write without a
/// click: a `SleepDisabled 1` Restwatt did not set (Manuel's script, another tool) is left
/// alone and shown as set outside Restwatt.
public enum SettingsReconciler {
    /// At launch: re-acquire the remembered assertions, then close the crash gap.
    public static func launchActions(stored: StoredSettings,
                                     observedSleepDisabled: Observation<Bool>) -> [SettingsAction] {
        var actions: [SettingsAction] = []
        for assertion in AwakeAssertion.allCases where stored.isOn(assertion) {
            actions.append(.acquire(assertion))
        }
        guard stored.lidClosedAwakeArmedByRestwatt else {
            // Not armed: a `SleepDisabled 1` is somebody else's (shown as set outside
            // Restwatt), a `0` is nothing. Neither is touched.
            return actions
        }
        switch observedSleepDisabled {
        case .known(true):
            // Restwatt armed it and did not get to reset it (crash, kill, power loss).
            actions.append(.writePmset(.saver, thenArmed: false))
        case .known(false):
            // The write never landed (write-ahead record, then a refused or crashed write),
            // or somebody else already reset it; nothing to write.
            actions.append(contentsOf: settleActions(armed: true, observedSleepDisabled: observedSleepDisabled))
        case .unknown:
            // Cannot tell; leave armed so the quit reconcile tries again.
            break
        }
        return actions
    }

    /// The one rule launch and a finished click share: an armed record against an observed
    /// `SleepDisabled 0` is a write that never landed or was taken back by somebody else, so
    /// the record is dropped quietly. Any other combination is left to the caller.
    public static func settleActions(armed: Bool,
                                     observedSleepDisabled: Observation<Bool>) -> [SettingsAction] {
        guard armed, observedSleepDisabled == .known(false) else {
            return []
        }
        return [.setArmed(false)]
    }

    /// At quit: take back what Restwatt set, unless it is already reset.
    public static func quitActions(armed: Bool,
                                   observedSleepDisabled: Observation<Bool>) -> [SettingsAction] {
        guard armed else {
            return []
        }
        if observedSleepDisabled == .known(false) {
            return [.setArmed(false)]
        }
        return [.writePmset(.saver, thenArmed: false)]
    }

    /// A click on a toggle, judged against the snapshot the menu was rendered from.
    public static func toggleActions(key: SettingKey, snapshot: SettingsSnapshot) -> [SettingsAction] {
        let currentlyOn = snapshot.isOn(key)
        switch key {
        case .awake(let assertion):
            // A remembered choice the system refuses shows off with the reason; the click on
            // it clears the choice instead of trying again, so the file can be cleaned from
            // the menu. The next launch still retries a choice that is kept.
            let remembered = snapshot.rememberedAwake[assertion] ?? false
            return [currentlyOn || remembered ? .release(assertion) : .acquire(assertion)]
        case .lidClosedAwake:
            switch snapshot.sleepDisabled {
            case .known(true):
                return [.writePmset(.saver, thenArmed: false)]
            case .known(false):
                return [.writePmset(.awake, thenArmed: true)]
            case .unknown(let reason):
                // The checkmark shows off because nothing could be read. Writing the awake
                // profile blind could never be switched off from the menu again, so it is
                // refused. Turning off is the safe direction and stays allowed: when Restwatt
                // itself armed the setting, the click takes it back.
                return snapshot.armedByRestwatt
                    ? [.writePmset(.saver, thenArmed: false)]
                    : [.refuseLidClosedWrite(reason)]
            }
        case .sync(let service):
            if service.isLaunchdService {
                return [currentlyOn ? .bootout(service) : .bootstrapAndKickstart(service)]
            }
            return [currentlyOn ? .quitApplication(service) : .launchApplication(service)]
        case .energyMode(let mode):
            switch snapshot.energyMode {
            case .known(let observed):
                // A click on the row already marked is a no-op (radio behaviour, no root call).
                return observed.mode == mode ? [] : [.writeEnergyMode(mode, observed.source)]
            case .unknown(let reason):
                // Without the current source there is no flag to write with; guessing one
                // could change the wrong source, so the click is refused.
                return [.refuseEnergyModeWrite(mode, reason)]
            }
        }
    }
}
