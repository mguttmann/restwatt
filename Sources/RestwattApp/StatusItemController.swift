import AppKit
import RestwattCore

/// Owns the NSStatusItem: title, hover popover and the click menu.
///
/// Hover path: an `NSTrackingArea` on the status item button reports the pointer entering
/// and leaving. Entering arms one short timer; when it fires the popover is shown from the
/// latest model. Leaving the button arms a short hide timer, which the popover's own
/// tracking area cancels if the pointer moved onto the popover. No timer exists while the
/// pointer is neither arriving nor leaving.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Seconds between the pointer entering the item and the popover appearing.
    static let showDelay: TimeInterval = 0.35
    /// Seconds the pointer may be off both button and popover before the popover hides.
    static let hideDelay: TimeInterval = 0.3

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let popover = DetailPopover()
    private var hoverTimer: Timer?
    private var latestModel: DisplayModel = .unavailable(reason: "Starting")

    private let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.title = "Restwatt"
        installHoverTracking()
    }

    func show(_ model: DisplayModel) {
        latestModel = model
        statusItem.button?.title = Formatting.menuBarTitle(model)
        popover.update(model)
    }

    // MARK: Hover popover

    private func installHoverTracking() {
        guard let button = statusItem.button else {
            return
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        button.addTrackingArea(area)
        popover.onMouseEntered = { [weak self] in
            self?.cancelHoverTimer()
        }
        popover.onMouseExited = { [weak self] in
            self?.scheduleHide()
        }
    }

    /// `NSTrackingArea` owner callback: the pointer entered the status item button.
    @objc func mouseEntered(with event: NSEvent) {
        cancelHoverTimer()
        if popover.isShown || menu.highlightedItem != nil {
            return
        }
        hoverTimer = Timer.scheduledTimer(
            timeInterval: Self.showDelay,
            target: self,
            selector: #selector(showPopover),
            userInfo: nil,
            repeats: false)
    }

    /// `NSTrackingArea` owner callback: the pointer left the status item button.
    @objc func mouseExited(with event: NSEvent) {
        scheduleHide()
    }

    @objc private func showPopover() {
        hoverTimer = nil
        guard let button = statusItem.button else {
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

    /// The menu is rebuilt from the latest model each time it opens. Information items stay
    /// enabled (no action, so selecting one only closes the menu) to be drawn in the normal
    /// label colour instead of the disabled grey.
    func menuWillOpen(_ menu: NSMenu) {
        cancelHoverTimer()
        popover.close()
        menu.removeAllItems()
        for row in Formatting.detailRows(latestModel) {
            menu.addItem(Self.menuItem(for: row))
        }
        if case .battery(let status) = latestModel {
            menu.addItem(.separator())
            for row in Formatting.processRows(status.processReport, limit: 5) {
                let item = Self.menuItem(for: row)
                item.indentationLevel = row.emphasis == .heading ? 0 : 1
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(Self.menuItem(for: DetailRow("Restwatt \(version)")))
        let quit = NSMenuItem(title: "Quit Restwatt", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private static func menuItem(for row: DetailRow) -> NSMenuItem {
        let item = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
        item.isEnabled = true
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
        item.attributedTitle = title
        return item
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
