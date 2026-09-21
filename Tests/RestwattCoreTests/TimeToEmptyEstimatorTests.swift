import XCTest
@testable import RestwattCore

final class TimeToEmptyEstimatorTests: XCTestCase {
    private let remainingWh = 62.975

    /// Feed `count` samples of `watts` every 60 s starting at `start`; returns the next time.
    private func feed(_ estimator: inout TimeToEmptyEstimator, from start: TimeInterval,
                      count: Int, watts: Double) -> TimeInterval {
        var time = start
        for _ in 0..<count {
            estimator.add(time: time, remainingWattHours: remainingWh, drawWatts: watts)
            time += 60
        }
        return time
    }

    func testFirstSampleIsTakenAsIs() {
        var estimator = TimeToEmptyEstimator()
        XCTAssertNil(estimator.estimate)
        estimator.add(time: 0, remainingWattHours: remainingWh, drawWatts: 7.138)
        let estimate = estimator.estimate!
        XCTAssertEqual(estimate.instantWatts, 7.138)
        XCTAssertEqual(estimate.smoothedWatts, 7.138)
        XCTAssertEqual(estimate.instantMinutes, estimate.smoothedMinutes)
        XCTAssertEqual(estimate.instantMinutes, 529)
        XCTAssertEqual(estimate.observedSeconds, 0)
        XCTAssertEqual(estimate.sampleCount, 1)
        XCTAssertEqual(estimate.confidence, .low)
    }

    func testDuplicateTimeChangesNothing() {
        var estimator = TimeToEmptyEstimator()
        estimator.add(time: 0, remainingWattHours: remainingWh, drawWatts: 7)
        let before = estimator.estimate
        estimator.add(time: 0, remainingWattHours: remainingWh, drawWatts: 21)
        XCTAssertEqual(estimator.estimate, before)
        estimator.add(time: -5, remainingWattHours: remainingWh, drawWatts: 21)
        XCTAssertEqual(estimator.estimate, before)
    }

    func testNonPositiveSamplesAreIgnored() {
        var estimator = TimeToEmptyEstimator()
        estimator.add(time: 0, remainingWattHours: remainingWh, drawWatts: 7)
        estimator.add(time: 60, remainingWattHours: remainingWh, drawWatts: 0)
        estimator.add(time: 120, remainingWattHours: remainingWh, drawWatts: -12)
        XCTAssertEqual(estimator.estimate?.sampleCount, 1)
    }

    /// The adaptive part: the same 3x outlier moves a young estimate a lot and an old one
    /// barely. A fixed time constant fails this test in one of the two directions.
    func testOutlierMovesYoungEstimateMoreThanOldOne() {
        var young = TimeToEmptyEstimator()
        let t = feed(&young, from: 0, count: 2, watts: 7)  // t = 0, 60
        young.add(time: t, remainingWattHours: remainingWh, drawWatts: 21)  // t = 120
        let youngRise = young.estimate!.smoothedWatts / 7 - 1

        var old = TimeToEmptyEstimator()
        let t2 = feed(&old, from: 0, count: 61, watts: 7)  // 60 min of steady 7 W
        old.add(time: t2, remainingWattHours: remainingWh, drawWatts: 21)
        let oldRise = old.estimate!.smoothedWatts / 7 - 1

        XCTAssertGreaterThan(youngRise, 0.40)
        XCTAssertLessThan(oldRise, 0.10)
        XCTAssertGreaterThan(youngRise, oldRise * 5)
        XCTAssertEqual(old.estimate!.instantWatts, 21)
    }

    func testLastingChangeIsAdoptedWithinThreeTimeConstants() {
        var estimator = TimeToEmptyEstimator()
        let t = feed(&estimator, from: 0, count: 61, watts: 7)
        _ = feed(&estimator, from: t, count: 90, watts: 14)  // another 90 min
        XCTAssertGreaterThan(estimator.estimate!.smoothedWatts, 13.3)
        XCTAssertLessThan(estimator.estimate!.smoothedWatts, 14)
    }

    func testSmoothedTimeIsMoreStableThanInstantTime() {
        var estimator = TimeToEmptyEstimator()
        let t = feed(&estimator, from: 0, count: 31, watts: 7)
        estimator.add(time: t, remainingWattHours: remainingWh, drawWatts: 21)
        let estimate = estimator.estimate!
        XCTAssertLessThan(estimate.instantMinutes!, 200)
        XCTAssertGreaterThan(estimate.smoothedMinutes!, 400)
    }

    func testConfidenceThresholds() {
        XCTAssertEqual(TimeToEmptyEstimator.confidence(observedSeconds: 0), .low)
        XCTAssertEqual(TimeToEmptyEstimator.confidence(observedSeconds: 299), .low)
        XCTAssertEqual(TimeToEmptyEstimator.confidence(observedSeconds: 300), .medium)
        XCTAssertEqual(TimeToEmptyEstimator.confidence(observedSeconds: 1799), .medium)
        XCTAssertEqual(TimeToEmptyEstimator.confidence(observedSeconds: 1800), .high)

        var estimator = TimeToEmptyEstimator()
        _ = feed(&estimator, from: 0, count: 6, watts: 7)  // observed 300 s
        XCTAssertEqual(estimator.estimate?.confidence, .medium)
        _ = feed(&estimator, from: 360, count: 25, watts: 7)  // observed 1800 s
        XCTAssertEqual(estimator.estimate?.observedSeconds, 1800)
        XCTAssertEqual(estimator.estimate?.confidence, .high)
    }

    func testResetForgetsEverything() {
        var estimator = TimeToEmptyEstimator()
        _ = feed(&estimator, from: 0, count: 10, watts: 7)
        estimator.reset()
        XCTAssertNil(estimator.estimate)
        estimator.add(time: 1000, remainingWattHours: remainingWh, drawWatts: 9)
        XCTAssertEqual(estimator.estimate?.smoothedWatts, 9)
        XCTAssertEqual(estimator.estimate?.confidence, .low)
    }
}
