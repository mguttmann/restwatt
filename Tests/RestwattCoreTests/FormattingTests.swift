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

    /// Restwatt's own time to full for the measured 96 W charge, first sample.
    private let chargeEstimate = Estimate(
        instantWatts: 49.055, smoothedWatts: 49.055, instantMinutes: 22, smoothedMinutes: 22,
        observedSeconds: 0, sampleCount: 1, confidence: .low)

    private func charging(estimate: Estimate?, gaugeMinutes: Int?, adapterWatts: Int? = 96) -> DisplayModel {
        .battery(BatteryStatus(
            state: .charging, percent: 75, remainingWattHours: 51.736, drawWatts: -49.055,
            estimate: estimate, systemTimeToEmptyMinutes: nil, avgTimeToFullMinutes: gaugeMinutes,
            processReport: report, sampledAt: 0, adapterWatts: adapterWatts))
    }

    /// The synthetic weak source: 2.3 W still leave the battery, 1667 min at that rate.
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

    private var allModels: [DisplayModel] {
        [
            discharging(estimate: estimate), discharging(estimate: nil),
            weakSource(estimate: weakEstimate), weakSource(estimate: nil, adapterWatts: nil),
            charging(estimate: chargeEstimate, gaugeMinutes: 50), charging(estimate: nil, gaugeMinutes: nil),
            onAC(fullyCharged: true), onAC(fullyCharged: false, adapterWatts: 96),
            sourceChanging,
            .unavailable(reason: "No battery found"),
        ]
    }

    func testMenuBarTitles() {
        XCTAssertEqual(Formatting.menuBarTitle(discharging(estimate: estimate)), "7.1 W  8:12")
        XCTAssertEqual(Formatting.menuBarTitle(discharging(estimate: nil)), "7.1 W  --:--")
        XCTAssertEqual(Formatting.menuBarTitle(weakSource(estimate: weakEstimate)), "2.3 W  27:47  weak source")
        XCTAssertEqual(Formatting.menuBarTitle(weakSource(estimate: nil)), "2.3 W  --:--  weak source")
        XCTAssertEqual(Formatting.menuBarTitle(charging(estimate: chargeEstimate, gaugeMinutes: 50)), "Charging  0:22",
                       "the title carries Restwatt's own time, not the gauge's")
        XCTAssertEqual(Formatting.menuBarTitle(charging(estimate: nil, gaugeMinutes: 50)), "Charging")
        XCTAssertEqual(Formatting.menuBarTitle(onAC(fullyCharged: false)), "On AC")
        XCTAssertEqual(Formatting.menuBarTitle(onAC(fullyCharged: true)), "On AC  100 %")
        XCTAssertEqual(Formatting.menuBarTitle(sourceChanging), "95 %")
        XCTAssertEqual(Formatting.menuBarTitle(.unavailable(reason: "No battery found")), "No battery")
    }

    func testChargingTitleWithoutMinutesOnTheEstimate() {
        var noMinutes = chargeEstimate
        noMinutes.smoothedMinutes = nil
        XCTAssertEqual(Formatting.menuBarTitle(charging(estimate: noMinutes, gaugeMinutes: 50)), "Charging")
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

    func testEnergyString() {
        XCTAssertEqual(Formatting.energy(0), "0 mWh")
        XCTAssertEqual(Formatting.energy(0.0123), "12 mWh")
        XCTAssertEqual(Formatting.energy(0.9994), "999 mWh")
        XCTAssertEqual(Formatting.energy(0.9996), "1.00 Wh")
        XCTAssertEqual(Formatting.energy(1.0234), "1.02 Wh")
        XCTAssertEqual(Formatting.energy(12.5), "12.50 Wh")
    }

    /// Nothing a file can deliver may trap in the renderers: the values below are absurd
    /// on purpose, far beyond what `StatisticsCodec` lets through, and still render.
    func testExtremeFiguresRenderWithoutTrapping() {
        XCTAssertEqual(Formatting.energy(-9.2e15), "0 mWh")
        XCTAssertEqual(Formatting.energy(-0.0001), "0 mWh")
        XCTAssertEqual(Formatting.energy(.nan), "0 mWh")
        XCTAssertEqual(Formatting.energy(-.infinity), "0 mWh")
        XCTAssertEqual(Formatting.energy(.infinity), "0 mWh", "not a number and not finite is not energy")
        XCTAssertEqual(Formatting.energy(1e300), "\(String(format: "%.2f", 1e300)) Wh")
        XCTAssertEqual(Formatting.wholeMinutes(seconds: 5.5e20), PowerMath.maximumMinutes)
        XCTAssertEqual(Formatting.wholeMinutes(seconds: .infinity), 0)
        XCTAssertEqual(Formatting.wholeMinutes(seconds: .nan), 0)
        XCTAssertEqual(Formatting.wholeMinutes(seconds: -1e300), 0)
        XCTAssertEqual(Formatting.wholeMinutes(seconds: 15120), 252)

        let absurd = DailyEnergyStatistic(
            day: "2026-09-22",
            entries: [DailyEnergyEntry(name: "huge", wattHours: 1e300),
                      DailyEnergyEntry(name: "negative", wattHours: -9.2e15),
                      DailyEnergyEntry(name: "nan", wattHours: .nan),
                      DailyEnergyEntry(name: "inf", wattHours: .infinity)],
            otherWattHours: -.infinity, sampledSeconds: 5.5e20)
        let lines = Formatting.todayLines(absurd, limit: 5)
        XCTAssertEqual(lines[2], "  negative  0 mWh")
        XCTAssertEqual(lines[3], "  nan  0 mWh")
        XCTAssertEqual(lines.last, "  Total today 0 mWh over > 99 h sampled", "a nan total shows as nothing, the seconds hit the cap")
        let rows = Formatting.todayRows(absurd, limit: 5)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.last, DetailRow("Total today", "0 mWh over > 99 h sampled"))

        var model = discharging(estimate: Estimate(
            instantWatts: 7.138, smoothedWatts: 7.5, instantMinutes: 529, smoothedMinutes: 492,
            observedSeconds: 5.5e20, sampleCount: Int.max, confidence: .high))
        if case .battery(var status) = model {
            status.today = absurd
            model = .battery(status)
        }
        XCTAssertTrue(Formatting.tooltipText(model).contains("(5999 min observed, confidence high)"))
        XCTAssertEqual(Formatting.menuLines(model, version: "0.1.0").last, "Restwatt 0.1.0")
        XCTAssertTrue(Formatting.detailRows(model).contains { $0.value.hasPrefix("5999 min observed") },
                      "the popover rows clamp the observed minutes the same way")
    }

    func testTodayLines() {
        XCTAssertEqual(Formatting.todayLines(Fixtures.todayStatistic, limit: 3), [
            "Today (your processes, CPU energy only, estimate)",
            "  Discord Helper (Renderer)  1.02 Wh",
            "  node  310 mWh",
            "  Restwatt  12 mWh",
            "  Total today 1.74 Wh over 4:12 sampled",
        ])
        XCTAssertEqual(Formatting.todayLines(nil, limit: 3), [])
    }

    func testTooltipAndMenuCarryTodayOnlyWhenSampled() {
        var withToday = discharging(estimate: estimate)
        if case .battery(var status) = withToday {
            status.today = Fixtures.todayStatistic
            withToday = .battery(status)
        }
        let tooltip = Formatting.tooltipText(withToday)
        XCTAssertTrue(tooltip.contains("Total today 1.74 Wh over 4:12 sampled"))
        XCTAssertTrue(tooltip.hasSuffix("  Total today 1.74 Wh over 4:12 sampled"), "today comes after the live list")
        XCTAssertFalse(Formatting.tooltipText(discharging(estimate: estimate)).contains("Total today"))

        var many = Fixtures.todayStatistic
        many.entries += ["d", "e", "f", "g"].map { DailyEnergyEntry(name: $0, wattHours: 0.001) }
        if case .battery(var status) = withToday {
            status.today = many
            withToday = .battery(status)
        }
        let menu = Formatting.menuLines(withToday, version: "0.1.0")
        XCTAssertTrue(menu.contains("  e  1 mWh"), "the menu shows up to five names")
        XCTAssertFalse(menu.contains("  f  1 mWh"))
        XCTAssertEqual(menu.last, "Restwatt 0.1.0")
        let threeNames = Formatting.tooltipText(withToday)
        XCTAssertTrue(threeNames.contains("  Restwatt  12 mWh"), "the tooltip shows three names, Restwatt is the third")
        XCTAssertFalse(threeNames.contains("  d  1 mWh"))
    }

    func testTooltipWithoutEstimateAndWhileWarmingUp() {
        let tooltip = Formatting.tooltipText(discharging(estimate: nil))
        XCTAssertTrue(tooltip.contains("waiting for the first gauge reading"))
        let ac = Formatting.tooltipText(onAC(fullyCharged: false))
        XCTAssertTrue(ac.contains("On AC power, not charging"))
        XCTAssertTrue(ac.contains("collecting the first interval"))
        XCTAssertFalse(ac.contains("unaccounted"))
        XCTAssertFalse(ac.contains("Source rating"), "no rating row without the gauge key")
    }

    func testWeakSourceLines() {
        XCTAssertEqual(Formatting.summaryLines(weakSource(estimate: weakEstimate)), [
            "Battery 95 %, 63.0 Wh remaining",
            "Drawing 2.3 W now",
            "Time left at current draw: 27:47",
            "Time left, smoothed (0 min observed, confidence low): 27:47",
            "macOS estimate: not yet available",
            "Power source: connected, but it delivers less than the Mac uses",
            "Source rating: 30 W",
        ])
        let lines = Formatting.summaryLines(weakSource(estimate: nil, adapterWatts: nil))
        XCTAssertEqual(lines[2], "Time left: waiting for the first gauge reading")
        XCTAssertEqual(lines.last, "Power source: connected, but it delivers less than the Mac uses")
    }

    func testChargingLines() {
        XCTAssertEqual(Formatting.summaryLines(charging(estimate: chargeEstimate, gaugeMinutes: 50)), [
            "Battery 75 %, 51.7 Wh remaining",
            "Charging at 49.1 W",
            "Time to full at current power: 0:22",
            "Time to full, smoothed (0 min observed, confidence low): 0:22",
            "macOS estimate: 0:50",
            "Source rating: 96 W",
        ])
        let lines = Formatting.summaryLines(charging(estimate: nil, gaugeMinutes: nil, adapterWatts: nil))
        XCTAssertEqual(lines[2], "Time to full: waiting for the first gauge reading")
        XCTAssertEqual(lines.last, "macOS estimate: not yet available")
    }

    func testSourceChangingAndRatedExternalPowerLines() {
        XCTAssertEqual(Formatting.summaryLines(sourceChanging), [
            "Battery 95 %, 63.0 Wh remaining",
            "Power: power source changed, waiting for the gauge",
        ])
        XCTAssertEqual(Formatting.summaryLines(onAC(fullyCharged: false, adapterWatts: 96)), [
            "Battery 100 %, 70.2 Wh remaining",
            "On AC power, not charging",
            "Source rating: 96 W",
        ])
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
