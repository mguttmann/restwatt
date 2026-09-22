import Foundation

/// The four states macOS reports for the app as a login item (`SMAppService.Status`).
public enum LoginItemStatus: Equatable, Sendable {
    /// Not registered: the app does not open at login.
    case notRegistered
    /// Registered and allowed: the app opens at login.
    case enabled
    /// Registered, but the user has to allow it in System Settings before it opens at login.
    case requiresApproval
    /// The system does not know the app as a login item.
    case notFound
}

/// What a click on the Open at Login item does, decided from the status read when the menu
/// opened.
public enum LoginItemAction: Equatable, Sendable {
    case register
    case unregister
    /// Registering again would not help; the user has to allow the item in System Settings.
    case openLoginItemsSettings
}

/// The app as a login item. Nothing about it is persisted: the system is asked every time.
public protocol LoginItemControlling {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings at Login Items.
    func openLoginItemsSettings()
}

extension LoginItemStatus {
    /// Checked only when the app will really open at login.
    public var isOn: Bool {
        self == .enabled
    }

    /// The action a click takes from this status.
    public var clickAction: LoginItemAction {
        switch self {
        case .enabled:
            return .unregister
        case .requiresApproval:
            return .openLoginItemsSettings
        case .notRegistered, .notFound:
            return .register
        }
    }
}

extension Formatting {
    /// Apple's wording in System Settings, Login Items & Extensions.
    public static let openAtLoginLabel = "Open at Login"
    /// Shown under the item while macOS waits for the user to allow it.
    public static let loginItemApprovalNote = "needs approval in System Settings, Login Items"

    /// The Open at Login group: the item, the approval note while one is needed, and the
    /// reason the last click failed.
    public static func loginItemRows(status: LoginItemStatus, lastError: String?) -> [SettingsRow] {
        var rows = [SettingsRow(.openAtLogin(isOn: status.isOn), openAtLoginLabel)]
        if status == .requiresApproval {
            rows.append(SettingsRow(.note, loginItemApprovalNote))
        }
        if let lastError {
            rows.append(SettingsRow(.warning, "could not change: \(lastError)"))
        }
        return rows
    }
}

/// Holds the status last read and the reason the last click failed. The checkmark always
/// shows the status read back from the system, never the intended one (fail-closed).
public final class LoginItemCoordinator {
    public private(set) var status: LoginItemStatus = .notRegistered
    public private(set) var lastError: String?
    /// The status read right after the failed click; the warning belongs to that state only.
    private var statusAtError: LoginItemStatus?

    private let loginItem: LoginItemControlling

    public init(loginItem: LoginItemControlling) {
        self.loginItem = loginItem
    }

    /// Re-reads the status; called when the menu opens. A warning from a failed click is
    /// dropped once the status has moved on (for example after the user approved or enabled
    /// Restwatt in System Settings), so it never sits under a state it does not describe.
    public func refresh() {
        status = loginItem.status
        if let statusAtError, statusAtError != status {
            lastError = nil
            self.statusAtError = nil
        }
    }

    /// The menu rows for the status read last.
    public var rows: [SettingsRow] {
        Formatting.loginItemRows(status: status, lastError: lastError)
    }

    /// A click: registers, unregisters or opens System Settings, then re-reads the status.
    public func click() {
        do {
            switch status.clickAction {
            case .register:
                try loginItem.register()
            case .unregister:
                try loginItem.unregister()
            case .openLoginItemsSettings:
                loginItem.openLoginItemsSettings()
            }
            lastError = nil
            statusAtError = nil
            refresh()
        } catch {
            lastError = ((error as? SettingsFailure) ?? SettingsFailure(String(describing: error))).reason
            status = loginItem.status
            statusAtError = status
        }
    }
}
