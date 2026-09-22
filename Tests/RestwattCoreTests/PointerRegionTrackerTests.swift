import XCTest
@testable import RestwattCore

/// Pins the enter/leave logic that drives the hover popover from global pointer positions.
final class PointerRegionTrackerTests: XCTestCase {
    // A menu bar item frame as measured on a 1080 px high screen (AppKit origin bottom-left).
    private let item = PointerRegionTracker.Region(x: 1043, y: 949, width: 87, height: 33)

    func testReportsEachTransitionExactlyOnce() {
        var tracker = PointerRegionTracker()
        XCTAssertNil(tracker.update(pointerX: 500, pointerY: 400, region: item))
        XCTAssertNil(tracker.update(pointerX: 600, pointerY: 400, region: item))
        XCTAssertEqual(tracker.update(pointerX: 1050, pointerY: 960, region: item), .entered)
        XCTAssertNil(tracker.update(pointerX: 1100, pointerY: 970, region: item))
        XCTAssertTrue(tracker.isInside)
        XCTAssertEqual(tracker.update(pointerX: 1100, pointerY: 900, region: item), .left)
        XCTAssertNil(tracker.update(pointerX: 1100, pointerY: 800, region: item))
        XCTAssertFalse(tracker.isInside)
    }

    func testPointerBesideTheItemInTheMenuBarIsOutside() {
        var tracker = PointerRegionTracker()
        XCTAssertNil(tracker.update(pointerX: 1042, pointerY: 960, region: item))
        XCTAssertNil(tracker.update(pointerX: 1130, pointerY: 960, region: item))
        XCTAssertEqual(tracker.update(pointerX: 1043, pointerY: 949, region: item), .entered)
    }

    func testFrameIsReadPerEventSoAReflowedItemStillMatches() {
        var tracker = PointerRegionTracker()
        let moved = PointerRegionTracker.Region(x: 1039, y: 949, width: 91, height: 33)
        XCTAssertNil(tracker.update(pointerX: 1040, pointerY: 960, region: item))
        XCTAssertEqual(tracker.update(pointerX: 1040, pointerY: 960, region: moved), .entered)
        // The item shrank away from under the resting pointer: that counts as leaving.
        XCTAssertEqual(tracker.update(pointerX: 1040, pointerY: 960, region: item), .left)
    }

    func testEmptyLaunchFrameNeverContainsThePointer() {
        var tracker = PointerRegionTracker()
        let launch = PointerRegionTracker.Region(x: 0, y: 0, width: 74, height: 0)
        XCTAssertNil(tracker.update(pointerX: 0, pointerY: 0, region: launch))
        XCTAssertNil(tracker.update(pointerX: 10, pointerY: 0, region: launch))
        XCTAssertFalse(tracker.isInside)
    }
}
