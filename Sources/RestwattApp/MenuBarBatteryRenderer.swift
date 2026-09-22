import AppKit
import RestwattCore

/// Draws the battery-shaped menu bar image: the outline with its nub, the fill for the charge
/// percent and the menu bar text inside, all in colours resolved for the appearance the
/// status bar button has right now. Not a template image: a template would be tinted as a
/// whole and could not carry a second colour for the fill, so the colours are baked in here
/// and the image is drawn again whenever the appearance or the model changes.
@MainActor
enum MenuBarBatteryRenderer {
    static let font = NSFont.menuBarFont(ofSize: 0)

    static func image(text: String, percent: Int, tint: BatteryGlyph.Tint, appearance: NSAppearance) -> NSImage {
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let layout = BatteryGlyph.layout(
            textSize: BatteryGlyph.Size(width: ceil(measured.width), height: ceil(measured.height)),
            percent: percent)

        // Dynamic colours are resolved once, for the button's appearance, into concrete
        // colours: the drawing handler may run later and elsewhere, and a non-template image
        // keeps whatever it was drawn with.
        var labelColour = NSColor.labelColor
        var fillColour = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            labelColour = resolved(.labelColor)
            fillColour = resolved(systemColour(for: tint)).withAlphaComponent(CGFloat(BatteryGlyph.fillOpacity))
        }
        let font = self.font
        let image = NSImage(size: NSSize(width: layout.imageSize.width, height: layout.imageSize.height),
                            flipped: false) { _ in
            let body = rect(layout.body)
            let radius = CGFloat(BatteryGlyph.cornerRadius)

            NSGraphicsContext.saveGraphicsState()
            let inner = body.insetBy(dx: CGFloat(BatteryGlyph.strokeWidth), dy: CGFloat(BatteryGlyph.strokeWidth))
            let innerRadius = max(radius - CGFloat(BatteryGlyph.strokeWidth), 0)
            NSBezierPath(roundedRect: inner, xRadius: innerRadius, yRadius: innerRadius).addClip()
            fillColour.setFill()
            rect(layout.fill).fill()
            NSGraphicsContext.restoreGraphicsState()

            labelColour.setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            outline.lineWidth = CGFloat(BatteryGlyph.strokeWidth)
            outline.stroke()

            labelColour.setFill()
            let nub = rect(layout.nub)
            NSBezierPath(roundedRect: nub, xRadius: nub.width / 2, yRadius: nub.width / 2).fill()

            (text as NSString).draw(
                at: NSPoint(x: layout.textOrigin.x, y: layout.textOrigin.y),
                withAttributes: [.font: font, .foregroundColor: labelColour])
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = text
        return image
    }

    private static func systemColour(for tint: BatteryGlyph.Tint) -> NSColor {
        switch tint {
        case .label: return .labelColor
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }

    /// The colour as concrete sRGB components under the current drawing appearance.
    private static func resolved(_ colour: NSColor) -> NSColor {
        colour.usingColorSpace(.sRGB) ?? colour
    }

    private static func rect(_ rect: BatteryGlyph.Rect) -> NSRect {
        NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

/// A zero-sized subview of the status bar button whose only job is to report when the
/// button's effective appearance changes (light or dark menu bar), so the image can be drawn
/// again in the new colours. It takes no clicks.
final class AppearanceObservingView: NSView {
    var onChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
