import XCTest
@testable import RestwattCore

final class EnergyFlowEstimatorTests: XCTestCase {
    private let remainingWh = 62.975

    /// Feed `count` samples of `watts` every 60 s starting at `start`; returns the next time.
    private func feed(_ estimator: inout EnergyFlowEstimator, from start: TimeInterval,
                      count: Int, watts: Double) -> TimeInterval {
        var time = start
        for _ in 0..<count {
            estimator.add(time: time, energyWattHours: remainingWh, watts: watts)
            time += 60
        }
        return time
    }

    func testFirstSampleIsTakenAsIs() {
        var estimator = EnergyFlowEstimator()
        XCTAssertNil(estimator.estimate)
        estimator.add(time: 0, energyWattHours: remainingWh, watts: 7.138)
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
        var estimator = EnergyFlowEstimator()
        estimator.add(time: 0, energyWattHours: remainingWh, watts: 7)
        let before = estimator.estimate
        estimator.add(time: 0, energyWattHours: remainingWh, watts: 21)
        XCTAssertEqual(estimator.estimate, before)
        estimator.add(time: -5, energyWattHours: remainingWh, watts: 21)
        XCTAssertEqual(estimator.estimate, before)
    }

    func testNonPositiveSamplesAreIgnored() {
        var estimator = EnergyFlowEstimator()
        estimator.add(time: 0, energyWattHours: remainingWh, watts: 7)
        estimator.add(time: 60, energyWattHours: remainingWh, watts: 0)
        estimator.add(time: 120, energyWattHours: remainingWh, watts: -12)
        XCTAssertEqual(estimator.estimate?.sampleCount, 1)
    }

    /// The adaptive part: the same 3x outlier moves a young estimate a lot and an old one
    /// barely. A fixed time constant fails this test in one of the two directions.
    func testOutlierMovesYoungEstimateMoreThanOldOne() {
        var young = EnergyFlowEstimator()
        let t = feed(&young, from: 0, count: 2, watts: 7)  // t = 0, 60
        young.add(time: t, energyWattHours: remainingWh, watts: 21)  // t = 120
        let youngRise = young.estimate!.smoothedWatts / 7 - 1

        var old = EnergyFlowEstimator()
        let t2 = feed(&old, from: 0, count: 61, watts: 7)  // 60 min of steady 7 W
        old.add(time: t2, energyWattHours: remainingWh, watts: 21)
        let oldRise = old.estimate!.smoothedWatts / 7 - 1

        XCTAssertGreaterThan(youngRise, 0.40)
        XCTAssertLessThan(oldRise, 0.10)
        XCTAssertGreaterThan(youngRise, oldRise * 5)
        XCTAssertEqual(old.estimate!.instantWatts, 21)
    }

    func testLastingChangeIsAdoptedWithinThreeTimeConstants() {
        var estimator = EnergyFlowEstimator()
        let t = feed(&estimator, from: 0, count: 61, watts: 7)
        _ = feed(&estimator, from: t, count: 90, watts: 14)  // another 90 min
        XCTAssertGreaterThan(estimator.estimate!.smoothedWatts, 13.3)
        XCTAssertLessThan(estimator.estimate!.smoothedWatts, 14)
    }

    func testSmoothedTimeIsMoreStableThanInstantTime() {
        var estimator = EnergyFlowEstimator()
        let t = feed(&estimator, from: 0, count: 31, watts: 7)
        estimator.add(time: t, energyWattHours: remainingWh, watts: 21)
        let estimate = estimator.estimate!
        XCTAssertLessThan(estimate.instantMinutes!, 200)
        XCTAssertGreaterThan(estimate.smoothedMinutes!, 400)
    }

    func testConfidenceThresholds() {
        XCTAssertEqual(EnergyFlowEstimator.confidence(observedSeconds: 0), .low)
        XCTAssertEqual(EnergyFlowEstimator.confidence(observedSeconds: 299), .low)
        XCTAssertEqual(EnergyFlowEstimator.confidence(observedSeconds: 300), .medium)
        XCTAssertEqual(EnergyFlowEstimator.confidence(observedSeconds: 1799), .medium)
        XCTAssertEqual(EnergyFlowEstimator.confidence(observedSeconds: 1800), .high)

        var estimator = EnergyFlowEstimator()
        _ = feed(&estimator, from: 0, count: 6, watts: 7)  // observed 300 s
        XCTAssertEqual(estimator.estimate?.confidence, .medium)
        _ = feed(&estimator, from: 360, count: 25, watts: 7)  // observed 1800 s
        XCTAssertEqual(estimator.estimate?.observedSeconds, 1800)
        XCTAssertEqual(estimator.estimate?.confidence, .high)
    }

    /// The charging direction uses the same smoothing: fed with the missing energy and the
    /// charging power of the measured 96 W dump, the first estimate is the linear time to
    /// full, and later samples move it less and less.
    func testChargingSeriesYieldsTimeToFullWithGrowingStability() {
        let missingWh = PowerMath.missingWattHours(Fixtures.charging96W)
        var estimator = EnergyFlowEstimator()
        estimator.add(time: 0, energyWattHours: missingWh, watts: 49.055)
        let first = estimator.estimate!
        XCTAssertEqual(first.instantMinutes, 22)
        XCTAssertEqual(first.smoothedMinutes, 22, "the first sample is taken as is")
        XCTAssertEqual(first.confidence, .low)

        estimator.add(time: 60, energyWattHours: missingWh, watts: 30)  // the charger throttles
        let young = estimator.estimate!
        XCTAssertLessThan(young.smoothedWatts, 49)
        XCTAssertGreaterThan(young.smoothedWatts, 30)
        XCTAssertGreaterThan(young.smoothedMinutes!, first.smoothedMinutes!)
        XCTAssertLessThan(young.smoothedMinutes!, young.instantMinutes!, "smoothed lags the drop")

        var steady = EnergyFlowEstimator()
        var time: TimeInterval = 0
        for _ in 0..<61 {
            steady.add(time: time, energyWattHours: missingWh, watts: 49.055)
            time += 60
        }
        steady.add(time: time, energyWattHours: missingWh, watts: 30)
        let old = steady.estimate!
        XCTAssertGreaterThan(old.smoothedWatts, 47, "an hour of steady charging barely moves on one outlier")
        XCTAssertEqual(old.confidence, .high)
        XCTAssertEqual(old.smoothedMinutes, 23)
    }

    // MARK: Resuming an earlier session

    private let remembered = EnergyFlowEstimator.Memory(smoothedWatts: 7.5, observedSeconds: 2400, sampleCount: 40)

    func testResumedEstimatorHasNoEstimateBeforeTheFirstSample() {
        let estimator = EnergyFlowEstimator(resuming: remembered)
        XCTAssertNil(estimator.estimate)
        XCTAssertEqual(estimator.memory, remembered, "the memory itself is there from the start")
    }

    func testFirstSampleAfterResumeKeepsTheSmoothedPower() {
        var estimator = EnergyFlowEstimator(resuming: remembered)
        estimator.add(time: 0, energyWattHours: remainingWh, watts: 9.0)
        let estimate = estimator.estimate!
        XCTAssertEqual(estimate.smoothedWatts, 7.5, "no in-session dt yet, so the smoothed power does not move")
        XCTAssertEqual(estimate.instantWatts, 9.0)
        XCTAssertEqual(estimate.observedSeconds, 2400)
        XCTAssertEqual(estimate.sampleCount, 41)
        XCTAssertEqual(estimate.confidence, .high)
        XCTAssertEqual(estimate.instantMinutes, 420)
        XCTAssertEqual(estimate.smoothedMinutes, 504)
    }

    func testSecondSampleAfterResumeSmoothsWithTheRememberedWindow() {
        var long = EnergyFlowEstimator(resuming: EnergyFlowEstimator.Memory(
            smoothedWatts: 7, observedSeconds: 3600, sampleCount: 60))
        long.add(time: 0, energyWattHours: remainingWh, watts: 7)
        long.add(time: 60, energyWattHours: remainingWh, watts: 21)
        let longRise = long.estimate!.smoothedWatts / 7 - 1

        var short = EnergyFlowEstimator(resuming: EnergyFlowEstimator.Memory(
            smoothedWatts: 7, observedSeconds: 60, sampleCount: 2))
        short.add(time: 0, energyWattHours: remainingWh, watts: 7)
        short.add(time: 60, energyWattHours: remainingWh, watts: 21)
        let shortRise = short.estimate!.smoothedWatts / 7 - 1

        XCTAssertLessThan(longRise, 0.10, "an hour of remembered observation damps the outlier")
        XCTAssertGreaterThan(shortRise, 0.40, "a minute of remembered observation barely does")
        XCTAssertEqual(long.estimate?.observedSeconds, 3660)
        XCTAssertEqual(short.estimate?.observedSeconds, 120)
    }

    func testMemoryRoundTrip() {
        XCTAssertNil(EnergyFlowEstimator().memory)
        var estimator = EnergyFlowEstimator()
        _ = feed(&estimator, from: 0, count: 10, watts: 7)
        let memory = estimator.memory!
        XCTAssertEqual(memory, EnergyFlowEstimator.Memory(smoothedWatts: 7, observedSeconds: 540, sampleCount: 10))
        XCTAssertEqual(EnergyFlowEstimator(resuming: memory).memory, memory)
    }

    func testMaximumRememberedObservationIsWhereTauStopsGrowing() {
        XCTAssertEqual(EnergyFlowEstimator.maximumRememberedObservation,
                       EnergyFlowEstimator.tauMax * EnergyFlowEstimator.rampDivisor)
        XCTAssertEqual(EnergyFlowEstimator.maximumRememberedObservation, 3600, "the hour the README names")
    }

    func testResetForgetsEverything() {
        var estimator = EnergyFlowEstimator()
        _ = feed(&estimator, from: 0, count: 10, watts: 7)
        estimator.reset()
        XCTAssertNil(estimator.estimate)
        estimator.add(time: 1000, energyWattHours: remainingWh, watts: 9)
        XCTAssertEqual(estimator.estimate?.smoothedWatts, 9)
        XCTAssertEqual(estimator.estimate?.confidence, .low)
    }
}
