import XCTest
@testable import RestwattCore

/// The pure parts of the memory: the staleness rule, the day statistic and the file format.
final class EnergyStatisticsTests: XCTestCase {
    private let now = Fixtures.wallNow
    private let boot = Fixtures.bootTime

    private func state(observed: TimeInterval, gap: TimeInterval, watts: Double = 7.5, count: Int = 40) -> StoredEstimatorState {
        StoredEstimatorState(smoothedWatts: watts, observedSeconds: observed, sampleCount: count,
                             lastSampleAt: now.timeIntervalSince1970 - gap)
    }

    // MARK: Staleness rule (AC2)

    func testFreshEntryIsResumedAsIs() {
        let memory = state(observed: 2400, gap: 0).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot)
        XCTAssertEqual(memory, EnergyFlowEstimator.Memory(smoothedWatts: 7.5, observedSeconds: 2400, sampleCount: 40))
    }

    func testRememberedWindowIsCappedWhereTauStopsGrowing() {
        let memory = state(observed: 28800, gap: 0).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot)
        XCTAssertEqual(memory?.observedSeconds, 3600)
        XCTAssertEqual(memory?.sampleCount, 40)
    }

    func testPauseEatsTheWindowSecondForSecond() {
        let afterLongPause = state(observed: 3600, gap: 2700).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot)
        XCTAssertEqual(afterLongPause?.observedSeconds, 900)
        XCTAssertEqual(afterLongPause.map { EnergyFlowEstimator.confidence(observedSeconds: $0.observedSeconds) }, .medium)
        XCTAssertEqual(afterLongPause?.smoothedWatts, 7.5, "the power itself is kept, only the trust in it shrinks")

        let afterShortPause = state(observed: 1800, gap: 600).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot)
        XCTAssertEqual(afterShortPause?.observedSeconds, 1200)

        let restartAfterSeconds = state(observed: 900, gap: 3).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot)
        XCTAssertEqual(restartAfterSeconds?.observedSeconds, 897, "a quick restart keeps practically everything")
    }

    func testPauseAsLongAsTheWindowForgetsIt() {
        XCTAssertNil(state(observed: 3600, gap: 3600).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot))
        XCTAssertNil(state(observed: 3600, gap: 3601).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot))
        XCTAssertNil(state(observed: 28800, gap: 3600).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot),
            "a whole day of observation still does not survive an hour of pause")
        XCTAssertNil(state(observed: 600, gap: 700).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot))
    }

    func testClockThatRanBackwardsForgetsIt() {
        XCTAssertNil(state(observed: 3600, gap: -1).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: boot))
    }

    func testRebootForgetsItWithinTheTolerance() {
        let stored = boot.timeIntervalSince1970
        XCTAssertNil(state(observed: 3600, gap: 120).resumable(
            now: now, storedBootTime: stored, currentBootTime: boot.addingTimeInterval(61)))
        XCTAssertNil(state(observed: 3600, gap: 120).resumable(
            now: now, storedBootTime: stored, currentBootTime: boot.addingTimeInterval(-61)))
        XCTAssertEqual(state(observed: 3600, gap: 120).resumable(
            now: now, storedBootTime: stored, currentBootTime: boot.addingTimeInterval(59))?.observedSeconds, 3480,
            "a boot time that merely jitters is the same boot")
        XCTAssertEqual(StoredStatistics.bootTimeTolerance, 60)
    }

    func testUnknownBootTimeOnEitherSideLeavesTheGapToDecide() {
        XCTAssertEqual(state(observed: 3600, gap: 120).resumable(
            now: now, storedBootTime: nil, currentBootTime: boot)?.observedSeconds, 3480)
        XCTAssertEqual(state(observed: 3600, gap: 120).resumable(
            now: now, storedBootTime: boot.timeIntervalSince1970, currentBootTime: nil)?.observedSeconds, 3480)
        XCTAssertNil(state(observed: 3600, gap: 3600).resumable(
            now: now, storedBootTime: nil, currentBootTime: nil))
    }

    func testCorruptEntryIsNotResumed() {
        XCTAssertNil(state(observed: 3600, gap: 0, watts: 0).resumable(
            now: now, storedBootTime: nil, currentBootTime: nil), "a missing smoothedWatts decodes to 0")
        XCTAssertNil(state(observed: 3600, gap: 0, watts: -7).resumable(
            now: now, storedBootTime: nil, currentBootTime: nil))
        XCTAssertNil(state(observed: 3600, gap: 0, count: 0).resumable(
            now: now, storedBootTime: nil, currentBootTime: nil))
    }

    // MARK: Day statistic (AC4)

    private let interval = [
        ProcessEnergyEntry(name: "Discord Helper (Renderer)", watts: 0.416, cpuShare: 0.3, processCount: 2),
        ProcessEnergyEntry(name: "Restwatt", watts: 0.01, cpuShare: 0.001, processCount: 1),
    ]

    func testRecordAddsWattHoursAndSampledSeconds() {
        var day = DailyEnergyStatistic(day: "2026-09-22")
        day.record(interval, dt: 3600)
        XCTAssertEqual(day.entries.first, DailyEnergyEntry(name: "Discord Helper (Renderer)", wattHours: 0.416))
        XCTAssertEqual(day.entries.last!.wattHours, 0.01, accuracy: 1e-12)
        XCTAssertEqual(day.sampledSeconds, 3600)
        day.record(interval, dt: 3600)
        XCTAssertEqual(day.entries.first!.wattHours, 0.832, accuracy: 1e-12)
        XCTAssertEqual(day.sampledSeconds, 7200)
        XCTAssertEqual(day.totalWattHours, 0.852, accuracy: 1e-12)
        XCTAssertEqual(day.otherWattHours, 0)

        day.record(interval, dt: 0)
        XCTAssertEqual(day.sampledSeconds, 7200, "an empty interval counts nothing")
    }

    func testEntriesAreSortedByEnergyThenName() {
        var day = DailyEnergyStatistic(day: "2026-09-22")
        day.record([
            ProcessEnergyEntry(name: "b", watts: 1, cpuShare: 0, processCount: 1),
            ProcessEnergyEntry(name: "a", watts: 1, cpuShare: 0, processCount: 1),
            ProcessEnergyEntry(name: "c", watts: 2, cpuShare: 0, processCount: 1),
        ], dt: 3600)
        XCTAssertEqual(day.entries.map(\.name), ["c", "a", "b"])
    }

    func testEvictionKeepsTheLargestNamesAndTheTotal() {
        var day = DailyEnergyStatistic(day: "2026-09-22")
        let names = (1...25).map { ProcessEnergyEntry(name: String(format: "p%02d", $0), watts: Double($0), cpuShare: 0, processCount: 1) }
        day.record(names, dt: 3600)
        XCTAssertEqual(day.entries.count, DailyEnergyStatistic.maximumNames)
        XCTAssertEqual(DailyEnergyStatistic.maximumNames, 20)
        XCTAssertEqual(day.entries.first?.name, "p25")
        XCTAssertEqual(day.entries.last?.name, "p06")
        XCTAssertEqual(day.otherWattHours, 1 + 2 + 3 + 4 + 5, accuracy: 1e-9, "the five smallest fold into other")
        XCTAssertEqual(day.totalWattHours, Double((1...25).reduce(0, +)), accuracy: 1e-9)

        // An evicted name that grows later starts from zero again; its earlier energy stays in other.
        day.record([ProcessEnergyEntry(name: "p01", watts: 30, cpuShare: 0, processCount: 1)], dt: 3600)
        XCTAssertEqual(day.entries.first, DailyEnergyEntry(name: "p01", wattHours: 30))
        XCTAssertEqual(day.entries.count, 20)
        XCTAssertEqual(day.otherWattHours, 15 + 6, accuracy: 1e-9, "p06 is now the smallest and folds in")
        XCTAssertEqual(day.totalWattHours, 325 + 30, accuracy: 1e-9)
    }

    func testDayKeyIsZeroPaddedInTheInjectedZone() {
        let january = Fixtures.utc.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 12))!
        XCTAssertEqual(DailyEnergyStatistic.dayKey(for: january, calendar: Fixtures.utc), "2026-01-05")
        // 03:30 UTC on the 23rd is still the 22nd in New York.
        let lateEvening = Fixtures.utc.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 3, minute: 30))!
        XCTAssertEqual(DailyEnergyStatistic.dayKey(for: lateEvening, calendar: Fixtures.newYork), "2026-09-22")
        XCTAssertEqual(DailyEnergyStatistic.dayKey(for: lateEvening, calendar: Fixtures.utc), "2026-09-23")
    }

    func testDayRollsOverAtLocalMidnight() {
        let store = MemoryStatisticsStore()
        let clock = ManualWallClock(now: Fixtures.newYork.date(
            from: DateComponents(year: 2026, month: 9, day: 22, hour: 23, minute: 59, second: 30))!)
        let memory = EnergyMemory(store: store, wallClock: clock, calendar: Fixtures.newYork)
        memory.record(interval, dt: 30)
        XCTAssertEqual(memory.today?.day, "2026-09-22")
        XCTAssertEqual(memory.today?.sampledSeconds, 30)

        clock.advance(by: 60)
        memory.record([ProcessEnergyEntry(name: "node", watts: 1, cpuShare: 0, processCount: 1)], dt: 60)
        let next = memory.today!
        XCTAssertEqual(next.day, "2026-09-23")
        XCTAssertEqual(next.entries.map(\.name), ["node"], "the interval spanning midnight counts to the new day only")
        XCTAssertEqual(next.sampledSeconds, 60)

        // Same instants in UTC: it is 03:59 on the 23rd already, so nothing rolls over.
        let utcStore = MemoryStatisticsStore()
        let utcClock = ManualWallClock(now: clock.now.addingTimeInterval(-60))
        let utcMemory = EnergyMemory(store: utcStore, wallClock: utcClock, calendar: Fixtures.utc)
        utcMemory.record(interval, dt: 30)
        utcClock.advance(by: 60)
        utcMemory.record(interval, dt: 60)
        XCTAssertEqual(utcMemory.today?.day, "2026-09-23")
        XCTAssertEqual(utcMemory.today?.sampledSeconds, 90)
    }

    func testYesterdaysStatisticIsNotShownAsToday() {
        var yesterday = Fixtures.todayStatistic
        yesterday.day = "2026-09-21"
        let memory = EnergyMemory(
            store: MemoryStatisticsStore(StoredStatistics(today: yesterday)),
            wallClock: ManualWallClock(), calendar: Fixtures.newYork)
        XCTAssertNil(memory.today)
        let sameDay = EnergyMemory(
            store: MemoryStatisticsStore(StoredStatistics(today: Fixtures.todayStatistic)),
            wallClock: ManualWallClock(), calendar: Fixtures.newYork)
        XCTAssertEqual(sameDay.today, Fixtures.todayStatistic, "a stored statistic of the current day shows from the first tick")
    }

    // MARK: Codec (AC6, N8)

    private var fullDocument: StoredStatistics {
        StoredStatistics(
            bootTime: boot.timeIntervalSince1970,
            savedAt: now.timeIntervalSince1970 + 30,
            estimators: [
                "discharging": StoredEstimatorState(smoothedWatts: 7.5, observedSeconds: 3600, sampleCount: 61,
                                                    lastSampleAt: now.timeIntervalSince1970),
                "drainingOnExternalPower": StoredEstimatorState(smoothedWatts: 2.266, observedSeconds: 120, sampleCount: 3,
                                                                lastSampleAt: now.timeIntervalSince1970 - 7200),
                "charging": StoredEstimatorState(smoothedWatts: 49.1, observedSeconds: 720, sampleCount: 13,
                                                 lastSampleAt: now.timeIntervalSince1970 - 600),
            ],
            today: Fixtures.todayStatistic)
    }

    func testCodecRoundTrip() {
        XCTAssertEqual(StatisticsCodec.decode(StatisticsCodec.encode(fullDocument)), fullDocument)
        XCTAssertEqual(StatisticsCodec.decode(StatisticsCodec.encode(StoredStatistics())), StoredStatistics())
    }

    func testEncodingIsDeterministicAndReadable() {
        let small = StoredStatistics(
            bootTime: 1_789_998_856, savedAt: 1_790_064_030,
            estimators: ["charging": StoredEstimatorState(smoothedWatts: 49.1, observedSeconds: 720, sampleCount: 13,
                                                          lastSampleAt: 1_790_064_000)],
            today: DailyEnergyStatistic(
                day: "2026-09-22",
                entries: [DailyEnergyEntry(name: "Discord Helper (Renderer)", wattHours: 1.02),
                          DailyEnergyEntry(name: "node", wattHours: 0.31)],
                otherWattHours: 0.4, sampledSeconds: 15120))
        let text = String(decoding: StatisticsCodec.encode(small), as: UTF8.self)
        XCTAssertEqual(text, """
        {"bootTime":1789998856,"estimators":{"charging":{"lastSampleAt":1790064000,"observedSeconds":720,\
        "sampleCount":13,"smoothedWatts":49.1}},"savedAt":1790064030,"today":{"day":"2026-09-22",\
        "entries":[{"name":"Discord Helper (Renderer)","wattHours":1.02},{"name":"node","wattHours":0.31}],\
        "otherWattHours":0.4,"sampledSeconds":15120},"version":1}
        """)
        XCTAssertEqual(StatisticsCodec.encode(small), StatisticsCodec.encode(small))
    }

    func testUnknownKeysAreIgnoredAndMissingKeysMeanDefaults() {
        let json = """
        {"version":1,"future":42,"estimators":{"charging":{"smoothedWatts":49.1,"observedSeconds":720,"sampleCount":13,\
        "lastSampleAt":1790064000,"extra":true},"unknownState":{"smoothedWatts":1}},\
        "today":{"day":"2026-09-22","entries":[{"name":"node","wattHours":0.31,"joules":7},{"wattHours":1}],"more":1}}
        """
        let decoded = StatisticsCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.estimators["charging"],
                       StoredEstimatorState(smoothedWatts: 49.1, observedSeconds: 720, sampleCount: 13, lastSampleAt: 1_790_064_000))
        XCTAssertNil(decoded.estimators["unknownState"], "a key no PowerState uses is dropped, not passed through")
        XCTAssertEqual(decoded.estimators.count, 1)
        XCTAssertEqual(decoded.today, DailyEnergyStatistic(day: "2026-09-22", entries: [DailyEnergyEntry(name: "node", wattHours: 0.31)]))
        XCTAssertNil(decoded.bootTime)
        XCTAssertNil(decoded.savedAt)

        XCTAssertEqual(StatisticsCodec.decode(Data("{}".utf8)), StoredStatistics())
        XCTAssertEqual(StatisticsCodec.decode(Data("{\"today\":{\"entries\":[]}}".utf8)).today, nil, "a day without a date is no day")
    }

    // MARK: Validation at the boundary (t9)

    func testTheCeilingsAreGenerousPhysicalMaxima() {
        XCTAssertEqual(StoredEstimatorState.maximumSmoothedWatts, 1000)
        XCTAssertEqual(StoredEstimatorState.maximumObservedSeconds, 366 * 86400)
        XCTAssertEqual(StoredEstimatorState.maximumSampleCount, 366 * 86400)
        XCTAssertEqual(DailyEnergyStatistic.maximumWattHours, 24000)
        XCTAssertEqual(DailyEnergyStatistic.maximumSampledSeconds, 7 * 86400)
        XCTAssertEqual(PowerState.memoryKeys, ["discharging", "drainingOnExternalPower", "charging"])
    }

    func testAbsurdEstimatorEntriesAreDroppedOneByOne() {
        let json = """
        {"version":1,"estimators":{\
        "charging":{"smoothedWatts":49.1,"observedSeconds":720,"sampleCount":13,"lastSampleAt":1790064000},\
        "discharging":{"smoothedWatts":-7.5,"observedSeconds":720,"sampleCount":13,"lastSampleAt":1790064000},\
        "drainingOnExternalPower":{"smoothedWatts":2.2,"observedSeconds":720,"sampleCount":9223372036854775807,"lastSampleAt":1790064000}}}
        """
        let decoded = StatisticsCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.estimators.keys.sorted(), ["charging"], "negative watts and Int.max samples are not measurements")

        var entry = StoredEstimatorState(smoothedWatts: 7.5, observedSeconds: 3600, sampleCount: 61, lastSampleAt: 1_790_064_000)
        XCTAssertTrue(entry.isPlausible)
        entry.smoothedWatts = 1000.5
        XCTAssertFalse(entry.isPlausible, "beyond the largest adapter")
        entry.smoothedWatts = 0
        XCTAssertTrue(entry.isPlausible, "zero is a value the staleness rule refuses on its own")
        entry.observedSeconds = 5.5e20
        XCTAssertFalse(entry.isPlausible)
        entry.observedSeconds = -1
        XCTAssertFalse(entry.isPlausible)
        entry.observedSeconds = 0
        entry.sampleCount = -1
        XCTAssertFalse(entry.isPlausible)
        entry.sampleCount = 0
        entry.lastSampleAt = -1
        XCTAssertFalse(entry.isPlausible, "no tick before 1970")
        entry.lastSampleAt = .infinity
        XCTAssertFalse(entry.isPlausible)
        entry.lastSampleAt = .nan
        XCTAssertFalse(entry.isPlausible)
    }

    func testAbsurdDayFiguresAreDroppedAtDecode() {
        // Two absurd names among sane ones: only they go; the day itself stays.
        let names = """
        {"today":{"day":"2026-09-22","entries":[{"name":"node","wattHours":0.31},{"name":"huge","wattHours":-9.2e15},\
        {"name":"vast","wattHours":1e300},{"name":"Restwatt","wattHours":0.012}],"otherWattHours":0.4,"sampledSeconds":15120}}
        """
        let day = StatisticsCodec.decode(Data(names.utf8)).today
        XCTAssertEqual(day?.entries, [DailyEnergyEntry(name: "node", wattHours: 0.31), DailyEnergyEntry(name: "Restwatt", wattHours: 0.012)])
        XCTAssertEqual(day?.otherWattHours, 0.4)

        // The day's own figures decide the whole day.
        for broken in [
            "{\"today\":{\"day\":\"2026-09-22\",\"sampledSeconds\":5.5e20}}",
            "{\"today\":{\"day\":\"2026-09-22\",\"sampledSeconds\":-30}}",
            "{\"today\":{\"day\":\"2026-09-22\",\"otherWattHours\":-1}}",
            "{\"today\":{\"day\":\"2026-09-22\",\"otherWattHours\":1e300}}",
            "{\"today\":{\"day\":\"yesterday\",\"sampledSeconds\":30}}",
            "{\"today\":{\"day\":\"2026-9-22\",\"sampledSeconds\":30}}",
            "{\"today\":{\"day\":\"2026-09-22T00\",\"sampledSeconds\":30}}",
            "{\"today\":{\"day\":\"٢٠٢٦-09-22\",\"sampledSeconds\":30}}",
        ] {
            XCTAssertNil(StatisticsCodec.decode(Data(broken.utf8)).today, broken)
        }
        XCTAssertTrue(DailyEnergyStatistic.isDayKey("2026-09-22"))
        XCTAssertTrue(DailyEnergyStatistic.isDayKey("0000-00-00"), "the shape is checked, not the calendar")
        XCTAssertFalse(DailyEnergyStatistic.isDayKey("2026/09/22"))
        XCTAssertFalse(DailyEnergyStatistic.isDayKey(""))
    }

    func testMoreNamesThanTheCapAreFoldedAtDecodeAsRecordWouldFoldThem() {
        let entries = (1...25).map { "{\"name\":\"p\($0 < 10 ? "0" : "")\($0)\",\"wattHours\":\($0)}" }.joined(separator: ",")
        let json = "{\"today\":{\"day\":\"2026-09-22\",\"entries\":[\(entries)],\"otherWattHours\":1,\"sampledSeconds\":3600}}"
        let day = StatisticsCodec.decode(Data(json.utf8)).today!
        XCTAssertEqual(day.entries.count, DailyEnergyStatistic.maximumNames)
        XCTAssertEqual(day.entries.first, DailyEnergyEntry(name: "p25", wattHours: 25))
        XCTAssertEqual(day.entries.last, DailyEnergyEntry(name: "p06", wattHours: 6))
        XCTAssertEqual(day.otherWattHours, 1 + 1 + 2 + 3 + 4 + 5, accuracy: 1e-9, "the five smallest fold into other")
        XCTAssertEqual(day.totalWattHours, 1 + Double((1...25).reduce(0, +)), accuracy: 1e-9, "the total survives the fold")

        // Twenty names in file order survive untouched apart from the sort.
        let twenty = fullDocument
        XCTAssertEqual(StatisticsCodec.decode(StatisticsCodec.encode(twenty)).today, twenty.today)
    }

    func testANewerFormatIsUnreadableAndNeverOverwritten() {
        let json = """
        {"version":2,"bootTime":1789998856,"estimators":{"charging":{"smoothedWatts":49.1,"observedSeconds":720,\
        "sampleCount":13,"lastSampleAt":1790064000}},"today":{"day":"2026-09-22","sampledSeconds":30}}
        """
        let decoded = StatisticsCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded, StoredStatistics(version: 2), "nothing of a newer file is read, only its version")
        XCTAssertTrue(decoded.isNewerFormat)
        XCTAssertFalse(StoredStatistics().isNewerFormat)
        XCTAssertFalse(StoredStatistics(version: 0).isNewerFormat, "an older number reads as the current format")

        let store = MemoryStatisticsStore(decoded)
        let memory = EnergyMemory(store: store, wallClock: ManualWallClock(), calendar: Fixtures.newYork)
        memory.record(interval, dt: 30)
        var estimator = EnergyFlowEstimator()
        estimator.add(time: 0, energyWattHours: 60, watts: 7.5)
        memory.remember(estimator, for: "discharging")
        XCTAssertEqual(memory.today?.sampledSeconds, 30, "the session still keeps its statistic in memory")
        XCTAssertEqual(memory.resume("discharging").estimate, nil)
        memory.saveIfChanged()
        XCTAssertEqual(store.saveCount, 0, "this app never writes over a newer file")
        XCTAssertEqual(store.stored?.version, 2)
    }

    func testANewerFormatIsRecognisedEvenWhenItChangedAType() {
        for json in ["{\"version\":2,\"estimators\":[1]}", "{\"version\":2.0,\"today\":\"gone\"}", "{\"version\":3.5}"] {
            let decoded = StatisticsCodec.decode(Data(json.utf8))
            XCTAssertTrue(decoded.isNewerFormat, json)
            XCTAssertEqual(decoded.estimators, [:], json)
            XCTAssertNil(decoded.today, json)
        }
        XCTAssertEqual(StatisticsCodec.decode(Data("{\"version\":\"2\"}".utf8)), StoredStatistics(),
                       "a version that is not a number is no format this app knows; start from zero")
    }

    func testDuplicateAndOverlongNamesAreFoldedOrDroppedAtDecode() {
        let long = String(repeating: "x", count: 300)
        let json = """
        {"today":{"day":"2026-09-22","sampledSeconds":60,"entries":[{"name":"Safari","wattHours":1.0},\
        {"name":"Safari","wattHours":2.0},{"name":"","wattHours":5.0},{"name":"\(long)","wattHours":5.0}]}}
        """
        let day = StatisticsCodec.decode(Data(json.utf8)).today!
        XCTAssertEqual(day.entries, [DailyEnergyEntry(name: "Safari", wattHours: 3.0)],
                       "duplicates are summed as record sums them; empty and overlong names are dropped")
        XCTAssertEqual(day.otherWattHours, 0)
    }

    func testUnreadableDataMeansAStartFromZero() {
        for garbage in ["not json", "", "[1,2]", "{\"estimators\":[1]}", "{\"today\":\"yesterday\"}"] {
            XCTAssertEqual(StatisticsCodec.decode(Data(garbage.utf8)), StoredStatistics(), garbage)
        }
    }

    func testDocumentedPathMatchesTheCode() {
        XCTAssertEqual(StatisticsStoreLocation.documentedPath, "~/Library/Application Support/Restwatt/statistics.json")
        XCTAssertEqual(StatisticsStoreLocation.fileName, "statistics.json")
        XCTAssertEqual(StatisticsStoreLocation.directoryName, SettingsStoreLocation.directoryName)
        XCTAssertEqual(StoredStatistics.currentVersion, 1)
    }

    // MARK: Size bound (AC6)

    func testTheLargestDocumentStaysWellBelowFourKilobytes() {
        var day = DailyEnergyStatistic(day: "2026-09-22")
        let longNames = (0..<60).map { index in
            ProcessEnergyEntry(name: String(repeating: "x", count: 29) + String(format: "%02d", index),
                               watts: 1234.5678901234567 + Double(index), cpuShare: 0, processCount: 1)
        }
        XCTAssertTrue(longNames.allSatisfy { $0.name.count == 31 })
        day.record(longNames, dt: 3600)
        day.otherWattHours = 123456.78901234567
        day.sampledSeconds = 86399.999
        XCTAssertEqual(day.entries.count, DailyEnergyStatistic.maximumNames)

        let big = StoredEstimatorState(smoothedWatts: 123.45678901234567, observedSeconds: 86399.123456789,
                                       sampleCount: 1_000_000, lastSampleAt: 1_790_064_000.123456)
        let document = StoredStatistics(
            bootTime: 1_789_998_856.123456, savedAt: 1_790_064_030.654321,
            estimators: ["discharging": big, "drainingOnExternalPower": big, "charging": big],
            today: day)
        let size = StatisticsCodec.encode(document).count
        XCTAssertLessThan(size, 4096, "the file is a statistic, not a log")
        XCTAssertGreaterThan(size, 1000, "the document really carries 20 names")
    }
}
