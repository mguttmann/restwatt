import Foundation
import RestwattCore
import ServiceManagement

/// The app itself as a login item through `SMAppService.mainApp`. macOS registers the bundle
/// at the path it runs from, so the app should live in /Applications before it is enabled.
struct ServiceManagementLoginItem: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            // A status this build does not know is not shown as enabled.
            return .notFound
        }
    }

    func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw SettingsFailure(error.localizedDescription)
        }
    }

    func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw SettingsFailure(error.localizedDescription)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
