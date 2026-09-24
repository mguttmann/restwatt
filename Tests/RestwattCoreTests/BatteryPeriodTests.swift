import XCTest
@testable import RestwattCore

/// The battery period through the monitor: live unplug, plug-in, launch on battery, the one
/// power log read, and what the statistics file keeps of it.
final class BatteryPeriodTests: XCTestCase {
    /// 2031-06-11 17:46:40 in New York, some hours after the synthetic excerpt's unplug at 12:17:21.
    private let afternoon = Date(timeIntervalSince1970: 1_938_980_800)

    private var wallClock: ManualWallClock!
    private var clock: ManualClock!
    private var battery: FakeBattery!
    private var store: MemoryStatisticsStore!
    private var monitor: BatteryMonitor!

    private func launch(_ stored: StoredStatistics? = nil, at now: Date? = nil,
                        on snapshot: BatterySnapshot = Fixtures.discharging7W) {
        wallClock = ManualWallClock(now: now ?? afternoon)
        clock = ManualClock(now: 1000)
        battery = FakeBattery(snapshot)
        store = MemoryStatisticsStore(stored)
        let memory = EnergyMemory(store: store, wallClock: wallClock, calendar: Fixtures.newYork)
        monitor = BatteryMonitor(
            battery: battery, processes: FakeProcesses(), clock: clock, memory: memory,
            period: BatteryPeriodTracker(wallClock: wallClock, calendar: Fixtures.newYork, memory: memory))
    }

    @discardableResult
    private func tick(after seconds: TimeInterval = 0, on snapshot: BatterySnapshot? = nil) -> BatteryStatus? {
        wallClock.advance(by: seconds)
        clock.advance(by: seconds)
        if let snapshot {
            battery.result = .success(snapshot)
        }
        guard case .battery(let status) = monitor.tick() else {
            XCTFail("expected a battery model")
            return nil
        }
        return status
    }

    private func rows(_ status: BatteryStatus?) -> [DetailRow] {
        guard let status else {
            return []
        }
        return Formatting.detailRows(.battery(status)).filter { $0.label == "On battery for" || $0.label == "Since" }
    }

    private var logOnBattery: PowerLogSummary {
        var scanner = PowerLogScanner()
        scanner.consume(Fixtures.powerLogLines.dropLast().joined(separator: "\n"))
        scanner.finish()
        return scanner.summary
    }

    private var logAfterPlugIn: PowerLogSummary {
        var scanner = PowerLogScanner()
        scanner.consume(Fixtures.powerLogExcerpt)
        scanner.finish()
        return scanner.summary
    }

    private func stored(unplug: UnplugRecord?, bootTime: Double? = Fixtures.bootTime.timeIntervalSince1970,
                        estimators: [String: StoredEstimatorState] = [:]) -> StoredStatistics {
        StoredStatistics(bootTime: bootTime, savedAt: afternoon.timeIntervalSince1970 - 300,
                         estimators: estimators, unplug: unplug)
    }

    // MARK: Live

    func testALiveUnplugIsExactWithTheChargeAndNeedsNoLog() {
        launch(on: Fixtures.charging)
        XCTAssertNil(tick()?.onBattery, "no period while a source is connected")
        let status = tick(after: 2, on: Fixtures.discharging7W)
        let record = UnplugRecord(unpluggedAt: afternoon.timeIntervalSince1970 + 2, percent: 95, precision: .exact)
        XCTAssertEqual(status?.onBattery?.precision, .exact)
        XCTAssertEqual(status?.onBattery?.percentAtUnplug, 95)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "0:00", emphasis: .primary),
                                      DetailRow("Since", "17:46, from 95 %")])
        XCTAssertNil(monitor.takePowerLogRequest(), "a watched unplug needs no log")
        XCTAssertEqual(store.stored?.unplug, record, "persisted with the tick")

        let later = tick(after: 5400)
        XCTAssertEqual(rows(later).first, DetailRow("On battery for", "1:30", emphasis: .primary))
        XCTAssertEqual(store.stored?.unplug, record)
    }

    func testPluggingInClearsTheRecordAndAWeakSourceCountsAsConnected() {
        launch(on: Fixtures.charging)
        tick()
        tick(after: 2, on: Fixtures.discharging7W)
        XCTAssertNotNil(store.stored?.unplug)
        let plugged = tick(after: 30, on: Fixtures.charging)
        XCTAssertNil(plugged?.onBattery)
        XCTAssertEqual(rows(plugged), [])
        XCTAssertNil(store.stored?.unplug, "the file no longer carries it")

        tick(after: 2, on: Fixtures.discharging7W)
        XCTAssertNotNil(store.stored?.unplug)
        var weakSource = Fixtures.weakSourceDraining
        weakSource.updateTime += 60
        let weak = tick(after: 30, on: weakSource)
        XCTAssertEqual(weak?.state, .drainingOnExternalPower)
        XCTAssertNil(weak?.onBattery, "a source that still drains the battery is still a source")
        XCTAssertEqual(rows(weak), [])
        XCTAssertNil(store.stored?.unplug)
    }

    func testAnUnplugSeenOnlyAcrossAGapIsALowerBoundAndAsksOnce() {
        XCTAssertEqual(BatteryPeriodTracker.maximumObservationGap, 60)
        launch(on: Fixtures.charging)
        tick()
        let status = tick(after: 3600, on: Fixtures.discharging7W)
        XCTAssertEqual(status?.onBattery?.precision, .lowerBound)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                      DetailRow("Since", "18:46 or earlier")])
        XCTAssertNotNil(monitor.takePowerLogRequest())
        XCTAssertNil(monitor.takePowerLogRequest(), "once per period")
        tick(after: 30)
        XCTAssertNil(monitor.takePowerLogRequest())

        launch(on: Fixtures.charging)
        tick()
        XCTAssertEqual(tick(after: 60, on: Fixtures.discharging7W)?.onBattery?.precision, .exact, "60 s is still watched")
    }

    // MARK: Launch on battery

    /// The first tick of a session that starts after the last battery line of `logOnBattery`
    /// (61 % at 15:41): a charge at or below it, as a battery that kept draining reads.
    private var drainedSinceTheLog: BatterySnapshot {
        var snapshot = Fixtures.discharging7W
        snapshot.currentCapacityPercent = 11
        return snapshot
    }

    func testLaunchOnBatteryShowsTheLowerBoundUntilTheLogRefinesIt() {
        launch(on: drainedSinceTheLog)
        let first = tick()
        XCTAssertEqual(rows(first), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                     DetailRow("Since", "17:46 or earlier")])
        let request = monitor.takePowerLogRequest()
        XCTAssertEqual(request, PowerLogRequest(periodID: 0, sessionBatteryStart: afternoon))

        monitor.applyPowerLog(.summary(logOnBattery), for: request!)
        let refined = tick(after: 6)
        XCTAssertEqual(rows(refined), [DetailRow("On battery for", "5:29", emphasis: .primary),
                                       DetailRow("Since", "12:17, from 100 %")])
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_961_041, percent: 100, precision: .exact))
        XCTAssertNil(monitor.takePowerLogRequest(), "never read again after an answer")
    }

    func testAStoredLiveRecordIsKeptWhenTheLogShowsNoPlugInAfterIt() {
        let live = UnplugRecord(unpluggedAt: 1_938_960_930, percent: 99, precision: .exact)
        launch(stored(unplug: live))
        let first = tick()
        XCTAssertEqual(first?.onBattery?.precision, .lowerBound, "never shown before the log confirms it")
        XCTAssertEqual(store.stored?.unplug, live, "the file keeps it while the log is out")
        monitor.applyPowerLog(.summary(logOnBattery), for: monitor.takePowerLogRequest()!)
        let confirmed = tick(after: 6)
        XCTAssertEqual(rows(confirmed).last, DetailRow("Since", "12:15, from 99 %"))
        XCTAssertEqual(store.stored?.unplug, live)
    }

    /// The same log, but this session's first tick reads 95 %, far above the 61 % the log saw
    /// last: it was charged after that line without the log seeing it, so the log's own start
    /// is no evidence any more.
    func testALogWhoseLastChargeIsBelowTheFirstTickGivesOnlyTheLowerBound() {
        launch()
        tick()
        monitor.applyPowerLog(.summary(logOnBattery), for: monitor.takePowerLogRequest()!)
        XCTAssertEqual(logOnBattery.lastPercent, 61)
        XCTAssertEqual(rows(tick(after: 6)), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                              DetailRow("Since", "17:46 or earlier")])
        XCTAssertEqual(store.stored?.unplug?.precision, .lowerBound)
    }

    func testAStoredRecordBeforeAPlugInIsNeverShown() {
        let old = UnplugRecord(unpluggedAt: 1_938_949_200, percent: 80, precision: .exact)
        launch(stored(unplug: old), on: drainedSinceTheLog)
        tick()
        monitor.applyPowerLog(.summary(logOnBattery), for: monitor.takePowerLogRequest()!)
        let status = tick(after: 6)
        XCTAssertEqual(rows(status).last, DetailRow("Since", "12:17, from 100 %"), "the log saw AC at 12:14 after it")
        XCTAssertEqual(store.stored?.unplug?.unpluggedAt, 1_938_961_041)
    }

    /// A synthetic Assertions line in the measured shape, on 2031-06-11 in New York.
    private func logLine(_ time: String, _ source: String) -> String {
        "2031-06-11 \(time) -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using \(source)          "
    }

    private let bootMarker = "2031-06-11 15:00:00 -0400 Start               \tpowerd process is started"
        + "                                                  \t          "

    private func scan(_ lines: [String]) -> PowerLogSummary {
        var scanner = PowerLogScanner()
        scanner.consume(lines.joined(separator: "\n") + "\n")
        scanner.finish()
        return scanner.summary
    }

    /// The live unplug of an earlier session at 14:02:10 with 90 %.
    private let liveAtTwoPM = UnplugRecord(unpluggedAt: 1_938_967_330, percent: 90, precision: .exact)

    /// Discharging since the unplug at 90 %: 78 % at the launch.
    private var dischargedSinceTwoPM: BatterySnapshot {
        var snapshot = Fixtures.discharging7W
        snapshot.currentCapacityPercent = 78
        return snapshot
    }

    private func launchWithTheLiveRecord(applying summary: PowerLogSummary,
                                         on snapshot: BatterySnapshot? = nil) -> BatteryStatus? {
        launch(stored(unplug: liveAtTwoPM), on: snapshot ?? dischargedSinceTwoPM)
        tick()
        monitor.applyPowerLog(.summary(summary), for: monitor.takePowerLogRequest()!)
        return tick(after: 6)
    }

    func testAStoredRecordIsNeverShownWhenTheLogRestartsThePeriodAfterABoot() {
        // Charged while off: 40 % before the boot, 85 % after it.
        let rise = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 90)"),
                         logLine("14:50:00", "Batt(Charge: 40)"), bootMarker,
                         logLine("15:00:01", "Batt(Charge: 85)")])
        let status = launchWithTheLiveRecord(applying: rise)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "at least 2:46", emphasis: .primary),
                                      DetailRow("Since", "15:00 or earlier")], "never 14:02, from 90 %")
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_970_801, precision: .lowerBound))

        // The charge after the boot is unknown: the scanner restarts the period as well.
        let unknown = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 90)"),
                            bootMarker, logLine("15:00:01", "Batt(Charge:")])
        XCTAssertEqual(rows(launchWithTheLiveRecord(applying: unknown)).last, DetailRow("Since", "15:00 or earlier"))
    }

    func testAStoredRecordIsKeptAcrossABootWithoutARiseInCharge() {
        let noRise = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 90)"),
                           logLine("14:50:00", "Batt(Charge: 80)"), bootMarker,
                           logLine("15:00:01", "Batt(Charge: 79)")])
        let status = launchWithTheLiveRecord(applying: noRise)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "3:44", emphasis: .primary),
                                      DetailRow("Since", "14:02, from 90 %")])
        XCTAssertEqual(store.stored?.unplug, liveAtTwoPM)
    }

    /// Unplugged at 14:02:10, shut down before the log wrote a battery line, charged to 100 %
    /// while off, unplugged again and booted: the log has no battery line before the boot.
    func testAStoredRecordIsNeverShownAcrossABootDirectlyAfterTheLastExternalLine() {
        let summary = scan([logLine("14:00:00", "AC(Charge: 100)"), bootMarker,
                            logLine("15:00:01", "Batt(Charge: 100)")])
        XCTAssertEqual(summary.bracketStart, summary.lastExternalAt, "the old timestamp identity would confirm it")
        XCTAssertTrue(summary.unvettedBootAfterExternal)
        let status = launchWithTheLiveRecord(applying: summary)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "at least 2:46", emphasis: .primary),
                                      DetailRow("Since", "15:00 or earlier")], "never 14:02, from 90 %")
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_970_801, precision: .lowerBound))
    }

    /// The external and the first battery line in the same second before a boot with a rise.
    func testAStoredRecordIsNeverShownWhenTheRestartBracketEqualsTheExternalLine() {
        let summary = scan([logLine("14:02:10", "AC(Charge: 90)"), logLine("14:02:10", "Batt(Charge: 90)"),
                            bootMarker, logLine("15:00:01", "Batt(Charge: 100)")])
        XCTAssertEqual(summary.bracketStart, summary.lastExternalAt, "the old timestamp identity would confirm it")
        XCTAssertTrue(summary.unvettedBootAfterExternal)
        XCTAssertEqual(rows(launchWithTheLiveRecord(applying: summary)).last, DetailRow("Since", "15:00 or earlier"))
    }

    /// The log ends on the boot marker: the period after the boot is unknown to it.
    func testAStoredRecordIsNeverShownWhenTheLogEndsOnABoot() {
        let summary = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 90)"),
                            bootMarker])
        XCTAssertTrue(summary.unvettedBootAfterExternal)
        let status = launchWithTheLiveRecord(applying: summary)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                      DetailRow("Since", "17:46 or earlier")], "only this session's first tick is certain")
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_980_800, precision: .lowerBound))
    }

    /// The first tick of this session reads more than the candidate's charge: it was charged
    /// after the unplug, whatever the log says.
    func testAStoredRecordIsDroppedWhenTheFirstTickReadsAHigherCharge() {
        let noRise = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 90)"),
                           logLine("14:50:00", "Batt(Charge: 80)"), bootMarker,
                           logLine("15:00:01", "Batt(Charge: 79)")])
        XCTAssertFalse(noRise.unvettedBootAfterExternal, "the log alone would confirm it")
        var charged = dischargedSinceTwoPM
        charged.currentCapacityPercent = 91
        launch(stored(unplug: liveAtTwoPM), on: charged)
        tick()
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_980_800, precision: .lowerBound),
                       "the refuted candidate leaves the file at once")
        monitor.applyPowerLog(.summary(noRise), for: monitor.takePowerLogRequest()!)
        let status = tick(after: 6)
        XCTAssertNotEqual(store.stored?.unplug, liveAtTwoPM)
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_980_800, precision: .lowerBound),
                       "the log's own start at 14:02:00 with 90 % is refuted by the same 91 %")
        XCTAssertEqual(rows(status).last, DetailRow("Since", "17:46 or earlier"))
    }

    // MARK: The log's own start

    private func launchOnBattery(at percent: Int, applying summary: PowerLogSummary) -> BatteryStatus? {
        var snapshot = Fixtures.discharging7W
        snapshot.currentCapacityPercent = percent
        launch(on: snapshot)
        tick()
        monitor.applyPowerLog(.summary(summary), for: monitor.takePowerLogRequest()!)
        return tick(after: 6)
    }

    /// The log's exact start is held against this session's first tick like a stored record.
    func testTheLogsOwnStartIsRefutedByAHigherFirstCharge() {
        let log = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 90)"),
                        logLine("14:50:00", "Batt(Charge: 80)")])
        XCTAssertEqual(log.precision, .exact)
        XCTAssertEqual(rows(launchOnBattery(at: 78, applying: log)).last, DetailRow("Since", "14:02, from 90 %"))
        XCTAssertEqual(log.lastPercent, 80)
        XCTAssertEqual(rows(launchOnBattery(at: 80, applying: log)).last, DetailRow("Since", "14:02, from 90 %"),
                       "the last charge the log saw, unchanged, refutes nothing")
        let chargedAfterLastLine = launchOnBattery(at: 81, applying: log)
        XCTAssertEqual(rows(chargedAfterLastLine).last, DetailRow("Since", "17:46 or earlier"),
                       "above the log's last 80 % but below its start: charged after 14:50 unseen by the log")
        let charged = launchOnBattery(at: 91, applying: log)
        XCTAssertEqual(rows(charged), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                       DetailRow("Since", "17:46 or earlier")], "charged after 14:02 unseen by the log")
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_980_800, precision: .lowerBound))
    }

    /// An exact bracket without a known charge cannot be held against the first tick.
    func testTheLogsOwnStartWithoutAChargeIsOnlyALowerBound() {
        let log = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:01:00", "Batt(Charge:"),
                        logLine("14:06:01", "Batt(Charge: 97)")])
        XCTAssertEqual(log.precision, .exact)
        XCTAssertNil(log.percent)
        XCTAssertEqual(rows(launchOnBattery(at: 78, applying: log)).last, DetailRow("Since", "14:01 or earlier"))
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_967_260, precision: .lowerBound))
    }

    /// Cut-off charges around a boot shortly after the last line, then 50 %: the unplug may
    /// lie anywhere since 14:02, never an exact 15:00.
    func testARestartAfterABootWithUnknownChargesIsOnlyALowerBound() {
        let log = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:00", "Batt(Charge: 1"),
                        logLine("14:58:00", "Batt(Charge:"), bootMarker, logLine("15:00:01", "Batt(Charge: 50)")])
        XCTAssertEqual(rows(launchOnBattery(at: 45, applying: log)),
                       [DetailRow("On battery for", "at least 2:46", emphasis: .primary),
                        DetailRow("Since", "15:00 or earlier")])
    }

    /// Unplugged at 100 %, charged while off (still 100 %), unplugged again and booted.
    func testAStoredRecordAt100PercentIsNeverConfirmedAcrossABootWithAnUnchangedCharge() {
        let full = UnplugRecord(unpluggedAt: 1_938_967_330, percent: 100, precision: .exact)
        let log = scan([logLine("14:00:00", "AC(Charge: 100)"), logLine("14:02:10", "Batt(Charge: 100)"),
                        logLine("14:50:00", "Batt(Charge: 100)"), bootMarker, logLine("15:00:01", "Batt(Charge: 100)")])
        var snapshot = Fixtures.discharging7W
        snapshot.currentCapacityPercent = 100
        launch(stored(unplug: full), on: snapshot)
        tick()
        monitor.applyPowerLog(.summary(log), for: monitor.takePowerLogRequest()!)
        XCTAssertEqual(rows(tick(after: 6)).last, DetailRow("Since", "15:00 or earlier"), "never 14:02, from 100 %")
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_970_801, precision: .lowerBound))
    }

    func testAStoredRecordIsNeverShownWhenTheLogDoesNotReachBackToAnExternalLine() {
        let batteryOnly = scan([logLine("14:02:00", "Batt(Charge: 90)"), logLine("14:50:00", "Batt(Charge: 80)")])
        XCTAssertNil(batteryOnly.lastExternalAt)
        let status = launchWithTheLiveRecord(applying: batteryOnly)
        XCTAssertEqual(rows(status), [DetailRow("On battery for", "at least 3:44", emphasis: .primary),
                                      DetailRow("Since", "14:02 or earlier")], "the time before the log is unwatched")
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_967_320, precision: .lowerBound))
    }

    func testLaunchOnACClearsAStoredRecord() {
        launch(stored(unplug: UnplugRecord(unpluggedAt: 1_938_961_041, percent: 100, precision: .exact)),
               on: Fixtures.onExternalPowerFull)
        let status = tick()
        XCTAssertNil(status?.onBattery)
        XCTAssertNil(store.stored?.unplug)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertNil(monitor.takePowerLogRequest())
    }

    /// A reboot alone does not invalidate the earlier session's live unplug, and a read that
    /// failed or timed out observed no plug-in.
    func testAFailedLogKeepsTheStoredLiveRecord() {
        let live = UnplugRecord(unpluggedAt: 1_938_960_930, percent: 99, precision: .exact)
        launch(stored(unplug: live, bootTime: Fixtures.bootTime.timeIntervalSince1970 - 3600))
        tick()
        monitor.applyPowerLog(.failed, for: monitor.takePowerLogRequest()!)
        XCTAssertEqual(rows(tick(after: 6)), [DetailRow("On battery for", "5:31", emphasis: .primary),
                                              DetailRow("Since", "12:15, from 99 %")])
        XCTAssertEqual(store.stored?.unplug, live)
        XCTAssertNil(monitor.takePowerLogRequest())
    }

    /// A stored record at 100 %: a charge while off cannot show up as a higher first tick, so
    /// a failed read keeps nothing and shows the honest lower bound.
    func testAFailedLogDoesNotKeepAStoredRecordAtAFullBattery() {
        let full = UnplugRecord(unpluggedAt: 1_938_960_930, percent: 100, precision: .exact)
        let unknown = UnplugRecord(unpluggedAt: 1_938_960_930, precision: .exact)
        for record in [full, unknown] {
            launch(stored(unplug: record, bootTime: Fixtures.bootTime.timeIntervalSince1970 - 3600))
            tick()
            monitor.applyPowerLog(.failed, for: monitor.takePowerLogRequest()!)
            XCTAssertEqual(rows(tick(after: 6)), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                                  DetailRow("Since", "17:46 or earlier")], "\(record)")
            XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_980_800, precision: .lowerBound))
        }
        XCTAssertFalse(BatteryPeriodTracker.counterSignalCanFire(for: full))
        XCTAssertTrue(BatteryPeriodTracker.counterSignalCanFire(
            for: UnplugRecord(unpluggedAt: 0, percent: 99, precision: .exact)))
    }

    /// The first tick reads 95 %, more than the 90 % at the stored unplug: it was charged since.
    func testAFailedLogNeverShowsAStoredRecordTheFirstTickRefuted() {
        let refuted = UnplugRecord(unpluggedAt: 1_938_960_930, percent: 90, precision: .exact)
        launch(stored(unplug: refuted))
        tick()
        monitor.applyPowerLog(.failed, for: monitor.takePowerLogRequest()!)
        XCTAssertEqual(rows(tick(after: 6)), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                              DetailRow("Since", "17:46 or earlier")])
        XCTAssertEqual(store.stored?.unplug, UnplugRecord(unpluggedAt: 1_938_980_800, precision: .lowerBound))
    }

    func testAFailedReadWithoutAStoredRecordOrAStaleLogKeepsTheHonestLowerBound() {
        let live = stored(unplug: UnplugRecord(unpluggedAt: 1_938_960_930, percent: 99, precision: .exact))
        let cases: [(PowerLogOutcome, StoredStatistics?)] = [
            (.failed, nil), (.summary(logAfterPlugIn), live), (.summary(PowerLogSummary()), live),
        ]
        for (outcome, stored) in cases {
            launch(stored)
            tick()
            monitor.applyPowerLog(outcome, for: monitor.takePowerLogRequest()!)
            let status = tick(after: 6)
            XCTAssertEqual(rows(status), [DetailRow("On battery for", "at least 0:00", emphasis: .primary),
                                          DetailRow("Since", "17:46 or earlier")], "\(outcome)")
            XCTAssertEqual(store.stored?.unplug,
                           UnplugRecord(unpluggedAt: afternoon.timeIntervalSince1970, precision: .lowerBound),
                           "never the stored value after \(outcome)")
            XCTAssertNil(monitor.takePowerLogRequest())
        }
    }

    func testAnAnswerForAnEndedPeriodIsIgnored() {
        launch()
        tick()
        let request = monitor.takePowerLogRequest()!
        tick(after: 30, on: Fixtures.charging)
        monitor.applyPowerLog(.summary(logOnBattery), for: request)
        XCTAssertNil(tick(after: 1)?.onBattery)
        let unplugged = tick(after: 2, on: Fixtures.discharging7W)
        monitor.applyPowerLog(.summary(logOnBattery), for: request)
        XCTAssertEqual(tick(after: 1)?.onBattery?.since, unplugged?.onBattery?.since, "the live unplug stands")
        XCTAssertEqual(tick()?.onBattery?.percentAtUnplug, 95)
    }

    func testManyTicksAskOnlyOnce() {
        launch()
        var requests = 0
        for _ in 0..<10 {
            tick(after: 30)
            if monitor.takePowerLogRequest() != nil {
                requests += 1
            }
        }
        XCTAssertEqual(requests, 1)
    }

    func testAPlugInWhileTheLogIsReadIsTakenFromTheLog() {
        launch(at: Date(timeIntervalSince1970: 1_938_960_840))
        tick()
        let request = monitor.takePowerLogRequest()!
        wallClock.now = afternoon
        monitor.applyPowerLog(.summary(logOnBattery), for: request)
        XCTAssertEqual(tick()?.onBattery?.since, Date(timeIntervalSince1970: 1_938_961_041),
                       "the log saw AC at 12:14:45, after the first battery tick at 12:14:00")
    }

    func testAChargeThatRoseAcrossAGapIsAnUnwatchedPlugIn() {
        launch(on: Fixtures.charging)
        tick()
        var low = Fixtures.discharging7W
        low.currentCapacityPercent = 40
        XCTAssertEqual(tick(after: 2, on: low)?.onBattery?.precision, .exact)
        XCTAssertNil(monitor.takePowerLogRequest())
        let morning = tick(after: 8 * 3600, on: Fixtures.discharging7W)
        XCTAssertEqual(morning?.onBattery?.precision, .lowerBound, "charged from 40 to 95 % while asleep")
        XCTAssertEqual(morning?.onBattery?.since, wallClock.now)
        XCTAssertNotNil(monitor.takePowerLogRequest())

        launch(on: Fixtures.charging)
        tick()
        tick(after: 2, on: Fixtures.discharging7W)
        XCTAssertEqual(tick(after: 8 * 3600, on: low)?.onBattery?.precision, .exact, "a falling charge is the same period")
        XCTAssertNil(monitor.takePowerLogRequest())
    }

    // MARK: File

    func testARebootKeepsTheRecordButNotTheEstimators() {
        let live = UnplugRecord(unpluggedAt: 1_938_960_930, percent: 99, precision: .exact)
        let estimator = StoredEstimatorState(smoothedWatts: 7.5, observedSeconds: 3600, sampleCount: 40,
                                             lastSampleAt: afternoon.timeIntervalSince1970 - 120)
        launch(stored(unplug: live, bootTime: Fixtures.bootTime.timeIntervalSince1970 - 3600,
                      estimators: ["discharging": estimator]))
        XCTAssertEqual(tick()?.estimate?.sampleCount, 1, "the estimator is gone after the reboot")
        XCTAssertEqual(store.stored?.unplug, live, "the wall clock still holds")
        XCTAssertEqual(store.stored?.bootTime, Fixtures.bootTime.timeIntervalSince1970)
        monitor.applyPowerLog(.summary(logOnBattery), for: monitor.takePowerLogRequest()!)
        XCTAssertEqual(tick(after: 6)?.onBattery?.percentAtUnplug, 99)
    }

    func testARecordInTheFutureIsDropped() {
        XCTAssertEqual(UnplugRecord.futureTolerance, 60)
        let now = afternoon.timeIntervalSince1970
        let far = UnplugRecord(unpluggedAt: now + 61, percent: 99, precision: .exact)
        let near = UnplugRecord(unpluggedAt: now + 60, percent: 99, precision: .exact)
        let memory = { (record: UnplugRecord) in
            EnergyMemory(store: MemoryStatisticsStore(self.stored(unplug: record)),
                         wallClock: ManualWallClock(now: self.afternoon), calendar: Fixtures.newYork)
        }
        XCTAssertNil(memory(far).unplug, "a clock that was set back")
        XCTAssertEqual(memory(near).unplug, near)
        XCTAssertFalse(far.isPlausible(now: afternoon))
        XCTAssertTrue(near.isPlausible(now: afternoon))

        // Set back during the session: only the present is certain.
        launch(on: Fixtures.charging)
        tick()
        tick(after: 2, on: Fixtures.discharging7W)
        wallClock.advance(by: -3600)
        let back = tick(after: 30)
        XCTAssertEqual(back?.onBattery?.precision, .lowerBound)
        XCTAssertEqual(back?.onBattery?.since, wallClock.now)
    }
}
