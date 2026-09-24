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

    /// 2031-06-11 18:05:11 in New York, a second before the synthetic excerpt's plug-in.
    private let beforePlugIn = Date(timeIntervalSince1970: 1_938_981_911)

    private func period(since: Double, percent: Int? = 100, precision: UnplugRecord.Precision = .exact,
                        now: Date? = nil) -> OnBatteryPeriod {
        OnBatteryPeriod(since: Date(timeIntervalSince1970: since), now: now ?? beforePlugIn,
                        percentAtUnplug: percent, precision: precision, calendar: Fixtures.newYork)
    }

    private func onBattery(_ period: OnBatteryPeriod?, state: PowerState = .discharging) -> DisplayModel {
        .battery(BatteryStatus(
            state: state, percent: 10, remainingWattHours: 6.9, drawWatts: 13.2,
            estimate: estimate, systemTimeToEmptyMinutes: 31, avgTimeToFullMinutes: nil,
            processReport: report, sampledAt: 0, onBattery: period))
    }

    private func periodRows(_ model: DisplayModel) -> [DetailRow] {
        Formatting.detailRows(model).filter { $0.label == "On battery for" || $0.label == "Since" }
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

    func testTodayRows() {
        XCTAssertEqual(Formatting.todayRows(Fixtures.todayStatistic, limit: 3), [
            DetailRow("Today (your processes, CPU energy only, estimate)", emphasis: .heading),
            DetailRow("Discord Helper (Renderer)", "1.02 Wh"),
            DetailRow("node", "310 mWh"),
            DetailRow("Restwatt", "12 mWh"),
            DetailRow("Total today", "1.74 Wh over 4:12 sampled"),
        ])
        XCTAssertEqual(Formatting.todayRows(Fixtures.todayStatistic, limit: 2).map(\.label),
                       [Formatting.todayHeading, "Discord Helper (Renderer)", "node", "Total today"])
        XCTAssertEqual(Formatting.todayRows(nil, limit: 3), [], "no section before the first sampled interval of the day")
    }

    func testTodayRowsCarryTheSameFiguresAsTheTodayLines() {
        let lines = Formatting.todayLines(Fixtures.todayStatistic, limit: 3)
        let rows = Formatting.todayRows(Fixtures.todayStatistic, limit: 3)
        XCTAssertEqual(lines.count, rows.count)
        XCTAssertEqual(lines.first, rows.first?.label)
        for (line, row) in zip(lines.dropFirst(), rows.dropFirst()) {
            XCTAssertTrue(line.hasPrefix("  \(row.label)"), "\(line) does not start with \(row.label)")
            XCTAssertTrue(line.hasSuffix(row.value), "\(line) does not end with \(row.value)")
        }
    }

    func testRowsCarryTheSameFiguresAsTheStringLines() {
        // The string functions are pinned elsewhere; the rows must not drift from them.
        for model in [discharging(estimate: estimate), discharging(estimate: nil),
                      weakSource(estimate: weakEstimate), weakSource(estimate: nil),
                      charging(estimate: chargeEstimate, gaugeMinutes: 50), charging(estimate: nil, gaugeMinutes: nil),
                      onAC(fullyCharged: false, adapterWatts: 96), sourceChanging,
                      onBattery(period(since: 1_938_961_041)), onBattery(period(since: 1_938_911_400)),
                      onBattery(period(since: 1_938_980_800, precision: .lowerBound)),
                      onBattery(period(since: 1_938_961_041), state: .powerSourceChanging),
                      .unavailable(reason: "No battery found")] {
            let summary = Formatting.summaryLines(model).joined(separator: "\n")
            for row in Formatting.detailRows(model) where !row.value.isEmpty {
                let figure = row.value.split(separator: ",").first.map(String.init) ?? row.value
                XCTAssertTrue(summary.contains(figure), "\(figure) missing from summary lines for \(model)")
            }
        }
    }

    func testOnBatteryRowsNameTheDurationAndTheUnplug() {
        let measured = onBattery(period(since: 1_938_961_041))
        XCTAssertEqual(periodRows(measured), [DetailRow("On battery for", "5:47", emphasis: .primary),
                                              DetailRow("Since", "12:17, from 100 %")])
        XCTAssertEqual(periodRows(onBattery(period(since: 1_938_961_041, percent: nil))).last,
                       DetailRow("Since", "12:17"), "an exact start without a known charge")
        XCTAssertEqual(periodRows(onBattery(period(since: 1_938_980_800, precision: .lowerBound))),
                       [DetailRow("On battery for", "at least 0:18", emphasis: .primary),
                        DetailRow("Since", "17:46 or earlier")])
        XCTAssertEqual(periodRows(onBattery(period(since: 1_938_911_400))).last,
                       DetailRow("Since", "yesterday 22:30, from 100 %"))
        XCTAssertEqual(periodRows(onBattery(period(since: 1_938_825_000))).last,
                       DetailRow("Since", "2031-06-09 22:30, from 100 %"))
        XCTAssertEqual(periodRows(onBattery(period(since: 1_937_981_911, precision: .lowerBound))).first,
                       DetailRow("On battery for", "> 99 h", emphasis: .primary), "capped, and no `at least` on a cap")
        XCTAssertEqual(periodRows(onBattery(period(since: 1_938_981_971))).first,
                       DetailRow("On battery for", "0:00", emphasis: .primary), "a start a minute ahead shows no negative time")
        XCTAssertEqual(periodRows(onBattery(period(since: 1_938_961_041, now: Date(timeIntervalSince1970: 1_938_961_100)))).first,
                       DetailRow("On battery for", "0:00", emphasis: .primary), "59 s are not yet a minute, never rounded up")
    }

    func testOnBatteryRowsFollowTheMacOSEstimateAndAreAbsentOnASource() {
        let labels = Formatting.detailRows(onBattery(period(since: 1_938_961_041))).map(\.label)
        XCTAssertEqual(labels, ["Battery", "Drawing now", "Time left at current draw", "Time left, smoothed", "Smoothing",
                                "macOS estimate", "On battery for", "Since"])
        let changing = Formatting.detailRows(onBattery(period(since: 1_938_961_041), state: .powerSourceChanging))
        XCTAssertEqual(changing.map(\.label), ["Battery", "Power", "On battery for", "Since"])
        XCTAssertEqual(periodRows(onBattery(nil)), [])
        for model in [discharging(estimate: estimate), weakSource(estimate: weakEstimate),
                      charging(estimate: chargeEstimate, gaugeMinutes: 50), onAC(fullyCharged: true), sourceChanging] {
            XCTAssertEqual(periodRows(model), [], "no period rows without a period: \(model)")
        }
        XCTAssertEqual(Formatting.menuBarTitle(onBattery(period(since: 1_938_961_041))),
                       Formatting.menuBarTitle(onBattery(nil)), "the menu bar title is unchanged")
    }

    func testNoDashesInRows() {
        for model in [discharging(estimate: estimate), weakSource(estimate: weakEstimate),
                      charging(estimate: chargeEstimate, gaugeMinutes: nil), onAC(fullyCharged: true), sourceChanging,
                      onBattery(period(since: 1_938_961_041)),
                      onBattery(period(since: 1_938_825_000, precision: .lowerBound))] {
            let text = (Formatting.detailRows(model) + Formatting.processRows(report, limit: 5)
                + Formatting.todayRows(Fixtures.todayStatistic, limit: 5))
                .map { $0.label + $0.value }.joined()
            XCTAssertFalse(text.contains("\u{2013}"), "en dash in \(text)")
            XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(text)")
        }
    }
}
