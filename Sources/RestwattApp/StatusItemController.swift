import AppKit
import RestwattCore

/// Owns the NSStatusItem: title, hover tooltip and the click menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
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
        statusItem.button?.toolTip = "Restwatt is starting"
    }

    func show(_ model: DisplayModel) {
        latestModel = model
        statusItem.button?.title = Formatting.menuBarTitle(model)
        statusItem.button?.toolTip = Formatting.tooltipText(model)
    }

    /// The menu is rebuilt from the latest model each time it opens.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in Formatting.menuLines(latestModel, version: version) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Restwatt", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
