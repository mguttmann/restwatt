import AppKit

/// The view behind a display-only row of the click menu.
///
/// AppKit highlights every enabled menu item on hover and closes the menu when one is
/// clicked, whether or not it has an action. A view-backed item draws itself instead: it never
/// highlights, and because the item is disabled the menu neither selects it on click nor stops
/// on it during keyboard navigation. The text keeps the normal label colour, which a disabled
/// text-only item would lose to the disabled grey.
///
/// The frame is the row's intrinsic size; NSMenu widens every view to the widest item, so the
/// menu is never narrower than the longest row.
final class MenuRowView: NSView {
    /// Horizontal distance from the menu edge to the text of an unindented row; matches the
    /// text start of the ordinary items in the same menu.
    static let baseInset: CGFloat = 21
    /// Added per `indentationLevel`, the same step NSMenuItem uses.
    static let indentStep: CGFloat = 12
    static let trailingInset: CGFloat = 14
    static let verticalPadding: CGFloat = 3

    init(text: NSAttributedString, indentationLevel: Int) {
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        let inset = Self.baseInset + Self.indentStep * CGFloat(indentationLevel)
        let size = label.fittingSize
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: inset + size.width + Self.trailingInset,
            height: size.height + 2 * Self.verticalPadding))
        autoresizingMask = [.width]
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MenuRowView is created in code only")
    }

    /// Wraps `text` in a disabled, view-backed item that shows it without reacting to the mouse.
    static func menuItem(text: NSAttributedString, indentationLevel: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: text.string, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = MenuRowView(text: text, indentationLevel: indentationLevel)
        return item
    }

    // Swallow clicks so they neither reach the menu nor close it.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}
