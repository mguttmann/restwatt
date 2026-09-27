import Foundation

/// A failure an adapter reports back to the coordinator, with text fit for a menu row.
public struct SettingsFailure: Error, Equatable, Sendable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

// System access sits behind these protocols so the coordinator can be tested with doubles.

/// IOPM assertions held by this process.
public protocol PowerAssertionHolding {
    /// Returns the assertion token, or throws with the reason the system refused.
    func acquire(_ assertion: AwakeAssertion, name: String) throws -> UInt32
    func release(_ token: UInt32)
}

/// Launches one executable with fixed arguments and waits for it.
public protocol CommandRunning {
    func run(_ vector: CommandVector) -> CommandResult
}

/// A monotonic clock that can also wait. The bounded wait after a `launchctl` call runs on
/// it, so tests drive the wait without sleeping.
public protocol SettleClock: ClockReading {
    func pause(_ seconds: TimeInterval)
}

/// The settings file.
public protocol SettingsStoring {
    /// Defaults when there is no file or it cannot be read.
    func load() -> StoredSettings
    func save(_ settings: StoredSettings) throws
}

/// Other applications (OneDrive), by bundle identifier.
public protocol ApplicationControlling {
    func isRunning(bundleIdentifier: String) -> Bool
    /// Starts the application without activating it and hidden; throws when it is not installed
    /// or the launch was refused.
    func launchHidden(bundleIdentifier: String) throws
    /// Asks a running instance to quit; returns before it has quit.
    func requestQuit(bundleIdentifier: String) throws
}

/// What a privileged write left behind: the vectors that ran as root, and why the profile
/// did not finish when it did not. The coordinator decides the armed record on this, not
/// on a later observation that may be unreadable.
public struct PrivilegedWrite: Equatable, Sendable {
    /// Vectors that ran as root and succeeded, in order.
    public var applied: [CommandVector] = []
    /// Vectors a failed administrator dialog may have applied: the chain stops at its first
    /// failing call and osascript does not say which one it was. Empty when the dialog was
    /// cancelled (nothing ran) or never opened.
    public var unaccounted: [CommandVector] = []
    public var error: PrivilegeError?

    /// True when no vector can have reached pmset as root.
    public var nothingApplied: Bool {
        applied.isEmpty && unaccounted.isEmpty
    }
}

/// Writes a pmset profile as root: the passwordless `sudo -n` first, vector by vector; the
/// administrator dialog when sudo itself does not run a vector (a denial, or a failure of
/// sudo's own), and only for the vectors not yet applied. A vector that ran as root and
/// failed stops the profile with pmset's own stderr: no dialog for a command line that
/// would fail again, no re-run of applied vectors. Nothing but `pmset` with fixed keys
/// ever runs as root.
public struct PrivilegedRunner {
    private let commands: CommandRunning

    public init(commands: CommandRunning) {
        self.commands = commands
    }

    public func write(_ profile: PmsetProfile) -> PrivilegedWrite {
        write(profile.vectors)
    }

    /// Writes the vectors in order; the Energy Mode rows pass a single one.
    public func write(_ vectors: [CommandVector]) -> PrivilegedWrite {
        var outcome = PrivilegedWrite()
        var remaining = vectors[...]
        // Set when sudo failed for a reason other than a plain denial: the line that ran and
        // what sudo said, reported together with the dialog's outcome.
        var sudoFailure: String?
        while let vector = remaining.first {
            let sudoLine = SystemCommands.sudoNonInteractive(vector)
            let result = commands.run(sudoLine)
            if result.succeeded {
                outcome.applied.append(remaining.removeFirst())
                continue
            }
            if SystemStateParser.isSudoDenial(result) {
                break
            }
            if SystemStateParser.isSudoFailure(result) {
                sudoFailure = Self.commandLine(sudoLine, result)
                break
            }
            // pmset itself, as root: its exit status and its stderr, nothing else ran.
            outcome.error = .commandFailed(vector, exitStatus: result.exitStatus, message: Self.text(of: result))
            return outcome
        }
        guard !remaining.isEmpty else {
            return outcome
        }
        let script: CommandVector
        do {
            script = try SystemCommands.administratorScript(Array(remaining))
        } catch let error as PrivilegeError {
            outcome.error = error
            return outcome
        } catch {
            outcome.error = .declinedOrFailed(String(describing: error))
            return outcome
        }
        let result = commands.run(script)
        if result.succeeded {
            outcome.applied.append(contentsOf: remaining)
            return outcome
        }
        if !SystemStateParser.isDialogCancelled(result) {
            // The chain ran and stopped at a failing call: every call before it applied,
            // the failing one and the ones after it did not; which was which is unknown.
            outcome.unaccounted = Array(remaining.dropLast())
        }
        let dialogText = Self.text(of: result, fallback: "administrator dialog")
        outcome.error = .declinedOrFailed(sudoFailure.map { "\($0), then \(dialogText)" } ?? dialogText)
        return outcome
    }

    /// The head of stderr, else of stdout; the fallback plus the exit status when both are
    /// empty, or empty when there is no fallback.
    private static func text(of result: CommandResult, fallback: String = "") -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        if text.isEmpty {
            return fallback.isEmpty ? "" : "\(fallback) exit \(result.exitStatus)"
        }
        return SystemStateParser.head(text)
    }

    /// `<command line> exit <status>`, plus the head of the output when there is one.
    static func commandLine(_ vector: CommandVector, _ result: CommandResult) -> String {
        commandLine(vector, exitStatus: result.exitStatus, message: text(of: result))
    }

    static func commandLine(_ vector: CommandVector, exitStatus: Int32, message: String) -> String {
        let line = "\(vector.commandLine) exit \(exitStatus)"
        return message.isEmpty ? line : "\(line): \(message)"
    }
}

/// Owns the settings state: the held assertions, the settings file and the observed system
/// state. All calls are synchronous and expected on one thread (the app's main thread).
public final class SettingsCoordinator {
    /// How long a `launchctl` switch may take to show in `launchctl print` before the click
    /// counts as failed. launchd reports a job it is still spawning or tearing down in
    /// neither end state, so one read right after the calls is not enough. The main thread
    /// waits at most this long (plus the duration of the last read).
    public static let serviceSettleDeadline: TimeInterval = 2
    /// Pause between two reads of `launchctl print` while waiting.
    public static let serviceSettleInterval: TimeInterval = 0.2
    /// The most pauses one wait takes, so rounding in the clock never adds a read.
    static let serviceSettlePauses = Int((serviceSettleDeadline / serviceSettleInterval).rounded(.up))

    public private(set) var snapshot = SettingsSnapshot()

    private let store: SettingsStoring
    private let assertions: PowerAssertionHolding
    private let commands: CommandRunning
    private let applications: ApplicationControlling
    private let privileged: PrivilegedRunner
    private let uid: uid_t
    private let clock: SettleClock
    private var stored: StoredSettings
    private var persisted: StoredSettings
    private var tokens: [AwakeAssertion: UInt32] = [:]
    /// The state each failed action wanted, per toggle with a warning. A later read that
    /// shows that state drops the warning: it no longer describes what the menu shows.
    private var wantedAfterFailure: [SettingKey: WantedState] = [:]

    public init(store: SettingsStoring, assertions: PowerAssertionHolding, commands: CommandRunning,
                applications: ApplicationControlling, uid: uid_t, clock: SettleClock) {
        self.store = store
        self.assertions = assertions
        self.commands = commands
        self.applications = applications
        self.privileged = PrivilegedRunner(commands: commands)
        self.uid = uid
        self.clock = clock
        stored = StoredSettings()
        persisted = stored
    }

    /// Loads the file, re-acquires the remembered assertions and closes the crash gap of the
    /// lid-closed setting. Writes pmset only when Restwatt itself armed it.
    public func applyStoredAtLaunch() {
        stored = store.load()
        persisted = stored
        snapshot.armedByRestwatt = stored.lidClosedAwakeArmedByRestwatt
        snapshot.rememberedAwake = stored.awake
        let observed = readSleepDisabled()
        snapshot.sleepDisabled = observed
        perform(SettingsReconciler.launchActions(stored: stored, observedSleepDisabled: observed))
        refreshObserved()
    }

    /// Re-reads everything the checkmarks show. Called when the menu opens and after actions.
    public func refreshObserved() {
        snapshot.sleepDisabled = readSleepDisabled()
        snapshot.energyMode = readEnergyMode()
        for service in SyncService.allCases {
            snapshot.sync[service] = readServiceState(service)
        }
        for assertion in AwakeAssertion.allCases {
            snapshot.awake[assertion] = tokens[assertion] != nil
        }
        snapshot.armedByRestwatt = stored.lidClosedAwakeArmedByRestwatt
        snapshot.rememberedAwake = stored.awake
        dropWarningsTheSystemNoLongerShows()
    }

    /// A click on the toggle: performs its actions, re-reads the state, then settles the
    /// armed record against it (a write-ahead record whose write did not land is dropped).
    public func toggle(_ key: SettingKey) {
        perform(SettingsReconciler.toggleActions(key: key, snapshot: snapshot))
        refreshObserved()
        // Bookkeeping, not an action of its own: the reason the click failed stays visible.
        perform(SettingsReconciler.settleActions(armed: stored.lidClosedAwakeArmedByRestwatt,
                                                 observedSleepDisabled: snapshot.sleepDisabled),
                clearingErrors: false)
    }

    /// Takes back the lid-closed setting if Restwatt armed it. The assertions need no work:
    /// the process ending releases them.
    public func willTerminate() {
        guard stored.lidClosedAwakeArmedByRestwatt else {
            return
        }
        let observed = readSleepDisabled()
        perform(SettingsReconciler.quitActions(armed: true, observedSleepDisabled: observed))
    }

    // MARK: Actions

    /// Runs every action and records each outcome on its own toggle. A failure never stops
    /// the list: the actions are independent of each other, and the one dependency that
    /// exists (armed and the pmset write belong together) is inside `.writePmset` itself.
    private func perform(_ actions: [SettingsAction], clearingErrors: Bool = true) {
        for action in actions {
            let key = Self.key(of: action)
            switch execute(action) {
            case .success:
                if clearingErrors {
                    snapshot.lastError[key] = nil
                    wantedAfterFailure[key] = nil
                }
            case .failure(let failure):
                snapshot.lastError[key] = failure.reason
                wantedAfterFailure[key] = WantedState(of: action)
            }
        }
        saveIfChanged()
    }

    /// Drops each warning whose failed action wanted exactly the state just read. Only
    /// warnings with a `WantedState` qualify; the others stay until the next successful
    /// action on their toggle.
    private func dropWarningsTheSystemNoLongerShows() {
        for (key, wanted) in wantedAfterFailure where wanted.isObserved(in: snapshot) {
            snapshot.lastError[key] = nil
            wantedAfterFailure[key] = nil
        }
    }

    private static func key(of action: SettingsAction) -> SettingKey {
        switch action {
        case .acquire(let assertion), .release(let assertion):
            return .awake(assertion)
        case .writePmset, .setArmed, .refuseLidClosedWrite:
            return .lidClosedAwake
        case .bootstrapAndKickstart(let service), .bootout(let service),
             .launchApplication(let service), .quitApplication(let service):
            return .sync(service)
        case .writeEnergyMode(let mode, _), .refuseEnergyModeWrite(let mode, _):
            return .energyMode(mode)
        }
    }

    private func execute(_ action: SettingsAction) -> Result<Void, SettingsFailure> {
        switch action {
        case .acquire(let assertion):
            if tokens[assertion] != nil {
                return .success(())
            }
            do {
                tokens[assertion] = try assertions.acquire(assertion, name: assertion.assertionName)
                stored.awake[assertion] = true
                return .success(())
            } catch {
                // The stored choice stays as it is: a remembered assertion the system refuses
                // right now shows off with the reason and is tried again at the next launch;
                // a refused click from off changes nothing, so no file appears for it.
                return .failure(Self.failure(error))
            }

        case .release(let assertion):
            // Without a token this only clears the remembered choice: the click on a stored
            // assertion the system refuses takes the choice out of the file.
            if let token = tokens.removeValue(forKey: assertion) {
                assertions.release(token)
            }
            stored.awake[assertion] = false
            return .success(())

        case .writePmset(let profile, let armed):
            let recordWrittenAhead = armed && !stored.lidClosedAwakeArmedByRestwatt
            if recordWrittenAhead {
                // Write-ahead: the record goes to disk before root touches pmset. Without the
                // record there is no write, or a crash in between would leave a
                // `disablesleep 1` nobody takes back.
                stored.lidClosedAwakeArmedByRestwatt = true
                if let failure = saveIfChanged() {
                    stored.lidClosedAwakeArmedByRestwatt = false
                    return .failure(SettingsFailure("not written, the settings file could not be saved: \(failure.reason)"))
                }
                snapshot.armedByRestwatt = true
            }
            let outcome = privileged.write(profile)
            guard let error = outcome.error else {
                stored.lidClosedAwakeArmedByRestwatt = armed
                snapshot.armedByRestwatt = armed
                return .success(())
            }
            if recordWrittenAhead, !Self.keepsWriteAheadRecord(outcome) {
                // The record follows the outcome of the write, not a later observation that
                // may be unreadable: nothing reached pmset, so there is nothing to take back.
                stored.lidClosedAwakeArmedByRestwatt = false
                snapshot.armedByRestwatt = false
            }
            return .failure(Self.failure(error))

        case .setArmed(let armed):
            stored.lidClosedAwakeArmedByRestwatt = armed
            snapshot.armedByRestwatt = armed
            return .success(())

        case .refuseLidClosedWrite:
            // The reason sits in the note under the toggle already; it is not repeated here.
            return .failure(SettingsFailure("not written while SleepDisabled could not be read"))

        case .bootstrapAndKickstart(let service):
            guard let bootstrap = SystemCommands.launchctlBootstrap(service, uid: uid),
                  let kickstart = SystemCommands.launchctlKickstart(service, uid: uid) else {
                return .failure(SettingsFailure("\(service.label) is not a launchd service"))
            }
            // The scripts ignore both exit codes and judge by the resulting state; so does this.
            let calls = [bootstrap, kickstart]
            return checkServiceState(service, wanted: true, calls: calls, results: calls.map(commands.run))

        case .bootout(let service):
            guard let bootout = SystemCommands.launchctlBootout(service, uid: uid) else {
                return .failure(SettingsFailure("\(service.label) is not a launchd service"))
            }
            return checkServiceState(service, wanted: false, calls: [bootout], results: [commands.run(bootout)])

        case .launchApplication(let service):
            // The primary bundle identifier's error is the one worth showing; the others are
            // fallbacks for a differently packaged build.
            var primaryError: Error?
            for identifier in service.bundleIdentifiers {
                do {
                    try applications.launchHidden(bundleIdentifier: identifier)
                    return .success(())
                } catch {
                    primaryError = primaryError ?? error
                }
            }
            return .failure(primaryError.map(Self.failure) ?? SettingsFailure("\(service.label) has no bundle identifier"))

        case .quitApplication(let service):
            var quitOne = false
            for identifier in service.bundleIdentifiers where applications.isRunning(bundleIdentifier: identifier) {
                do {
                    try applications.requestQuit(bundleIdentifier: identifier)
                    quitOne = true
                } catch {
                    return .failure(Self.failure(error))
                }
            }
            return quitOne ? .success(()) : .failure(SettingsFailure("\(service.label) is not running"))

        case .writeEnergyMode(let mode, let source):
            let outcome = privileged.write([SystemCommands.pmsetEnergyMode(mode, source: source)])
            if let error = outcome.error {
                return .failure(Self.failure(error))
            }
            return checkEnergyMode(mode, source: source)

        case .refuseEnergyModeWrite:
            // The reason sits in the note under the group already; it is not repeated here.
            return .failure(SettingsFailure("not written while the power source could not be read"))
        }
    }

    /// Success is the value read back, not pmset's exit status: a key pmset accepts but does
    /// not act on, or a mapping other than assumed, shows up here instead of as a wrong checkmark.
    private func checkEnergyMode(_ mode: EnergyMode, source: PowerSource) -> Result<Void, SettingsFailure> {
        let observed = readEnergyMode()
        snapshot.energyMode = observed
        let accepted = "pmset accepted \(SystemCommands.energyModeKey) \(mode.rawValue)"
        switch observed {
        case .known(let observation) where observation.source != source:
            return .failure(SettingsFailure(
                "\(accepted) for \(source.rawValue), but the power source is now \(observation.source.rawValue)"))
        case .known(let observation):
            if observation.mode == mode {
                return .success(())
            }
            let reported = observation.rawValue.map { "powermode \($0)" } ?? "no powermode line"
            return .failure(SettingsFailure("\(accepted) but reports \(reported) for \(source.rawValue)"))
        case .unknown(let reason):
            return .failure(SettingsFailure("written, but the energy mode could not be re-read: \(reason)"))
        }
    }

    /// Success is the observed state after the calls, not their exit codes: `launchctl print`
    /// is read until it shows the wanted state or `serviceSettleDeadline` has passed. A miss
    /// names the calls that failed, with their exit status and stderr, or, when every call
    /// succeeded, the state launchd reported at the deadline.
    private func checkServiceState(_ service: SyncService, wanted: Bool, calls: [CommandVector],
                                   results: [CommandResult]) -> Result<Void, SettingsFailure> {
        let state = awaitServiceState(service, wanted: wanted)
        snapshot.sync[service] = state
        if state.matches(wanted: wanted) {
            return .success(())
        }
        let failed = zip(calls, results).filter { !$0.1.succeeded }.map { vector, result in
            let call = "\(vector.arguments.first ?? vector.commandLine) exit \(result.exitStatus)"
            return result.stderr.isEmpty ? call : "\(call): \(SystemStateParser.head(result.stderr))"
        }
        if !failed.isEmpty {
            return .failure(SettingsFailure("launchctl \(failed.joined(separator: "; "))"))
        }
        let seconds = String(format: "%g", Self.serviceSettleDeadline)
        return .failure(SettingsFailure(
            "launchctl succeeded, but launchd reports \(Self.describe(state)) after \(seconds) s"))
    }

    /// Reads the service state until it matches the wanted one; the reads stop once
    /// `serviceSettleDeadline` has passed since the first one.
    private func awaitServiceState(_ service: SyncService, wanted: Bool) -> ServiceState {
        let start = clock.now
        var state = readServiceState(service)
        for _ in 0..<Self.serviceSettlePauses where !state.matches(wanted: wanted) {
            let remaining = Self.serviceSettleDeadline - (clock.now - start)
            guard remaining > 0 else {
                break
            }
            clock.pause(min(Self.serviceSettleInterval, remaining))
            state = readServiceState(service)
        }
        return state
    }

    private static func describe(_ state: ServiceState) -> String {
        switch state {
        case .running: return "it running"
        case .loadedIdle: return "it loaded, not running"
        case .off: return "it not loaded"
        case .unknown(let reason): return "no known state (\(reason))"
        }
    }

    private static func failure(_ error: Error) -> SettingsFailure {
        (error as? SettingsFailure) ?? SettingsFailure(String(describing: error))
    }

    private static func failure(_ error: PrivilegeError) -> SettingsFailure {
        switch error {
        case .declinedOrFailed(let reason):
            return SettingsFailure(reason)
        case .commandFailed(let vector, let exitStatus, let message):
            return SettingsFailure(PrivilegedRunner.commandLine(vector, exitStatus: exitStatus, message: message))
        case .invalidToken(let token):
            return SettingsFailure("refused to run token \(token)")
        }
    }

    /// Whether a write-ahead record survives a failed awake write: only when a vector was,
    /// or may have been, applied, so quit or the next launch takes it back. A write that
    /// reached nothing (cancelled dialog, sudo denied and dialog declined, the one vector
    /// refused) is disarmed at once, whatever `pmset -g` says afterwards.
    static func keepsWriteAheadRecord(_ outcome: PrivilegedWrite) -> Bool {
        !outcome.nothingApplied
    }

    // MARK: Observation

    private func readSleepDisabled() -> Observation<Bool> {
        let result = commands.run(SystemCommands.pmsetRead)
        guard result.succeeded else {
            return .unknown("pmset -g exit \(result.exitStatus): \(SystemStateParser.head(result.stderr))")
        }
        guard let disabled = SystemStateParser.parseSleepDisabled(pmsetOutput: result.stdout) else {
            return .unknown("pmset -g printed no settings")
        }
        return .known(disabled)
    }

    /// The current source and its Energy Mode: `pmset -g cap` names the source and lists
    /// whether it can set `highpowermode`, `pmset -g custom` carries the value per source.
    private func readEnergyMode() -> Observation<EnergyModeObservation> {
        let capabilities = commands.run(SystemCommands.pmsetReadCapabilities)
        guard capabilities.succeeded else {
            return .unknown("pmset -g cap exit \(capabilities.exitStatus): \(SystemStateParser.head(capabilities.stderr))")
        }
        guard let parsed = SystemStateParser.parseCapabilities(pmsetCapOutput: capabilities.stdout) else {
            return .unknown("pmset -g cap printed no capabilities")
        }
        guard let source = parsed.source else {
            return .unknown("pmset -g cap names an unknown power source")
        }
        let custom = commands.run(SystemCommands.pmsetReadCustom)
        guard custom.succeeded else {
            return .unknown("pmset -g custom exit \(custom.exitStatus): \(SystemStateParser.head(custom.stderr))")
        }
        guard let modes = SystemStateParser.parsePowerModes(pmsetCustomOutput: custom.stdout) else {
            return .unknown("pmset -g custom printed no settings")
        }
        guard let rawValue = modes[source] else {
            return .unknown("pmset -g custom has no \(source.rawValue) block")
        }
        return .known(EnergyModeObservation(source: source, rawValue: rawValue,
                                            highPowerCapable: parsed.keys.contains("highpowermode")))
    }

    private func readServiceState(_ service: SyncService) -> ServiceState {
        if service.isLaunchdService {
            return SystemStateParser.parseLaunchctlPrint(
                commands.run(SystemCommands.launchctlPrint(service.rawValue, uid: uid)))
        }
        let running = service.bundleIdentifiers.contains { applications.isRunning(bundleIdentifier: $0) }
        return running ? .running : .off
    }

    // MARK: Store

    /// Writes the file only when something changed, so a launch that toggles nothing leaves
    /// no file behind. Returns the failure so a write-ahead step can refuse to go on.
    @discardableResult
    private func saveIfChanged() -> SettingsFailure? {
        guard stored != persisted else {
            return nil
        }
        do {
            try store.save(stored)
            persisted = stored
            snapshot.storeError = nil
            return nil
        } catch {
            let failure = Self.failure(error)
            snapshot.storeError = failure.reason
            return failure
        }
    }
}

/// The state a failed action wanted, where one read of the system shows all of it. Actions
/// whose effect the read covers only in part have none (the saver profile writes four
/// vectors, `SleepDisabled` shows only the first), so their warning is never dropped by an
/// observation.
enum WantedState: Equatable {
    case service(SyncService, on: Bool)
    case sleepDisabled
    case energyMode(EnergyMode, PowerSource)

    init?(of action: SettingsAction) {
        switch action {
        case .bootstrapAndKickstart(let service), .launchApplication(let service):
            self = .service(service, on: true)
        case .bootout(let service), .quitApplication(let service):
            self = .service(service, on: false)
        case .writePmset(.awake, _):
            // One vector; `disablesleep 1` is its last key.
            self = .sleepDisabled
        case .writeEnergyMode(let mode, let source):
            self = .energyMode(mode, source)
        case .acquire, .release, .writePmset, .setArmed, .refuseLidClosedWrite, .refuseEnergyModeWrite:
            // Assertions are held, not read from the system; a refusal names a read that
            // failed, not a state that was wanted.
            return nil
        }
    }

    func isObserved(in snapshot: SettingsSnapshot) -> Bool {
        switch self {
        case .service(let service, let on):
            return snapshot.sync[service]?.matches(wanted: on) ?? false
        case .sleepDisabled:
            return snapshot.sleepDisabled == .known(true)
        case .energyMode(let mode, let source):
            guard case .known(let observed) = snapshot.energyMode else {
                return false
            }
            return observed.source == source && observed.mode == mode
        }
    }
}

extension ServiceState {
    /// On is running or loaded; off is only a service launchd does not list (or an
    /// application that does not run), never a state that could not be read.
    func matches(wanted on: Bool) -> Bool {
        on ? isOn : self == .off
    }
}
