import XCTest
@testable import RestwattCore

/// Geometry and fill colour of the battery-shaped menu bar item (ticket 11, spec section 7.1).
final class BatteryGlyphTests: XCTestCase {
    private let text = BatteryGlyph.Size(width: 60, height: 16)

    private func fillWidth(_ percent: Int) -> Double {
        BatteryGlyph.layout(textSize: text, percent: percent).fill.width
    }

    private var innerWidth: Double {
        BatteryGlyph.layout(textSize: text, percent: 100).body.width - 2 * BatteryGlyph.strokeWidth
    }

    func testFillWidthFollowsThePercent() {
        XCTAssertEqual(fillWidth(0), 0)
        XCTAssertEqual(fillWidth(20), innerWidth * 0.2, accuracy: 1e-9)
        XCTAssertEqual(fillWidth(50), innerWidth * 0.5, accuracy: 1e-9)
        XCTAssertEqual(fillWidth(100), innerWidth, accuracy: 1e-9)
    }

    func testOutOfRangePercentClamps() {
        XCTAssertEqual(fillWidth(-5), 0)
        XCTAssertEqual(fillWidth(150), innerWidth, accuracy: 1e-9)
        XCTAssertEqual(BatteryGlyph.clampedPercent(-5), 0)
        XCTAssertEqual(BatteryGlyph.clampedPercent(150), 100)
        XCTAssertEqual(BatteryGlyph.clampedPercent(42), 42)
    }

    func testFillStartsAtTheLeftInnerEdgeAndStaysInsideTheOutline() {
        let layout = BatteryGlyph.layout(textSize: text, percent: 100)
        let stroke = BatteryGlyph.strokeWidth
        XCTAssertEqual(layout.fill.x, layout.body.x + stroke)
        XCTAssertEqual(layout.fill.y, layout.body.y + stroke)
        XCTAssertEqual(layout.fill.maxX, layout.body.maxX - stroke, accuracy: 1e-9)
        XCTAssertEqual(layout.fill.maxY, layout.body.maxY - stroke, accuracy: 1e-9)
        XCTAssertEqual(BatteryGlyph.layout(textSize: text, percent: 30).fill.x, layout.fill.x, "the fill grows from the left")
    }

    func testBodyWrapsTheTextWithTheInsets() {
        let layout = BatteryGlyph.layout(textSize: text, percent: 50)
        XCTAssertEqual(layout.body.width, text.width + 2 * BatteryGlyph.textInsetX + 2 * BatteryGlyph.strokeWidth)
        XCTAssertEqual(layout.body.height, text.height + 2 * BatteryGlyph.textInsetY)
        XCTAssertEqual(layout.textOrigin.x, layout.body.x + BatteryGlyph.strokeWidth + BatteryGlyph.textInsetX)
        XCTAssertEqual(layout.textOrigin.y, layout.body.y + BatteryGlyph.textInsetY)
        XCTAssertEqual(layout.body.x, BatteryGlyph.strokeWidth, "room for the stroke on the left")
        XCTAssertEqual(layout.body.y, BatteryGlyph.strokeWidth, "room for the stroke at the bottom")
    }

    func testNubSitsRightOfTheBodyVerticallyCentred() {
        let layout = BatteryGlyph.layout(textSize: text, percent: 50)
        XCTAssertEqual(layout.nub.x, layout.body.maxX + BatteryGlyph.nubGap)
        XCTAssertEqual(layout.nub.width, BatteryGlyph.nubWidth)
        XCTAssertEqual(layout.nub.height, layout.body.height * BatteryGlyph.nubHeightRatio, accuracy: 1e-9)
        let bodyCentre = layout.body.y + layout.body.height / 2
        XCTAssertEqual(layout.nub.y + layout.nub.height / 2, bodyCentre, accuracy: 1e-9)
    }

    func testImageSizeCoversBodyStrokeAndNub() {
        let layout = BatteryGlyph.layout(textSize: text, percent: 50)
        XCTAssertEqual(layout.imageSize.width, layout.nub.maxX)
        XCTAssertEqual(layout.imageSize.width,
                       BatteryGlyph.strokeWidth + layout.body.width + BatteryGlyph.nubGap + BatteryGlyph.nubWidth,
                       "stroke margin on the left, the nub gap keeps the right stroke inside")
        XCTAssertEqual(layout.imageSize.height, layout.body.height + 2 * BatteryGlyph.strokeWidth)
        XCTAssertEqual(layout.imageSize.height, 20, "16 pt of text, one inset and one stroke on each side")
    }

    /// The menu bar is 22 pt thick; a tall font must not push the image beyond it.
    func testImageHeightIsCappedByTheMenuBarThickness() {
        let layout = BatteryGlyph.layout(textSize: BatteryGlyph.Size(width: 60, height: 40), percent: 50)
        XCTAssertEqual(layout.body.height, BatteryGlyph.maxBodyHeight)
        XCTAssertLessThanOrEqual(layout.imageSize.height, 22)
        XCTAssertGreaterThanOrEqual(layout.textOrigin.y, layout.body.y, "the text box starts inside the body")
    }

    func testWiderTextMakesAWiderImageOfTheSameHeight() {
        let narrow = BatteryGlyph.layout(textSize: text, percent: 50)
        let wide = BatteryGlyph.layout(textSize: BatteryGlyph.Size(width: 120, height: 16), percent: 50)
        XCTAssertEqual(wide.imageSize.width - narrow.imageSize.width, 60)
        XCTAssertEqual(wide.imageSize.height, narrow.imageSize.height)
        XCTAssertEqual(wide.fill.width, narrow.fill.width + 30, accuracy: 1e-9, "half of the extra inner width")
    }

    func testConstantsThatTheDocsAndTheDrawingRelyOn() {
        XCTAssertGreaterThan(BatteryGlyph.fillOpacity, 0)
        XCTAssertLessThan(BatteryGlyph.fillOpacity, 1)
        XCTAssertEqual(BatteryGlyph.lowChargeThresholdPercent, 20)
        XCTAssertGreaterThan(BatteryGlyph.cornerRadius, BatteryGlyph.strokeWidth)
    }

    // MARK: Fill colour

    private func tint(_ state: PowerState, _ percent: Int, lowPower: Bool = false) -> BatteryGlyph.Tint {
        BatteryGlyph.tint(state: state, percent: percent, lowPowerModeEnabled: lowPower)
    }

    func testLowChargeWhileDrainingIsRedAndBeatsLowPowerMode() {
        XCTAssertEqual(tint(.discharging, 20), .red)
        XCTAssertEqual(tint(.discharging, 20, lowPower: true), .red)
        XCTAssertEqual(tint(.discharging, 5), .red)
        XCTAssertEqual(tint(.drainingOnExternalPower, 10), .red)
        XCTAssertEqual(tint(.discharging, 21), .label, "just above the threshold")
    }

    func testChargingAndFullOnACAreGreenWhateverTheChargeOrMode() {
        XCTAssertEqual(tint(.charging, 5), .green, "energy goes in, the low charge is not a warning")
        XCTAssertEqual(tint(.charging, 100, lowPower: true), .green)
        XCTAssertEqual(tint(.onExternalPower(fullyCharged: true), 100), .green)
        XCTAssertEqual(tint(.onExternalPower(fullyCharged: true), 100, lowPower: true), .green)
    }

    func testLowPowerModeIsYellowInTheNeutralStates() {
        XCTAssertEqual(tint(.discharging, 21, lowPower: true), .yellow)
        XCTAssertEqual(tint(.discharging, 100, lowPower: true), .yellow)
        XCTAssertEqual(tint(.onExternalPower(fullyCharged: false), 50, lowPower: true), .yellow)
        XCTAssertEqual(tint(.powerSourceChanging, 50, lowPower: true), .yellow)
    }

    func testEverythingElseIsTheLabelColour() {
        XCTAssertEqual(tint(.discharging, 100), .label)
        XCTAssertEqual(tint(.onExternalPower(fullyCharged: false), 50), .label)
        XCTAssertEqual(tint(.powerSourceChanging, 5), .label, "direction unknown, so never red")
        XCTAssertEqual(tint(.powerSourceChanging, 100), .label)
    }
}
