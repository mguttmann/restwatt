import Foundation

/// One step the coordinator performs. The reconciler decides the list; the coordinator runs
/// every step and records each failure on its own toggle: no step is skipped because an
/// unrelated earlier step failed (the crash-gap reset must not hang on an IOKit refusal).
/// The only dependency there is, "armed follows the pmset write", lives inside one step:
/// `writePmset` carries the armed flag and the coordinator sets it only when the write
/// succeeded.
public enum SettingsAction: Equatable, Sendable {
    case acquire(AwakeAssertion)
    case release(AwakeAssertion)
    /// Writes the profile as root and, only on success, records `thenArmed`.
    case writePmset(PmsetProfile, thenArmed: Bool)
    /// Records the armed flag without a write (the system is already in the wanted state).
    case setArmed(Bool)
    case bootstrapAndKickstart(SyncService)
    case bootout(SyncService)
    case launchApplication(SyncService)
    case quitApplication(SyncService)
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
            return actions
        }
        switch observedSleepDisabled {
        case .known(true):
            // Restwatt armed it and did not get to reset it (crash, kill, power loss).
            actions.append(.writePmset(.saver, thenArmed: false))
        case .known(false):
            // Somebody else already reset it; nothing to write.
            actions.append(.setArmed(false))
        case .unknown:
            // Cannot tell; leave armed so the quit reconcile tries again.
            break
        }
        return actions
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

    /// A click on a toggle that currently shows `currentlyOn`.
    public static func toggleActions(key: SettingKey, currentlyOn: Bool) -> [SettingsAction] {
        switch key {
        case .awake(let assertion):
            return [currentlyOn ? .release(assertion) : .acquire(assertion)]
        case .lidClosedAwake:
            return currentlyOn
                ? [.writePmset(.saver, thenArmed: false)]
                : [.writePmset(.awake, thenArmed: true)]
        case .sync(let service):
            if service.isLaunchdService {
                return [currentlyOn ? .bootout(service) : .bootstrapAndKickstart(service)]
            }
            return [currentlyOn ? .quitApplication(service) : .launchApplication(service)]
        }
    }
}
