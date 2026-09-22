import XCTest
@testable import RestwattCore

/// Pins the label/value rows the hover popover and the click menu are built from.
final class DetailRowTests: XCTestCase {
    private let report = ProcessEnergyReport(
        entries: [
            ProcessEnergyEntry(name: "Discord Helper (Renderer)", watts: 0.416, cpuShare: 0.3, processCount: 2),
            ProcessEnergyEntry(name: "com.apple.WebKit.WebContent", watts: 0.0217, cpuShare: 0.13, processCount: 1),
            ProcessEnergyEntry(name: "Restwatt", watts: 0.01, cpuShare: 0.001, processCount: 1),
            ProcessEnergyEntry(name: "Terminal", watts: 0.005, cpuShare: 0.001, processCount: 1),
        ],
        visibleTotalWatts: 0.63, processCount: 105, unaccountedWatts: 6.508, isWarmingUp: false)

    private let estimate = Estimate(
        instantWatts: 7.138, smoothedWatts: 7.5, instantMinutes: 529, smoothedMinutes: 492,
        observedSeconds: 2520, sampleCount: 43, confidence: .high)

    private func discharging(estimate: Estimate?) -> DisplayModel {
        .battery(BatteryStatus(
            state: .discharging, percent: 95, remainingWattHours: 62.975, drawWatts: 7.138,
            estimate: estimate, systemTimeToEmptyMinutes: 466, avgTimeToFullMinutes: nil,
            processReport: report, sampledAt: 0))
    }

    private let chargeEstimate = Estimate(
        instantWatts: 49.055, smoothedWatts: 49.055, instantMinutes: 22, smoothedMinutes: 22,
        observedSeconds: 0, sampleCount: 1, confidence: .low)

    private func charging(estimate: Estimate?, gaugeMinutes: Int?, adapterWatts: Int? = 96) -> DisplayModel {
        .battery(BatteryStatus(
            state: .charging, percent: 75, remainingWattHours: 51.736, drawWatts: -49.055,
            estimate: estimate, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: gaugeMinutes,
            processReport: report, sampledAt: 0, adapterWatts: adapterWatts))
    }

    private let weakEstimate = Estimate(
        instantWatts: 2.266, smoothedWatts: 2.266, instantMinutes: 1667, smoothedMinutes: 1667,
        observedSeconds: 0, sampleCount: 1, confidence: .low)

    private func weakSource(estimate: Estimate?, adapterWatts: Int? = 30) -> DisplayModel {
        .battery(BatteryStatus(
            state: .drainingOnExternalPower, percent: 95, remainingWattHours: 62.975, drawWatts: 2.266,
            estimate: estimate, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: nil,
            processReport: report, sampledAt: 0, adapterWatts: adapterWatts))
    }

    private func onAC(fullyCharged: Bool, adapterWatts: Int? = nil) -> DisplayModel {
        .battery(BatteryStatus(
            state: .onExternalPower(fullyCharged: fullyCharged), percent: 100, remainingWattHours: 70.2,
            drawWatts: 0, estimate: nil, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: nil,
            processReport: .warmingUp, sampledAt: 0, adapterWatts: adapterWatts))
    }

    private var sourceChanging: DisplayModel {
        .battery(BatteryStatus(
            state: .powerSourceChanging, percent: 95, remainingWattHours: 62.975, drawWatts: 7.138,
            estimate: nil, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: nil,
            processReport: .warmingUp, sampledAt: 0, adapterWatts: 96))
    }

    func testDischargingRows() {
        let rows = Formatting.detailRows(discharging(estimate: estimate))
        XCTAssertEqual(rows, [
            DetailRow("Battery", "95 %, 63.0 Wh"),
            DetailRow("Drawing now", "7.1 W", emphasis: .primary),
            DetailRow("Time left at current draw", "8:49", emphasis: .primary),
            DetailRow("Time left, smoothed", "8:12", emphasis: .primary),
            DetailRow("Smoothing", "42 min observed, confidence high"),
            DetailRow("macOS estimate", "7:46"),
        ])
    }

    func testPrimaryRowsAreDrawAndBothTimesLeft() {
        let primary = Formatting.detailRows(discharging(estimate: estimate))
            .filter { $0.emphasis == .primary }
            .map(\.label)
        XCTAssertEqual(primary, ["Drawing now", "Time left at current draw", "Time left, smoothed"])
    }

    func testDischargingWithoutEstimate() {
        let rows = Formatting.detailRows(discharging(estimate: nil))
        XCTAssertEqual(rows[2], DetailRow("Time left", "waiting for the first gauge reading", emphasis: .primary))
        XCTAssertEqual(rows.last, DetailRow("macOS estimate", "7:46"))
        XCTAssertEqual(rows.count, 4)
    }

    func testEstimateWithoutMinutesShowsNotAvailable() {
        // Draw near zero yields an estimate without minutes; the primary rows must still exist.
        var noMinutes = estimate
        noMinutes.instantMinutes = nil
        noMinutes.smoothedMinutes = nil
        let rows = Formatting.detailRows(discharging(estimate: noMinutes))
        XCTAssertEqual(rows[2], DetailRow("Time left at current draw", "n/a", emphasis: .primary))
        XCTAssertEqual(rows[3], DetailRow("Time left, smoothed", "n/a", emphasis: .primary))
        XCTAssertEqual(rows.count, 6)
    }

    func testWeakSourceRows() {
        XCTAssertEqual(Formatting.detailRows(weakSource(estimate: weakEstimate)), [
            DetailRow("Battery", "95 %, 63.0 Wh"),
            DetailRow("Drawing now", "2.3 W", emphasis: .primary),
            DetailRow("Time left at current draw", "27:47", emphasis: .primary),
            DetailRow("Time left, smoothed", "27:47", emphasis: .primary),
            DetailRow("Smoothing", "0 min observed, confidence low"),
            DetailRow("macOS estimate", "not yet available"),
            DetailRow("Power source", "connected, but it delivers less than the Mac uses", emphasis: .primary),
            DetailRow("Source rating", "30 W"),
        ])
        let rows = Formatting.detailRows(weakSource(estimate: nil, adapterWatts: nil))
        XCTAssertEqual(rows[2], DetailRow("Time left", "waiting for the first gauge reading", emphasis: .primary))
        XCTAssertEqual(rows.last?.label, "Power source")
        XCTAssertEqual(rows.count, 5)
    }

    func testChargingRows() {
        XCTAssertEqual(Formatting.detailRows(charging(estimate: chargeEstimate, gaugeMinutes: 50)), [
            DetailRow("Battery", "75 %, 51.7 Wh"),
            DetailRow("Charging at", "49.1 W", emphasis: .primary),
            DetailRow("Time to full at current power", "0:22", emphasis: .primary),
            DetailRow("Time to full, smoothed", "0:22", emphasis: .primary),
            DetailRow("Smoothing", "0 min observed, confidence low"),
            DetailRow("macOS estimate", "0:50"),
            DetailRow("Source rating", "96 W"),
        ])
        let rows = Formatting.detailRows(charging(estimate: nil, gaugeMinutes: nil, adapterWatts: nil))
        XCTAssertEqual(rows[2], DetailRow("Time to full", "waiting for the first gauge reading", emphasis: .primary))
        XCTAssertEqual(rows.last, DetailRow("macOS estimate", "not yet available"))
        XCTAssertEqual(rows.count, 4)
    }

    func testExternalPowerAndSourceChangingRows() {
        XCTAssertEqual(Formatting.detailRows(onAC(fullyCharged: true)), [
            DetailRow("Battery", "100 %, 70.2 Wh"),
            DetailRow("Power", "On AC, fully charged", emphasis: .primary),
        ])
        XCTAssertEqual(Formatting.detailRows(onAC(fullyCharged: false, adapterWatts: 96)), [
            DetailRow("Battery", "100 %, 70.2 Wh"),
            DetailRow("Power", "On AC, not charging", emphasis: .primary),
            DetailRow("Source rating", "96 W"),
        ])
        XCTAssertEqual(Formatting.detailRows(sourceChanging), [
            DetailRow("Battery", "95 %, 63.0 Wh"),
            DetailRow("Power", "power source changed, waiting for the gauge", emphasis: .primary),
        ], "a stale reading shows neither watts nor a rating")
    }

    func testUnavailableIsOneHeading() {
        XCTAssertEqual(Formatting.detailRows(.unavailable(reason: "No battery found")),
                       [DetailRow("No battery found", emphasis: .heading)])
    }

    func testProcessRows() {
        let rows = Formatting.processRows(report, limit: 3)
        XCTAssertEqual(rows, [
            DetailRow("Top processes (your processes, CPU energy only, estimate)", emphasis: .heading),
            DetailRow("Discord Helper (Renderer) (2 processes)", "0.42 W"),
            DetailRow("com.apple.WebKit.WebContent", "0.02 W"),
            DetailRow("Restwatt", "0.01 W"),
            DetailRow("Visible total", "0.63 W over 105 processes, unaccounted 6.51 W"),
        ])
        XCTAssertEqual(Formatting.processRows(report, limit: 5).count, 6, "all four entries plus heading and total")
    }

    func testProcessRowsWhileWarmingUpAndWhenEmpty() {
        XCTAssertEqual(Formatting.processRows(.warmingUp, limit: 5).map(\.label),
                       [Formatting.processListHeading, "collecting the first interval"])
        let empty = ProcessEnergyReport(
            entries: [], visibleTotalWatts: 0, processCount: 0, unaccountedWatts: nil, isWarmingUp: false)
        let rows = Formatting.processRows(empty, limit: 5)
        XCTAssertEqual(rows[1].label, "no process used measurable energy")
        XCTAssertEqual(rows.last, DetailRow("Visible total", "0.00 W over 0 processes"))
    }

    func testRowsCarryTheSameFiguresAsTheStringLines() {
        // The string functions are pinned elsewhere; the rows must not drift from them.
        for model in [discharging(estimate: estimate), discharging(estimate: nil),
                      weakSource(estimate: weakEstimate), weakSource(estimate: nil),
                      charging(estimate: chargeEstimate, gaugeMinutes: 50), charging(estimate: nil, gaugeMinutes: nil),
                      onAC(fullyCharged: false, adapterWatts: 96), sourceChanging,
                      .unavailable(reason: "No battery found")] {
            let summary = Formatting.summaryLines(model).joined(separator: "\n")
            for row in Formatting.detailRows(model) where !row.value.isEmpty {
                let figure = row.value.split(separator: ",").first.map(String.init) ?? row.value
                XCTAssertTrue(summary.contains(figure), "\(figure) missing from summary lines for \(model)")
            }
        }
    }

    func testNoDashesInRows() {
        for model in [discharging(estimate: estimate), weakSource(estimate: weakEstimate),
                      charging(estimate: chargeEstimate, gaugeMinutes: nil), onAC(fullyCharged: true), sourceChanging] {
            let text = (Formatting.detailRows(model) + Formatting.processRows(report, limit: 5))
                .map { $0.label + $0.value }.joined()
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(text)")
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(text)")
        }
    }
}
