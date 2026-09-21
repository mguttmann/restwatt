import XCTest
@testable import RestwattCore

final class FormattingTests: XCTestCase {
    private let report = ProcessEnergyReport(
        entries: [
            ProcessEnergyEntry(name: "Discord Helper (Renderer)", watts: 0.416, cpuShare: 0.3, processCount: 2),
            ProcessEnergyEntry(name: "com.apple.WebKit.WebContent", watts: 0.0217, cpuShare: 0.13, processCount: 1),
            ProcessEnergyEntry(name: "Restwatt", watts: 0.01, cpuShare: 0.001, processCount: 1),
            ProcessEnergyEntry(name: "Terminal", watts: 0.005, cpuShare: 0.001, processCount: 1),
        ],
        visibleTotalWatts: 0.63, processCount: 105, unaccountedWatts: 6.508, isWarmingUp: false)

    private func discharging(estimate: Estimate?) -> DisplayModel {
        .battery(BatteryStatus(
            state: .discharging, percent: 95, remainingWattHours: 62.975, drawWatts: 7.138,
            estimate: estimate, systemTimeToEmptyMinutes: 466, avgTimeToFullMinutes: nil,
            processReport: report, sampledAt: 0))
    }

    private let estimate = Estimate(
        instantWatts: 7.138, smoothedWatts: 7.5, instantMinutes: 529, smoothedMinutes: 492,
        observedSeconds: 2520, sampleCount: 43, confidence: .high)

    private func charging(minutes: Int?) -> DisplayModel {
        .battery(BatteryStatus(
            state: .charging, percent: 95, remainingWattHours: 62.975, drawWatts: -25.18,
            estimate: nil, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: minutes,
            processReport: report, sampledAt: 0))
    }

    private func onAC(fullyCharged: Bool) -> DisplayModel {
        .battery(BatteryStatus(
            state: .onExternalPower(fullyCharged: fullyCharged), percent: 100, remainingWattHours: 70.2,
            drawWatts: 0, estimate: nil, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: nil,
            processReport: .warmingUp, sampledAt: 0))
    }

    private var allModels: [DisplayModel] {
        [
            discharging(estimate: estimate), discharging(estimate: nil),
            charging(minutes: 65), charging(minutes: nil),
            onAC(fullyCharged: true), onAC(fullyCharged: false),
            .unavailable(reason: "No battery found"),
        ]
    }

    func testMenuBarTitles() {
        XCTAssertEqual(Formatting.menuBarTitle(discharging(estimate: estimate)), "7.1 W  8:12")
        XCTAssertEqual(Formatting.menuBarTitle(discharging(estimate: nil)), "7.1 W  --:--")
        XCTAssertEqual(Formatting.menuBarTitle(charging(minutes: 65)), "Charging  1:05")
        XCTAssertEqual(Formatting.menuBarTitle(charging(minutes: nil)), "Charging")
        XCTAssertEqual(Formatting.menuBarTitle(onAC(fullyCharged: false)), "On AC")
        XCTAssertEqual(Formatting.menuBarTitle(onAC(fullyCharged: true)), "On AC  100 %")
        XCTAssertEqual(Formatting.menuBarTitle(.unavailable(reason: "No battery found")), "No battery")
    }

    func testTitleShowsSmoothedNotInstantTime() {
        XCTAssertEqual(Formatting.menuBarTitle(discharging(estimate: estimate)), "7.1 W  8:12")
        XCTAssertNotEqual(Formatting.durationString(minutes: estimate.instantMinutes!), "8:12")
    }

    func testDurationString() {
        XCTAssertEqual(Formatting.durationString(minutes: 529), "8:49")
        XCTAssertEqual(Formatting.durationString(minutes: 61), "1:01")
        XCTAssertEqual(Formatting.durationString(minutes: 5), "0:05")
        XCTAssertEqual(Formatting.durationString(minutes: 0), "0:00")
        XCTAssertEqual(Formatting.durationString(minutes: 5999), "> 99 h")
    }

    func testTooltipContent() {
        let tooltip = Formatting.tooltipText(discharging(estimate: estimate))
        let lines = tooltip.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Restwatt")
        XCTAssertEqual(lines[1], "Battery 95 %, 63.0 Wh remaining")
        XCTAssertEqual(lines[2], "Drawing 7.1 W now")
        XCTAssertEqual(lines[3], "Time left at current draw: 8:49")
        XCTAssertEqual(lines[4], "Time left, smoothed (42 min observed, confidence high): 8:12")
        XCTAssertEqual(lines[5], "macOS estimate: 7:46")
        XCTAssertTrue(tooltip.contains("estimate"))
        XCTAssertTrue(tooltip.contains("your processes"))
        XCTAssertTrue(tooltip.contains("CPU energy only"))
        XCTAssertTrue(tooltip.contains("Discord Helper (Renderer) (2 processes)  0.42 W"))
        XCTAssertTrue(tooltip.contains("Restwatt  0.01 W"))
        XCTAssertFalse(tooltip.contains("Terminal"), "tooltip lists the top 3 only")
        XCTAssertTrue(tooltip.contains("Visible total 0.63 W over 105 processes, unaccounted 6.51 W"))
    }

    func testTooltipWithoutEstimateAndWhileWarmingUp() {
        let tooltip = Formatting.tooltipText(discharging(estimate: nil))
        XCTAssertTrue(tooltip.contains("waiting for the first gauge reading"))
        let ac = Formatting.tooltipText(onAC(fullyCharged: false))
        XCTAssertTrue(ac.contains("On AC power, not charging"))
        XCTAssertTrue(ac.contains("collecting the first interval"))
        XCTAssertFalse(ac.contains("unaccounted"))
    }

    func testMenuLinesShowTopFiveAndVersion() {
        let lines = Formatting.menuLines(discharging(estimate: estimate), version: "0.1.0")
        XCTAssertTrue(lines.contains { $0.contains("Terminal") }, "menu lists up to 5 processes")
        XCTAssertEqual(lines.last, "Restwatt 0.1.0")
        XCTAssertTrue(lines.contains("Time left at current draw: 8:49"))
    }

    func testNoDashesInAnyOutput() {
        for model in allModels {
            var text = Formatting.menuBarTitle(model) + Formatting.tooltipText(model)
            text += Formatting.menuLines(model, version: "0.1.0").joined()
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(text)")
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(text)")
        }
    }
}
