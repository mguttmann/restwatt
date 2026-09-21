import AppKit

// Bootstrap. `.accessory` keeps the app out of the Dock even when the bare SwiftPM binary is
// launched without an Info.plist; inside the bundle `LSUIElement` does the same.
let app = NSApplication.shared
_ = app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
