import AppKit
import RestwattCore

/// Owns the NSStatusItem: title, hover popover and the click menu.
///
/// Hover path: the menu bar item is hosted by the system, so the app owns no on-screen window
/// for it and an `NSTrackingArea` on the button never fires. Instead a global mouse-moved
/// monitor hit-tests the pointer position against the button window's current frame (read on
/// every event, it is empty at launch and moves when the menu bar reflows) and reports only
/// enter/leave transitions. Entering arms one short timer; when it fires the popover is shown
/// from the latest model. Leaving arms a short hide timer, which the popover's own tracking
/// area cancels if the pointer moved onto the popover. No timer exists while the pointer is
/// neither arriving nor leaving. The monitor looks at pointer position only and stores nothing.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Seconds between the pointer entering the item and the popover appearing.
    static let showDelay: TimeInterval = 0.35
    /// Seconds the pointer may be off both button and popover before the popover hides.
    static let hideDelay: TimeInterval = 0.3

    private let statusItem: NSStatusItem
    private let settings: SettingsCoordinator
    private let menu = NSMenu()
    private let popover = DetailPopover()
    private var hoverTimer: Timer?
    private var pointerMonitor: Any?
    private var pointerTracker = PointerRegionTracker()
    /// True between menuWillOpen and menuDidClose; no popover is armed or shown meanwhile.
    private var menuIsOpen = false
    private var latestModel: DisplayModel = .unavailable(reason: "Starting")

    private let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }()

    init(settings: SettingsCoordinator) {
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.title = "Restwatt"
        installPointerMonitor()
    }

    /// Removes the global pointer monitor; called from applicationWillTerminate.
    func stopObservingPointer() {
        cancelHoverTimer()
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
    }

    func show(_ model: DisplayModel) {
        latestModel = model
        statusItem.button?.title = Formatting.menuBarTitle(model)
        popover.update(model)
    }

    // MARK: Hover popover

    private func installPointerMonitor() {
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.pointerMoved(event)
            }
        }
        popover.onMouseEntered = { [weak self] in
            self?.cancelHoverTimer()
        }
        popover.onMouseExited = { [weak self] in
            self?.scheduleHide()
        }
    }

    /// Global monitor callback: hit-tests the pointer against the item's current frame and
    /// forwards only enter/leave transitions.
    private func pointerMoved(_ event: NSEvent) {
        guard let frame = statusItem.button?.window?.frame else {
            return
        }
        let location = NSEvent.mouseLocation
        let region = PointerRegionTracker.Region(
            x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        switch pointerTracker.update(pointerX: location.x, pointerY: location.y, region: region) {
        case .entered:
            mouseEntered(with: event)
        case .left:
            mouseExited(with: event)
        case nil:
            break
        }
    }

    /// The pointer entered the status item.
    func mouseEntered(with event: NSEvent) {
        cancelHoverTimer()
        if popover.isShown || menuIsOpen {
            return
        }
        hoverTimer = Timer.scheduledTimer(
            timeInterval: Self.showDelay,
            target: self,
            selector: #selector(showPopover),
            userInfo: nil,
            repeats: false)
    }

    /// The pointer left the status item.
    func mouseExited(with event: NSEvent) {
        scheduleHide()
    }

    @objc private func showPopover() {
        hoverTimer = nil
        guard !menuIsOpen, let button = statusItem.button else {
            return
        }
        popover.show(latestModel, relativeTo: button)
    }

    @objc private func hidePopover() {
        hoverTimer = nil
        popover.close()
    }

    private func scheduleHide() {
        cancelHoverTimer()
        guard popover.isShown else {
            return
        }
        hoverTimer = Timer.scheduledTimer(
            timeInterval: Self.hideDelay,
            target: self,
            selector: #selector(hidePopover),
            userInfo: nil,
            repeats: false)
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    // MARK: Click menu

    /// The menu is rebuilt from the latest model each time it opens. Information rows are
    /// display-only view-backed items (`MenuRowView`): drawn in the normal label colour, they
    /// neither highlight nor react to a click, and keyboard navigation skips them. Only the
    /// toggles and Quit are ordinary menu items. The settings section is rendered from the
    /// system state read right now, so its checkmarks never show a stale or intended state.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        cancelHoverTimer()
        popover.close()
        menu.removeAllItems()
        for row in Formatting.detailRows(latestModel) {
            menu.addItem(Self.menuItem(for: row))
        }
        if case .battery(let status) = latestModel {
            menu.addItem(.separator())
            for row in Formatting.processRows(status.processReport, limit: 5)
                + Formatting.todayRows(status.today, limit: 5) {
                menu.addItem(Self.menuItem(for: row, indentationLevel: row.emphasis == .heading ? 0 : 1))
            }
        }
        menu.addItem(.separator())
        settings.refreshObserved()
        for row in Formatting.settingsRows(settings.snapshot) {
            menu.addItem(menuItem(for: row))
        }
        menu.addItem(.separator())
        menu.addItem(Self.menuItem(for: DetailRow("Restwatt \(version)")))
        let quit = NSMenuItem(title: "Quit Restwatt", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private static func menuItem(for row: DetailRow, indentationLevel: Int = 0) -> NSMenuItem {
        let size = NSFont.systemFontSize
        let title = NSMutableAttributedString(
            string: row.label,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: row.emphasis == .primary ? .semibold : .regular)])
        if !row.value.isEmpty {
            title.append(NSAttributedString(string: "  "))
            title.append(NSAttributedString(
                string: row.value,
                attributes: [.font: NSFont.monospacedDigitSystemFont(
                    ofSize: size, weight: row.emphasis == .primary ? .semibold : .regular)]))
        }
        return MenuRowView.menuItem(text: title, indentationLevel: indentationLevel)
    }

    /// A settings row: toggles carry the key in `representedObject` and a checkmark state;
    /// headings, notes and warnings are display-only rows like the process list entries.
    private func menuItem(for row: SettingsRow) -> NSMenuItem {
        let size = NSFont.systemFontSize
        switch row.kind {
        case .heading:
            return MenuRowView.menuItem(text: NSAttributedString(
                string: row.label, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .regular)]))
        case .toggle(let key, let isOn):
            let item = NSMenuItem(title: row.label, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SettingKeyBox(key)
            item.state = isOn ? .on : .off
            item.indentationLevel = 1
            if !row.detail.isEmpty {
                let title = NSMutableAttributedString(
                    string: row.label, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .regular)])
                title.append(NSAttributedString(string: "  "))
                title.append(NSAttributedString(
                    string: row.detail,
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = title
            }
            return item
        case .note, .warning:
            let colour: NSColor = row.kind == .warning ? .systemOrange : .secondaryLabelColor
            let text = NSAttributedString(
                string: row.label,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
                             .foregroundColor: colour])
            return MenuRowView.menuItem(text: text, indentationLevel: 2)
        }
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SettingKeyBox else {
            return
        }
        settings.toggle(box.key)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// `representedObject` needs a class; the key itself is a value type in the core.
private final class SettingKeyBox: NSObject {
    let key: SettingKey

    init(_ key: SettingKey) {
        self.key = key
    }
}
