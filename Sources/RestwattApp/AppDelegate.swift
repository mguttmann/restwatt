import AppKit
import IOKit.ps
import RestwattCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var monitor: BatteryMonitor?
    private var settings: SettingsCoordinator?
    private var timer: Timer?
    private var secondSampleTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = BatteryMonitor(
            battery: IOKitBatteryReader(),
            processes: LibprocProcessReader(),
            clock: SystemClock(),
            memory: EnergyMemory(store: FileStatisticsStore(), wallClock: SystemWallClock(), calendar: .current)
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
        statusItem = StatusItemController(
            settings: settings, loginItem: LoginItemCoordinator(loginItem: ServiceManagementLoginItem()))

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

        // One early second tick, so the process list (which needs two readings) shows up
        // within seconds instead of after a full interval. Fires once, then the timer above
        // sets the pace. Same run-loop mode as the main timer, so an open menu in the first
        // seconds does not hold it back.
        let secondSampleTimer = Timer(
            timeInterval: Sampling.secondSampleDelay,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(secondSampleTimer, forMode: .common)
        self.secondSampleTimer = secondSampleTimer
    }

    func applicationWillTerminate(_ notification: Notification) {
        // First: take back the lid-closed pmset profile if Restwatt set it. The assertions
        // need nothing, the process ending releases them. Then write the statistics one last
        // time.
        settings?.willTerminate()
        monitor?.willTerminate()
        timer?.invalidate()
        secondSampleTimer?.invalidate()
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

/// Wall clock plus the kernel's boot time (`kern.boottime`), which unlike
/// `Date() - systemUptime` does not drift with every sleep.
struct SystemWallClock: WallClockReading {
    var now: Date {
        Date()
    }

    var bootTime: Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}
