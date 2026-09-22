import Foundation

/// Geometry and fill colour of the battery-shaped menu bar item. Pure: the app measures the
/// text with its font and draws the result; nothing here knows AppKit or pixels.
///
/// Coordinates are unflipped (origin bottom left, like AppKit's default image space). The
/// body is the rounded outline; its stroke is centred on the rect's edge. The fill sits
/// inside the stroke and grows from the left inner edge with the charge percent. The nub
/// is the small terminal on the right, vertically centred.
public enum BatteryGlyph {
    public static let strokeWidth: Double = 1
    /// Horizontal gap between the inner edge of the outline and the text.
    public static let textInsetX: Double = 5
    /// Vertical gap between the text box and the outline.
    public static let textInsetY: Double = 1
    public static let nubWidth: Double = 2
    /// Gap between the body's right edge and the nub.
    public static let nubGap: Double = 1
    /// Nub height as a fraction of the body height.
    public static let nubHeightRatio: Double = 0.4
    public static let cornerRadius: Double = 4
    /// The body never grows taller than this; the menu bar is 22 pt thick and the image adds
    /// one stroke width on each side.
    public static let maxBodyHeight: Double = 20
    /// Opacity of the fill, so the text drawn over it stays readable.
    public static let fillOpacity: Double = 0.35
    /// At or below this charge the fill turns red while the battery drains.
    public static let lowChargeThresholdPercent = 20

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    public struct Layout: Equatable, Sendable {
        public var imageSize: Size
        /// The outline; the stroke is centred on its edge.
        public var body: Rect
        public var nub: Rect
        /// Inside the outline; its width follows the percent.
        public var fill: Rect
        /// Bottom left corner of the text box.
        public var textOrigin: Point
    }

    /// Clamps to 0...100; the gauge never reports more, but a clamp costs nothing.
    public static func clampedPercent(_ percent: Int) -> Int {
        min(max(percent, 0), 100)
    }

    /// `textSize` is the measured size of the text in the menu bar font.
    public static func layout(textSize: Size, percent: Int) -> Layout {
        let bodyHeight = min(textSize.height + 2 * textInsetY, maxBodyHeight)
        let body = Rect(x: strokeWidth, y: strokeWidth,
                        width: textSize.width + 2 * textInsetX + 2 * strokeWidth,
                        height: bodyHeight)
        let inner = Rect(x: body.x + strokeWidth, y: body.y + strokeWidth,
                         width: body.width - 2 * strokeWidth, height: body.height - 2 * strokeWidth)
        let fill = Rect(x: inner.x, y: inner.y,
                        width: inner.width * Double(clampedPercent(percent)) / 100,
                        height: inner.height)
        let nubHeight = body.height * nubHeightRatio
        let nub = Rect(x: body.maxX + nubGap, y: body.y + (body.height - nubHeight) / 2,
                       width: nubWidth, height: nubHeight)
        let textHeight = min(textSize.height, body.height - 2 * textInsetY)
        let textOrigin = Point(x: inner.x + textInsetX, y: body.y + (body.height - textHeight) / 2)
        return Layout(
            imageSize: Size(width: nub.maxX, height: body.height + 2 * strokeWidth),
            body: body, nub: nub, fill: fill, textOrigin: textOrigin)
    }

    /// The fill colour, named; the app maps it to the system colours of the current appearance.
    public enum Tint: Equatable, Sendable {
        /// The label colour of the current appearance: the normal state.
        case label
        case green
        case yellow
        case red
    }

    /// The convention users know from Apple's own item: red is the safety signal and wins,
    /// green means energy is going in (or the battery is full on external power), yellow
    /// means Low Power Mode is in effect, everything else takes the label colour.
    /// `lowPowerModeEnabled` is the effective system state, not the mode set in the menu.
    public static func tint(state: PowerState, percent: Int, lowPowerModeEnabled: Bool) -> Tint {
        if state.isDraining, percent <= lowChargeThresholdPercent {
            return .red
        }
        if state == .charging || state == .onExternalPower(fullyCharged: true) {
            return .green
        }
        if lowPowerModeEnabled {
            return .yellow
        }
        return .label
    }
}
