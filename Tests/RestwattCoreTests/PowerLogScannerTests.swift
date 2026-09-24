import XCTest
@testable import RestwattCore

/// The `pmset -g log` scanner against the synthetic excerpt in the measured shape and the
/// cut-off lines it contains.
final class PowerLogScannerTests: XCTestCase {
    private func scan(_ text: String) -> PowerLogSummary {
        var scanner = PowerLogScanner()
        scanner.consume(text)
        scanner.finish()
        return scanner.summary
    }

    private func scan(lines: [String]) -> PowerLogSummary {
        scan(lines.joined(separator: "\n") + "\n")
    }

    private var excerptWithoutPlugIn: [String] {
        Array(Fixtures.powerLogLines.dropLast())
    }

    /// A synthetic Assertions line in the measured shape.
    private func line(_ time: String, _ source: String) -> String {
        "2031-06-11 \(time) -0400 Assertions          \tSummary- [System: PrevIdle PrevDisp DeclUser kDisp] Using \(source)          "
    }

    private let bootMarker = "2031-06-11 15:00:00 -0400 Start               \tpowerd process is started"
        + "                                                  \t          "

    func testExcerptOnBatteryFindsTheUnplugAtTwelveSeventeen() {
        let summary = scan(lines: excerptWithoutPlugIn)
        XCTAssertEqual(summary.lastExternalAt, 1_938_960_885, "12:14:45 -0400, the last AC line")
        XCTAssertEqual(summary.batterySince, 1_938_961_041, "12:17:21 -0400, the first battery line after it")
        XCTAssertEqual(summary.bracketStart, 1_938_960_885)
        XCTAssertEqual(summary.percent, 100)
        XCTAssertEqual(summary.precision, .exact, "a bracket of 156 s")
        XCTAssertTrue(summary.endsOnBattery)
    }

    func testFullExcerptEndsWithThePlugIn() {
        let summary = scan(Fixtures.powerLogExcerpt)
        XCTAssertFalse(summary.endsOnBattery)
        XCTAssertEqual(summary.lastExternalAt, 1_938_981_912, "18:05:12 -0400")
        XCTAssertNil(summary.batterySince)
        XCTAssertNil(summary.percent)
        XCTAssertEqual(summary.precision, .lowerBound)
    }

    func testCutOffLinesNeverInventACharge() {
        let rest = { (line: String) in ArraySlice(Array(line.utf8)[25...]) }
        let cutAC = Fixtures.powerLogLines.first { $0.hasSuffix("Using AC(Char          ") }!
        XCTAssertEqual(PowerLogScanner.source(rest(cutAC))?.onBattery, false, "`Using AC(Char` is still AC")
        XCTAssertNil(PowerLogScanner.source(rest(cutAC))?.charge)
        for cut in Fixtures.powerLogLines where cut.hasSuffix("(Charge: 1          ") || cut.hasSuffix("(Charge:          ") {
            let found = PowerLogScanner.source(rest(cut))
            XCTAssertEqual(found?.onBattery, true, cut)
            XCTAssertNil(found?.charge, "never 1 %: \(cut)")
        }
        // A period that starts on a cut-off line takes its charge from the next complete one.
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 1"),
                                   line("14:03:00", "Batt(Charge: 99)")])
        XCTAssertEqual(summary.batterySince, 1_938_967_320)
        XCTAssertEqual(summary.percent, 99)
    }

    func testAllFiveMeasuredSpellingsAreRecognised() {
        let rest = { (line: String) in ArraySlice(Array(line.utf8)[25...]) }
        let cases: [(String, Bool, Int)] = [
            ("Summary- [System: kDisp] Using Batt(Charge: 100)          ", true, 100),
            ("Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:99%) 2980 secs ", true, 99),
            ("DarkWake from Deep Idle [CDN] : due to rtc/Maintenance Using BATT (Charge:100%) 9 secs    ", true, 100),
            ("Summary- [System: kDisp] Using AC(Charge: 75)          ", false, 75),
            ("DarkWake to FullWake from Deep Idle [CDNVA] : due to Notification Using AC (Charge:100%)           ", false, 100),
        ]
        for (message, onBattery, charge) in cases {
            let full = "2031-06-11 12:00:00 -0400 Assertions          \t" + message
            let found = PowerLogScanner.source(rest(full))
            XCTAssertEqual(found?.onBattery, onBattery, message)
            XCTAssertEqual(found?.charge, charge, message)
        }
    }

    func testMalformedLinesChangeNothing() {
        let clean = scan(lines: excerptWithoutPlugIn)
        let noise = [
            "PM ASL data store: /var/log/powermanagement",
            "==========                ======              \t=======",
            "",
            "UUID: (null)",
            "2031-13-11 12:57:00 -0400 Assertions          \tSummary- Using AC(Charge: 100)",
            "2031-02-30 12:57:00 -0400 Assertions          \tSummary- Using AC(Charge: 100)",
            "2031-06-11 12:57:00 +2500 Assertions          \tSummary- Using AC(Charge: 100)",
            "2031-06-11 12:57 -0400 Assertions          \tSummary- Using AC(Charge: 100)",
            "  continued Using AC(Charge: 100)",
            "2031-06-11 13:00:00 -0400 Assertions          \tPID 568(powerd) Created InternalPreventSleep",
            "2031-06-11 13:00:01 -0400 Assertions          \tSummary- [System: kDisp] Using B",
            "2031-06-11 13:00:02 -0400 Assertions          \tSummary- [System: kDisp] Using",
        ]
        var mixed: [String] = []
        for (index, line) in excerptWithoutPlugIn.enumerated() {
            mixed.append(line)
            mixed.append(noise[index % noise.count])
        }
        XCTAssertEqual(scan(lines: mixed), clean)
        XCTAssertEqual(scan(lines: noise), PowerLogSummary(), "noise alone says nothing")
        let absurd = "2031-06-11 13:00:03 -0400 Assertions          \tSummary- [System: kDisp] Using Batt(Charge: 250)"
        XCTAssertNil(PowerLogScanner.source(ArraySlice(Array(absurd.utf8)[25...]))?.charge, "no charge above 100 %")
    }

    func testTimestampsAreParsedWithoutALocale() {
        XCTAssertEqual(PowerLogScanner.timestamp(Array("2031-06-11 12:14:45 -0400".utf8)), 1_938_960_885)
        XCTAssertEqual(PowerLogScanner.timestamp(Array("2031-06-11 16:14:45 +0000 x".utf8)), 1_938_960_885)
        XCTAssertEqual(PowerLogScanner.timestamp(Array("2031-06-11 21:44:45 +0530\tx".utf8)), 1_938_960_885)
        XCTAssertEqual(PowerLogScanner.timestamp(Array("2024-02-29 00:00:00 +0000".utf8)), 1_709_164_800)
        XCTAssertNil(PowerLogScanner.timestamp(Array("2031-06-11 12:14:45 -0400x".utf8)))
        XCTAssertNil(PowerLogScanner.timestamp(Array("2031-06-11 24:00:00 -0400".utf8)))
        XCTAssertNil(PowerLogScanner.timestamp(Array("2025-02-29 00:00:00 +0000".utf8)))
    }

    func testBootWithoutARiseInChargeKeepsThePeriod() {
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                   line("14:50:00", "Batt(Charge: 80)"), bootMarker,
                                   line("15:00:01", "Batt(Charge: 79)")])
        XCTAssertEqual(summary.batterySince, 1_938_967_320, "14:02:00, across the boot")
        XCTAssertEqual(summary.percent, 90)
        XCTAssertEqual(summary.precision, .exact)
    }

    func testBootWithARiseInChargeStartsAgainAfterIt() {
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                   line("14:50:00", "Batt(Charge: 40)"), bootMarker,
                                   line("15:00:01", "Batt(Charge: 85)")])
        XCTAssertEqual(summary.batterySince, 1_938_970_801, "charged while off: the period starts after the boot")
        XCTAssertEqual(summary.bracketStart, 1_938_970_200, "the last line before the boot, 14:50:00")
        XCTAssertEqual(summary.precision, .lowerBound, "ten minutes of unwatched off time")
        XCTAssertNil(summary.percent, "a charge is only given for an exact start")
    }

    func testBootWithAnUnknownChargeStartsAgainAfterIt() {
        let unknownAfter = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                        bootMarker, line("15:00:01", "Batt(Charge:")])
        XCTAssertEqual(unknownAfter.batterySince, 1_938_970_801, "undecided at the end of the log counts as a restart")
        XCTAssertEqual(unknownAfter.precision, .lowerBound)

        let unknownBefore = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 1"),
                                         bootMarker, line("15:00:01", "Batt(Charge: 50)")])
        XCTAssertEqual(unknownBefore.batterySince, 1_938_970_801)
        XCTAssertNil(unknownBefore.bracketStart, "without a rise nothing says the unplug came after the boot")
    }

    /// Cut-off charges on both sides of a boot shortly after the last line: the unplug may lie
    /// anywhere since 14:02, so the restart after the boot is only a lower bound.
    func testARestartWithoutAKnownRiseIsOnlyALowerBound() {
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 1"),
                                   line("14:58:00", "Batt(Charge:"), bootMarker, line("15:00:01", "Batt(Charge: 50)")])
        XCTAssertEqual(summary.batterySince, 1_938_970_801)
        XCTAssertNil(summary.bracketStart)
        XCTAssertEqual(summary.precision, .lowerBound, "never an exact 15:00")
        XCTAssertNil(summary.percent)
        XCTAssertTrue(summary.unvettedBootAfterExternal)

        let rise = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                line("14:58:00", "Batt(Charge: 40)"), bootMarker, line("15:00:01", "Batt(Charge: 85)")])
        XCTAssertEqual(rise.bracketStart, 1_938_970_680, "charged while off: the unplug lies after 14:58:00")
        XCTAssertEqual(rise.precision, .exact)
        XCTAssertEqual(rise.percent, 85)
    }

    /// At 100 % or at a charge limit the charge reads the same after charging while off.
    func testAnUnchangedChargeAcrossABootVetsNothing() {
        for held in ["100", "80"] {
            let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: \(held))"),
                                       line("14:50:00", "Batt(Charge: \(held))"), bootMarker,
                                       line("15:00:01", "Batt(Charge: \(held))")])
            XCTAssertTrue(summary.unvettedBootAfterExternal, held)
            XCTAssertEqual(summary.batterySince, 1_938_970_801, "never the 14:02 before the boot at \(held) %")
            XCTAssertNil(summary.bracketStart, held)
            XCTAssertEqual(summary.precision, .lowerBound, held)
        }
    }

    func testBootWhileOnACChangesNothing() {
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), bootMarker,
                                   line("15:00:01", "AC(Charge: 100)"), line("15:01:00", "Batt(Charge: 100)")])
        XCTAssertEqual(summary.batterySince, 1_938_970_860)
        XCTAssertEqual(summary.bracketStart, 1_938_970_801)
        XCTAssertEqual(summary.percent, 100)
        XCTAssertEqual(summary.precision, .exact)
    }

    func testOnlyAVettedBootKeepsTheLogContinuousSinceTheExternalLine() {
        let plain = scan(lines: excerptWithoutPlugIn)
        XCTAssertFalse(plain.unvettedBootAfterExternal, "the excerpt's only boot lies before its last AC line")
        let vetted = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                  bootMarker, line("15:00:01", "Batt(Charge: 89)")])
        XCTAssertFalse(vetted.unvettedBootAfterExternal)
        let rise = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                bootMarker, line("15:00:01", "Batt(Charge: 95)")])
        XCTAssertTrue(rise.unvettedBootAfterExternal)
        let unknown = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                   bootMarker, line("15:00:01", "Batt(Charge:")])
        XCTAssertTrue(unknown.unvettedBootAfterExternal)
        let seenAfter = scan(lines: [line("14:00:00", "AC(Charge: 100)"), bootMarker,
                                     line("15:00:01", "AC(Charge: 100)"), line("15:01:00", "Batt(Charge: 100)")])
        XCTAssertFalse(seenAfter.unvettedBootAfterExternal, "an external line after the boot starts afresh")
    }

    func testABootDirectlyAfterTheExternalLineIsUnvetted() {
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), bootMarker,
                                   line("15:00:01", "Batt(Charge: 100)")])
        XCTAssertTrue(summary.unvettedBootAfterExternal, "no battery line before the boot to vet it against")
        XCTAssertEqual(summary.batterySince, 1_938_970_801)
        XCTAssertEqual(summary.bracketStart, 1_938_967_200, "the unplug still lies between 14:00:00 and 15:00:01")
        XCTAssertEqual(summary.precision, .lowerBound)
        XCTAssertNil(summary.percent)
    }

    func testARestartInTheSameSecondAsTheExternalLineIsUnvetted() {
        let summary = scan(lines: [line("14:02:10", "AC(Charge: 90)"), line("14:02:10", "Batt(Charge: 90)"),
                                   bootMarker, line("15:00:01", "Batt(Charge: 100)")])
        XCTAssertEqual(summary.bracketStart, summary.lastExternalAt)
        XCTAssertTrue(summary.unvettedBootAfterExternal)
    }

    func testALogEndingOnABootKnowsNoCurrentPeriod() {
        let summary = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:02:00", "Batt(Charge: 90)"),
                                   bootMarker])
        XCTAssertTrue(summary.endsOnBattery)
        XCTAssertTrue(summary.unvettedBootAfterExternal)
        XCTAssertNil(summary.batterySince, "nothing after the boot says when the current period began")
        XCTAssertNil(summary.bracketStart)
        XCTAssertNil(summary.percent)
    }

    func testNoACLineIsOnlyALowerBound() {
        let summary = scan(lines: [line("14:02:00", "Batt(Charge: 90)"), line("14:10:00", "Batt(Charge: 88)")])
        XCTAssertTrue(summary.endsOnBattery)
        XCTAssertEqual(summary.batterySince, 1_938_967_320)
        XCTAssertNil(summary.bracketStart)
        XCTAssertEqual(summary.precision, .lowerBound, "the log may begin in the middle of the period")
    }

    func testTheBracketIsExactUpToFiveMinutes() {
        XCTAssertEqual(PowerLog.preciseBracket, 300)
        let exact = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:05:00", "Batt(Charge: 100)")])
        XCTAssertEqual(exact.precision, .exact)
        XCTAssertEqual(exact.percent, 100)
        let wide = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:05:01", "Batt(Charge: 100)")])
        XCTAssertEqual(wide.precision, .lowerBound)
        XCTAssertEqual(wide.batterySince, 1_938_967_501, "the shown start is the first battery line either way")

        let lateCharge = scan(lines: [line("14:00:00", "AC(Charge: 100)"), line("14:01:00", "Batt(Charge:"),
                                      line("14:06:01", "Batt(Charge: 97)")])
        XCTAssertNil(lateCharge.percent, "a charge read more than five minutes after the start is not the unplug charge")
    }

    func testChunkBoundariesDoNotMatter() {
        let whole = scan(lines: excerptWithoutPlugIn)
        let text = excerptWithoutPlugIn.joined(separator: "\n")
        for size in [1, 7, 4096] {
            var scanner = PowerLogScanner()
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
                scanner.consume(String(text[index..<end]))
                index = end
            }
            scanner.finish()
            XCTAssertEqual(scanner.summary, whole, "chunks of \(size)")
        }
    }

    func testReadTimeout() {
        XCTAssertEqual(PowerLog.readTimeout, 30)
        XCTAssertEqual(PowerLog.killGrace, 2)
        XCTAssertEqual(PowerLog.maximumLineLength, 65_536)
    }

    // MARK: Stream

    private func stream(_ text: String, chunk size: Int) -> PowerLogStream {
        var stream = PowerLogStream()
        let bytes = Data(text.utf8)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = min(index + size, bytes.endIndex)
            stream.consume(bytes[index..<end])
            index = end
        }
        return stream
    }

    func testTheStreamHandsTheScannerWholeLinesOnly() {
        let text = excerptWithoutPlugIn.joined(separator: "\n")
        for size in [1, 5, 4096] {
            var chunked = stream(text, chunk: size)
            XCTAssertEqual(chunked.finish(exitedCleanly: true, timedOut: false), .summary(scan(lines: excerptWithoutPlugIn)),
                           "chunks of \(size)")
        }
    }

    func testARunThatHitTheDeadlineOrFailedIsNeverASummary() {
        let text = excerptWithoutPlugIn.joined(separator: "\n") + "\n"
        var timedOut = stream(text, chunk: 4096)
        XCTAssertEqual(timedOut.finish(exitedCleanly: true, timedOut: true), .failed,
                       "a zero exit after the deadline's signal is still a cut-off read")
        var crashed = stream(text, chunk: 4096)
        XCTAssertEqual(crashed.finish(exitedCleanly: false, timedOut: false), .failed)
    }

    func testAnOverlongLineIsDroppedAndFailsTheRead() {
        let longest = String(repeating: "x", count: PowerLog.maximumLineLength)
        var fits = stream(excerptWithoutPlugIn.joined(separator: "\n") + "\n" + longest + "\n", chunk: 4096)
        XCTAssertFalse(fits.overflowed)
        XCTAssertEqual(fits.finish(exitedCleanly: true, timedOut: false), .summary(scan(lines: excerptWithoutPlugIn)))

        var tooLong = stream(excerptWithoutPlugIn.joined(separator: "\n") + "\n" + longest + "x", chunk: 4096)
        XCTAssertTrue(tooLong.overflowed)
        tooLong.consume(Data("\n\(line("18:00:00", "AC(Charge: 20)"))\n".utf8))
        XCTAssertEqual(tooLong.finish(exitedCleanly: true, timedOut: false), .failed, "nothing after the drop counts either")
    }

    // MARK: One read at a time

    func testASecondRequestWaitsForTheRunningReadAndOnlyTheLatestIsKept() {
        let first = PowerLogRequest(periodID: 0, sessionBatteryStart: Date(timeIntervalSince1970: 1_938_980_800))
        let second = PowerLogRequest(periodID: 1, sessionBatteryStart: Date(timeIntervalSince1970: 1_938_980_900))
        let third = PowerLogRequest(periodID: 2, sessionBatteryStart: Date(timeIntervalSince1970: 1_938_981_000))
        var queue = PowerLogReadQueue()
        XCTAssertEqual(queue.submit(first), first, "nothing runs: start at once")
        XCTAssertNil(queue.submit(second), "one read at a time")
        XCTAssertNil(queue.submit(third))
        XCTAssertEqual(queue.finish(), third, "the waiting requests collapse into the latest")
        XCTAssertNil(queue.submit(first), "the latest now runs")
        XCTAssertEqual(queue.finish(), first)
        XCTAssertNil(queue.finish(), "nothing waits")
        XCTAssertEqual(queue.submit(second), second, "idle again")
    }
}
