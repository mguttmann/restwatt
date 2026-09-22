import XCTest
@testable import RestwattCore

final class ProcessEnergyRankerTests: XCTestCase {
    // 6.588 J over a CPU-saturating child measured in 3 s; here spread over a 30 s interval.
    private let previous = [
        Fixtures.process(100, "yes", joules: 0, cpuSeconds: 0),
        Fixtures.process(200, "Discord Helper (Renderer)", joules: 10, cpuSeconds: 5),
        Fixtures.process(201, "Discord Helper (Renderer)", joules: 20, cpuSeconds: 7),
        Fixtures.process(300, "com.apple.WebKit.WebContent", joules: 1, cpuSeconds: 1),
        Fixtures.process(400, "reused", joules: 50, cpuSeconds: 3),
        Fixtures.process(500, "idle", joules: 2, cpuSeconds: 1),
    ]
    private let current = [
        Fixtures.process(100, "yes", joules: 6.588, cpuSeconds: 3),
        Fixtures.process(200, "Discord Helper (Renderer)", joules: 11, cpuSeconds: 5.6),
        Fixtures.process(201, "Discord Helper (Renderer)", joules: 20.5, cpuSeconds: 7.3),
        Fixtures.process(300, "com.apple.WebKit.WebContent", joules: 1.065, cpuSeconds: 1.4),
        Fixtures.process(400, "reused", joules: 3, cpuSeconds: 0.1),  // counter went down: new process
        Fixtures.process(500, "idle", joules: 2, cpuSeconds: 1),
        Fixtures.process(600, "newcomer", joules: 9, cpuSeconds: 2),  // no predecessor
    ]

    private func rank(limit: Int = 5, batteryIsOnlySource: Bool = true) -> ProcessEnergyReport {
        ProcessEnergyRanker.rank(
            previous: previous, current: current, dt: 30, drawWatts: 7.138,
            batteryIsOnlySource: batteryIsOnlySource, limit: limit)
    }

    func testWattsFromEnergyDelta() {
        let report = rank()
        let yes = report.entries.first { $0.name == "yes" }!
        XCTAssertEqual(yes.watts, 0.2196, accuracy: 0.0001)
        XCTAssertEqual(yes.cpuShare, 0.1, accuracy: 0.0001)
        XCTAssertEqual(yes.processCount, 1)
    }

    func testDecreasingCounterAndNewcomerAreSkipped() {
        let report = rank()
        XCTAssertNil(report.entries.first { $0.name == "reused" })
        XCTAssertNil(report.entries.first { $0.name == "newcomer" })
        XCTAssertEqual(report.processCount, 5)  // yes, 2x Discord, WebContent, idle
    }

    func testAggregationByName() {
        let report = rank()
        let discord = report.entries.first { $0.name == "Discord Helper (Renderer)" }!
        XCTAssertEqual(discord.watts, 1.5 / 30, accuracy: 1e-9)
        XCTAssertEqual(discord.cpuShare, 0.9 / 30, accuracy: 1e-9)
        XCTAssertEqual(discord.processCount, 2)
    }

    func testSortingLimitAndVisibleTotal() {
        let report = rank(limit: 2)
        XCTAssertEqual(report.entries.map(\.name), ["yes", "Discord Helper (Renderer)"])
        // Total covers every valid pid, not only the listed entries.
        XCTAssertEqual(report.visibleTotalWatts, (6.588 + 1.5 + 0.065) / 30, accuracy: 1e-9)
        XCTAssertFalse(report.isWarmingUp)
    }

    func testUnaccountedOnlyWhileTheBatteryIsTheOnlySource() {
        let discharging = rank()
        XCTAssertEqual(discharging.unaccountedWatts!, 7.138 - discharging.visibleTotalWatts, accuracy: 1e-9)
        XCTAssertNil(rank(batteryIsOnlySource: false).unaccountedWatts)
    }

    func testUnaccountedNeverNegative() {
        let report = ProcessEnergyRanker.rank(
            previous: previous, current: current, dt: 1, drawWatts: 0.5, batteryIsOnlySource: true)
        XCTAssertEqual(report.unaccountedWatts, 0)
    }

    func testFirstRoundIsWarmingUp() {
        let report = ProcessEnergyRanker.rank(
            previous: [], current: current, dt: 0, drawWatts: 7.138, batteryIsOnlySource: true)
        XCTAssertTrue(report.isWarmingUp)
        XCTAssertTrue(report.entries.isEmpty)
        XCTAssertNil(report.unaccountedWatts)
    }
}
