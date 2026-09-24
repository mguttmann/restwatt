import AppKit
import RestwattCore

/// The hover popover: a two-column grid of the detail rows, rebuilt from the latest model.
///
/// It replaces the native tooltip, which does not show over the menu bar on every macOS
/// version. Everything is in `NSColor.labelColor` so the text follows the light or dark
/// menu bar and is never rendered in the disabled grey.
@MainActor
final class DetailPopover {
    private let popover = NSPopover()
    private let contentView = HoverReportingView()
    private let viewController = NSViewController()
    private var grid: NSGridView?

    /// Called when the pointer enters or leaves the popover content.
    var onMouseEntered: (() -> Void)? {
        get { contentView.onMouseEntered }
        set { contentView.onMouseEntered = newValue }
    }

    var onMouseExited: (() -> Void)? {
        get { contentView.onMouseExited }
        set { contentView.onMouseExited = newValue }
    }

    var isShown: Bool {
        popover.isShown
    }

    init() {
        viewController.view = contentView
        popover.contentViewController = viewController
        // Closes on any click outside; the app is never activated to show it.
        popover.behavior = .transient
        popover.animates = false
    }

    /// Shows the popover below `view`, or leaves it where it is if already visible.
    func show(_ model: DisplayModel, relativeTo view: NSView) {
        render(model)
        if !popover.isShown {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    /// Re-renders the rows while visible; a no-op when hidden.
    func update(_ model: DisplayModel) {
        if popover.isShown {
            render(model)
        }
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func render(_ model: DisplayModel) {
        grid?.removeFromSuperview()
        var rows = Formatting.detailRows(model)
        if case .battery(let status) = model {
            rows += Formatting.processRows(status.processReport, limit: 3)
            rows += Formatting.todayRows(status.today, limit: 3)
        }
        let grid = NSGridView(views: rows.map(Self.cells(for:)))
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 16
        grid.rowSpacing = 3
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        for (index, row) in rows.enumerated() where row.emphasis == .heading {
            let gridRow = grid.row(at: index)
            gridRow.mergeCells(in: NSRange(location: 0, length: 2))
            gridRow.topPadding = index == 0 ? 0 : 8
        }
        contentView.addSubview(grid)
        let inset: CGFloat = 14
        let topInset = inset - 2
        // The bottom may give: while the popover still has its old size, the extra height
        // stays below the last row instead of being spread into a gap under a heading.
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: topInset),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -inset),
        ])
        self.grid = grid
        // The size comes from the grid alone. The content view's own fitting size never drops
        // below its current frame once it is in the popover, so a model with fewer rows would
        // never shrink the popover.
        let fitting = grid.fittingSize
        viewController.preferredContentSize = NSSize(
            width: fitting.width + 2 * inset, height: fitting.height + topInset + inset)
    }

    private static func cells(for row: DetailRow) -> [NSView] {
        let label = NSTextField(labelWithString: row.label)
        let value = NSTextField(labelWithString: row.value)
        label.textColor = .labelColor
        value.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        switch row.emphasis {
        case .primary:
            label.font = .systemFont(ofSize: 15, weight: .medium)
            value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        case .secondary:
            label.font = .systemFont(ofSize: 13)
            value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        case .heading:
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            value.font = .systemFont(ofSize: 12)
        }
        return [label, value]
    }
}

/// Reports pointer enter and exit so the controller can keep the popover open while the
/// pointer rests on it, without a timer running in between.
final class HoverReportingView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}
