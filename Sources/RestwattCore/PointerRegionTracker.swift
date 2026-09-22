import Foundation

/// Turns a stream of pointer positions into enter/leave transitions for one screen region.
///
/// The app feeds it every global mouse-moved event together with the current frame of the
/// menu bar item. The check is cheap on purpose: the vertical test runs first because almost
/// every pointer position is far below the menu bar, and a transition is reported only when
/// the inside flag actually flips, so the caller never sees repeated enters or leaves.
public struct PointerRegionTracker: Sendable {
    public enum Transition: Equatable, Sendable {
        case entered
        case left
    }

    /// A rectangle in screen coordinates. An empty rectangle contains no point.
    public struct Region: Equatable, Sendable {
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

        public func contains(x pointX: Double, y pointY: Double) -> Bool {
            guard height > 0, pointY >= y, pointY < y + height else {
                return false
            }
            return width > 0 && pointX >= x && pointX < x + width
        }
    }

    public private(set) var isInside = false

    public init() {}

    /// Records the pointer position and returns the transition it caused, if any.
    public mutating func update(pointerX: Double, pointerY: Double, region: Region) -> Transition? {
        let inside = region.contains(x: pointerX, y: pointerY)
        guard inside != isInside else {
            return nil
        }
        isInside = inside
        return inside ? .entered : .left
    }
}
