import AppKit
import IOKit.ps
import RestwattCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var monitor: BatteryMonitor?
    private var settings: SettingsCoordinator?
    private var timer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = BatteryMonitor(
            battery: IOKitBatteryReader(),
            processes: LibprocProcessReader(),
            clock: SystemClock()
        )
        self.monitor = monitor

        // Settings: re-acquire the remembered assertions and close the crash gap of the
        // lid-closed setting before the menu can show anything.
        let settings = SettingsCoordinator(
            store: FileSettingsStore(),
            assertions: IOKitPowerAssertions(),
            commands: ProcessCommandRunner(),
            applications: WorkspaceApplicationController(),
            uid: getuid()
        )
        settings.applyStoredAtLaunch()
        self.settings = settings
        statusItem = StatusItemController(settings: settings)

        // One slow timer on the main run loop; target/selector keeps the callback on the
        // main actor without a Sendable closure.
        let timer = Timer(
            timeInterval: Sampling.interval,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = Sampling.interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        installPowerSourceNotification()
        sample()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // First: take back the lid-closed pmset profile if Restwatt set it. The assertions
        // need nothing, the process ending releases them.
        settings?.willTerminate()
        timer?.invalidate()
        statusItem?.stopObservingPointer()
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    @objc private func timerFired() {
        sample()
    }

    /// Re-sample right away when the power source changes (plug or unplug), instead of
    /// waiting for the next timer fire.
    private func installPowerSourceNotification() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else {
                return
            }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                delegate.sample()
            }
        }, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func sample() {
        guard let monitor, let statusItem else {
            return
        }
        statusItem.show(monitor.tick())
    }
}

struct SystemClock: ClockReading {
    var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
