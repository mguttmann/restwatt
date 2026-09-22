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

/// Writes a pmset profile as root: the passwordless `sudo -n` first, vector by vector; the
/// administrator dialog only when sudo itself refuses, and only for the vectors not yet
/// applied. A vector that ran as root and failed stops the profile with its own stderr: no
/// dialog for a command line that would fail again, no re-run of applied vectors. Nothing
/// but `pmset` with fixed keys ever runs as root.
public struct PrivilegedRunner {
    private let commands: CommandRunning

    public init(commands: CommandRunning) {
        self.commands = commands
    }

    public func write(_ profile: PmsetProfile) -> Result<Void, PrivilegeError> {
        let vectors = profile.vectors
        var remaining = vectors[...]
        while let vector = remaining.first {
            let result = commands.run(SystemCommands.sudoNonInteractive(vector))
            if result.succeeded {
                remaining.removeFirst()
                continue
            }
            if SystemStateParser.isSudoDenial(result) {
                break
            }
            return .failure(.commandFailed(vector, exitStatus: result.exitStatus, message: Self.text(of: result)))
        }
        guard !remaining.isEmpty else {
            return .success(())
        }
        let script: CommandVector
        do {
            script = try SystemCommands.administratorScript(Array(remaining))
        } catch let error as PrivilegeError {
            return .failure(error)
        } catch {
            return .failure(.declinedOrFailed(String(describing: error)))
        }
        let result = commands.run(script)
        if result.succeeded {
            return .success(())
        }
        return .failure(.declinedOrFailed(Self.text(of: result, fallback: "administrator dialog")))
    }

    /// The head of stderr, else of stdout, else the exit status.
    private static func text(of result: CommandResult, fallback: String = "") -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        if text.isEmpty {
            return "\(fallback.isEmpty ? "" : fallback + " ")exit \(result.exitStatus)"
        }
        return SystemStateParser.head(text)
    }
}

/// Owns the settings state: the held assertions, the settings file and the observed system
/// state. All calls are synchronous and expected on one thread (the app's main thread).
public final class SettingsCoordinator {
    public private(set) var snapshot = SettingsSnapshot()

    private let store: SettingsStoring
    private let assertions: PowerAssertionHolding
    private let commands: CommandRunning
    private let applications: ApplicationControlling
    private let privileged: PrivilegedRunner
    private let uid: uid_t
    private var stored: StoredSettings
    private var persisted: StoredSettings
    private var tokens: [AwakeAssertion: UInt32] = [:]

    public init(store: SettingsStoring, assertions: PowerAssertionHolding, commands: CommandRunning,
                applications: ApplicationControlling, uid: uid_t) {
        self.store = store
        self.assertions = assertions
        self.commands = commands
        self.applications = applications
        self.privileged = PrivilegedRunner(commands: commands)
        self.uid = uid
        stored = StoredSettings()
        persisted = stored
    }

    /// Loads the file, re-acquires the remembered assertions and closes the crash gap of the
    /// lid-closed setting. Writes pmset only when Restwatt itself armed it.
    public func applyStoredAtLaunch() {
        stored = store.load()
        persisted = stored
        snapshot.armedByRestwatt = stored.lidClosedAwakeArmedByRestwatt
        let observed = readSleepDisabled()
        snapshot.sleepDisabled = observed
        perform(SettingsReconciler.launchActions(stored: stored, observedSleepDisabled: observed))
        refreshObserved()
    }

    /// Re-reads everything the checkmarks show. Called when the menu opens and after actions.
    public func refreshObserved() {
        snapshot.sleepDisabled = readSleepDisabled()
        for service in SyncService.allCases {
            snapshot.sync[service] = readServiceState(service)
        }
        for assertion in AwakeAssertion.allCases {
            snapshot.awake[assertion] = tokens[assertion] != nil
        }
        snapshot.armedByRestwatt = stored.lidClosedAwakeArmedByRestwatt
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
                }
            case .failure(let failure):
                snapshot.lastError[key] = failure.reason
            }
        }
        saveIfChanged()
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
            if let token = tokens.removeValue(forKey: assertion) {
                assertions.release(token)
            }
            stored.awake[assertion] = false
            return .success(())

        case .writePmset(let profile, let armed):
            if armed, !stored.lidClosedAwakeArmedByRestwatt {
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
            switch privileged.write(profile) {
            case .success:
                stored.lidClosedAwakeArmedByRestwatt = armed
                snapshot.armedByRestwatt = armed
                return .success(())
            case .failure(.declinedOrFailed(let reason)):
                return .failure(SettingsFailure(reason))
            case .failure(.commandFailed(let vector, let exitStatus, let message)):
                return .failure(SettingsFailure("\(vector.commandLine) exit \(exitStatus): \(message)"))
            case .failure(.invalidToken(let token)):
                return .failure(SettingsFailure("refused to run token \(token)"))
            }

        case .setArmed(let armed):
            stored.lidClosedAwakeArmedByRestwatt = armed
            snapshot.armedByRestwatt = armed
            return .success(())

        case .refuseLidClosedWrite(let reason):
            return .failure(SettingsFailure("not written, could not read pmset: \(reason)"))

        case .bootstrapAndKickstart(let service):
            guard let bootstrap = SystemCommands.launchctlBootstrap(service, uid: uid),
                  let kickstart = SystemCommands.launchctlKickstart(service, uid: uid) else {
                return .failure(SettingsFailure("\(service.label) is not a launchd service"))
            }
            // The scripts ignore both exit codes and judge by the resulting state; so does this.
            let bootstrapResult = commands.run(bootstrap)
            let kickstartResult = commands.run(kickstart)
            return checkServiceState(service, wanted: true, results: [bootstrapResult, kickstartResult])

        case .bootout(let service):
            guard let bootout = SystemCommands.launchctlBootout(service, uid: uid) else {
                return .failure(SettingsFailure("\(service.label) is not a launchd service"))
            }
            let result = commands.run(bootout)
            return checkServiceState(service, wanted: false, results: [result])

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
        }
    }

    /// Success is the observed state after the calls, not their exit codes; the exit codes
    /// only explain a miss.
    private func checkServiceState(_ service: SyncService, wanted: Bool,
                                   results: [CommandResult]) -> Result<Void, SettingsFailure> {
        let state = readServiceState(service)
        snapshot.sync[service] = state
        if state.isOn == wanted {
            return .success(())
        }
        let codes = results.map { String($0.exitStatus) }.joined(separator: ", ")
        let stderr = results.map(\.stderr).first { !$0.isEmpty } ?? ""
        let detail = stderr.isEmpty ? "" : ": \(SystemStateParser.head(stderr))"
        return .failure(SettingsFailure("launchctl exit \(codes)\(detail)"))
    }

    private static func failure(_ error: Error) -> SettingsFailure {
        (error as? SettingsFailure) ?? SettingsFailure(String(describing: error))
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
