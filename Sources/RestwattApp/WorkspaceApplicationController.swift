import AppKit
import RestwattCore

/// Starts and quits other applications through LaunchServices: no child process, no Apple
/// Event script. `launchHidden` is the equivalent of `open -g -j`; `requestQuit` is the
/// quit request the running application receives from the Dock or the Finder.
///
/// The coordinator calls these only from main-actor code; `assumeIsolated` states that
/// without pinning the core protocol to an actor.
struct WorkspaceApplicationController: ApplicationControlling {
    func isRunning(bundleIdentifier: String) -> Bool {
        MainActor.assumeIsolated {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
    }

    func launchHidden(bundleIdentifier: String) throws {
        try MainActor.assumeIsolated {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw SettingsFailure("\(bundleIdentifier) is not installed")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            // The launch completes asynchronously; the menu reads the running state when it
            // opens next, so a refused launch shows as not running there.
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }

    func requestQuit(bundleIdentifier: String) throws {
        try MainActor.assumeIsolated {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            guard !running.isEmpty else {
                throw SettingsFailure("\(bundleIdentifier) is not running")
            }
            for application in running where !application.terminate() {
                throw SettingsFailure("\(bundleIdentifier) did not accept the quit request")
            }
        }
    }
}
