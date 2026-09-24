import Foundation

/// The constants of the one `pmset -g log` read. Documented in the README.
public enum PowerLog {
    /// A log bracket (last external line to first battery line) at most this wide counts as
    /// the unplug itself; a wider one only bounds it.
    public static let preciseBracket: TimeInterval = 300
    /// Seconds after which the read is stopped and the honest lower bound stays.
    public static let readTimeout: TimeInterval = 30
    /// Seconds a stopped read gets to exit after the terminate signal before it is killed.
    public static let killGrace: TimeInterval = 2
    /// Bytes an unterminated line may grow to; a longer one is dropped and fails the read.
    public static let maximumLineLength = 65_536
}

/// What a scan of the power log found about the current battery period. Times are unix seconds.
public struct PowerLogSummary: Equatable, Sendable {
    /// Time of the last line that reported an external source.
    public var lastExternalAt: Double?
    /// First battery line of the period that is still open at the end of the log.
    public var batterySince: Double?
    /// The last line before `batterySince` known not to be on battery yet: the last external
    /// line, or the last line before an unobserved boot. Nil when the log has neither.
    public var bracketStart: Double?
    /// Charge at the start of the period, only from a complete reading near `batterySince` and
    /// only for an exact start.
    public var percent: Int?
    /// The last complete charge the log shows for the open period, at any precision. It is
    /// the reference a later charge is held against: a higher reading means the battery was
    /// charged after this line without the log seeing it.
    public var lastPercent: Int?
    /// The last line that named a power source named the battery.
    public var endsOnBattery: Bool
    /// A boot lies after `lastExternalAt` that the log does not show the battery period to
    /// continue across: no battery line before it, a charge unknown on either side or risen
    /// across it, or no battery line after it before the log ends. The Mac may have been on
    /// an external source while off, so nothing recorded before that boot can be confirmed.
    public var unvettedBootAfterExternal: Bool

    public init(lastExternalAt: Double? = nil, batterySince: Double? = nil, bracketStart: Double? = nil,
                percent: Int? = nil, lastPercent: Int? = nil, endsOnBattery: Bool = false,
                unvettedBootAfterExternal: Bool = false) {
        self.lastExternalAt = lastExternalAt
        self.batterySince = batterySince
        self.bracketStart = bracketStart
        self.percent = percent
        self.lastPercent = lastPercent
        self.endsOnBattery = endsOnBattery
        self.unvettedBootAfterExternal = unvettedBootAfterExternal
    }

    /// `.exact` when the bracket around `since` is known and at most `PowerLog.preciseBracket`
    /// wide, `.lowerBound` otherwise.
    public func precision(since: Double) -> UnplugRecord.Precision {
        if let bracketStart, since - bracketStart <= PowerLog.preciseBracket {
            return .exact
        }
        return .lowerBound
    }

    /// The precision of `batterySince` itself.
    public var precision: UnplugRecord.Precision {
        batterySince.map(precision(since:)) ?? .lowerBound
    }
}

/// The result of one read, as the app hands it back.
public enum PowerLogOutcome: Equatable, Sendable {
    case summary(PowerLogSummary)
    /// Timeout, non-zero exit, an overlong line, or the tool could not be started.
    case failed
}

/// The raw output of one read on its way to the scanner: whole lines only, so no UTF-8
/// sequence is cut in two, and at most `PowerLog.maximumLineLength` bytes of an unterminated
/// line. A longer line is dropped and the read can only fail from then on.
public struct PowerLogStream: Sendable {
    private var scanner = PowerLogScanner()
    private var carry = Data()
    /// A line outgrew `PowerLog.maximumLineLength`; the rest of the output is ignored.
    public private(set) var overflowed = false

    public init() {}

    public mutating func consume(_ chunk: Data) {
        guard !overflowed else {
            return
        }
        carry.append(chunk)
        if let lastNewline = carry.lastIndex(of: 0x0A) {
            scanner.consume(String(decoding: carry[carry.startIndex...lastNewline], as: UTF8.self))
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        if carry.count > PowerLog.maximumLineLength {
            carry = Data()
            overflowed = true
        }
    }

    /// The outcome once the tool has ended. Only a clean exit before the deadline with no
    /// dropped line is a summary; a read that hit the deadline fails even when the tool then
    /// exited with 0, because its output may be cut off anywhere.
    public mutating func finish(exitedCleanly: Bool, timedOut: Bool) -> PowerLogOutcome {
        guard exitedCleanly, !timedOut, !overflowed else {
            return .failed
        }
        scanner.consume(String(decoding: carry, as: UTF8.self))
        carry = Data()
        scanner.finish()
        return .summary(scanner.summary)
    }
}

/// At most one log read at a time. A request that arrives while a read runs waits; several
/// waiting requests collapse into the latest, which starts when the running read ends. A read
/// that already runs is never reused for a later request, since it may not reach the lines
/// of the later period.
public struct PowerLogReadQueue: Sendable {
    private var running = false
    private var waiting: PowerLogRequest?

    public init() {}

    /// The request to start now, or nil when a read is running and `request` waits.
    public mutating func submit(_ request: PowerLogRequest) -> PowerLogRequest? {
        guard !running else {
            waiting = request
            return nil
        }
        running = true
        return request
    }

    /// The running read ended; the waiting request to start next, if any.
    public mutating func finish() -> PowerLogRequest? {
        guard let next = waiting else {
            running = false
            return nil
        }
        waiting = nil
        return next
    }
}

/// One read the tracker asks for; the answer is only applied to the period it was asked for.
public struct PowerLogRequest: Equatable, Sendable {
    public let periodID: Int
    /// Wall-clock time of the first battery tick of the period in this session.
    public let sessionBatteryStart: Date

    public init(periodID: Int, sessionBatteryStart: Date) {
        self.periodID = periodID
        self.sessionBatteryStart = sessionBatteryStart
    }
}

/// Reads the output of `pmset -g log` incrementally, one chunk at a time, and keeps only a
/// constant amount of state: nothing of the log is buffered beyond the current line.
///
/// Only lines with a strict `yyyy-MM-dd HH:mm:ss +hhmm` prefix count. The power source is the
/// token after the last `Using ` of a line: `AC` is external, `Batt` in any case is the
/// battery, anything else (cut off, unknown) is ignored. A charge counts only when its
/// reading is complete up to the closing parenthesis, so a line cut off at `Charge: 1` never
/// reads as 1 %. A `powerd process is started` line inside a battery period is a boot the
/// log did not watch: the period only continues across it when the charge before and after is
/// known and fell. An unchanged charge vets nothing, since a Mac held at 100 % or at a charge
/// limit reads the same after charging while off. Otherwise the period starts again after the
/// boot, bracketed by the last line before it only when the charge rose (it was charged while
/// off, so the unplug lies after that line); with an unknown or unchanged charge the unplug
/// may lie anywhere before the boot, and the restart is only a lower bound. Every boot after
/// the last external line that is not vetted this way, including one with no battery line
/// before it and one the log ends on, is reported as `unvettedBootAfterExternal`.
public struct PowerLogScanner: Sendable {
    private struct BootCheck: Sendable {
        /// Last complete charge of the period before the boot.
        var percentBefore: Int?
        /// Last timestamped line before the boot.
        var lastTimestampBefore: Double?
        var firstBatteryAt: Double?
    }

    private var pending = ""
    private var lastExternalAt: Double?
    private var batterySince: Double?
    private var bracketStart: Double?
    private var percent: Int?
    private var lastPeriodPercent: Int?
    private var endsOnBattery = false
    private var lastTimestamp: Double?
    private var bootCheck: BootCheck?
    /// A boot after the last external line was not vetted by the charge before and after it.
    private var unvettedBoot = false

    public init() {}

    /// Feed the next piece of output; a line may span chunks.
    public mutating func consume(_ chunk: String) {
        pending += chunk
        guard pending.contains("\n") else {
            return
        }
        var lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
        pending = String(lines.removeLast())
        for line in lines {
            scan(line)
        }
    }

    /// The output ended; scan a last line without a newline and settle an open boot check.
    public mutating func finish() {
        if !pending.isEmpty {
            scan(Substring(pending))
            pending = ""
        }
        if bootCheck != nil {
            restartAfterBoot()
        }
    }

    /// The charge is only kept for an exact start; at a lower bound it is not the charge at
    /// the unplug.
    public var summary: PowerLogSummary {
        var summary = PowerLogSummary(
            lastExternalAt: lastExternalAt,
            batterySince: endsOnBattery ? batterySince : nil,
            bracketStart: endsOnBattery ? bracketStart : nil,
            percent: endsOnBattery ? percent : nil,
            lastPercent: endsOnBattery ? lastPeriodPercent : nil,
            endsOnBattery: endsOnBattery,
            unvettedBootAfterExternal: unvettedBoot || bootCheck != nil)
        if summary.precision != .exact {
            summary.percent = nil
        }
        return summary
    }

    private mutating func scan(_ line: Substring) {
        let bytes = Array(line.utf8)
        guard let time = Self.timestamp(bytes) else {
            return
        }
        let rest = bytes[25...]
        if Self.isBootMarker(rest) {
            if batterySince != nil, endsOnBattery {
                if let check = bootCheck, check.firstBatteryAt != nil {
                    restartAfterBoot()
                }
                if bootCheck == nil {
                    bootCheck = BootCheck(percentBefore: lastPeriodPercent, lastTimestampBefore: lastTimestamp)
                }
            } else {
                // No battery line of this period before the boot: no charge to vet it against.
                unvettedBoot = true
            }
            lastTimestamp = time
            return
        }
        lastTimestamp = time
        guard let found = Self.source(rest) else {
            return
        }
        let charge = found.charge
        if !found.onBattery {
            lastExternalAt = time
            batterySince = nil
            bracketStart = nil
            percent = nil
            lastPeriodPercent = nil
            bootCheck = nil
            unvettedBoot = false
            endsOnBattery = false
            return
        }
        endsOnBattery = true
        if batterySince == nil {
            batterySince = time
            bracketStart = lastExternalAt
            percent = nil
            lastPeriodPercent = nil
        }
        if var check = bootCheck {
            if check.firstBatteryAt == nil {
                check.firstBatteryAt = time
                bootCheck = check
            }
            guard let charge else {
                return
            }
            if let before = check.percentBefore, charge < before {
                bootCheck = nil
            } else {
                restartAfterBoot(chargedWhileOff: check.percentBefore.map { charge > $0 } ?? false)
            }
        }
        if let charge {
            if percent == nil, let batterySince, time - batterySince <= PowerLog.preciseBracket {
                percent = charge
            }
            lastPeriodPercent = charge
        }
    }

    /// The period is not known to continue across the boot: it starts again with the first
    /// battery line after it. Only a charge that rose across the boot brackets that start by
    /// the last line before it; otherwise the start is a lower bound. Without a battery line
    /// after the boot the log knows no current period at all.
    private mutating func restartAfterBoot(chargedWhileOff: Bool = false) {
        guard let check = bootCheck else {
            return
        }
        bootCheck = nil
        unvettedBoot = true
        guard let first = check.firstBatteryAt else {
            batterySince = nil
            bracketStart = nil
            percent = nil
            lastPeriodPercent = nil
            return
        }
        batterySince = first
        bracketStart = chargedWhileOff ? check.lastTimestampBefore : nil
        percent = nil
        lastPeriodPercent = nil
    }

    // MARK: Line grammar

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func number(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var value = 0
        for index in range {
            guard isDigit(bytes[index]) else {
                return nil
            }
            value = value * 10 + Int(bytes[index] - 0x30)
        }
        return value
    }

    /// Unix seconds of a `yyyy-MM-dd HH:mm:ss +hhmm` prefix, followed by a blank or the end of
    /// the line; nil for anything else. No locale is involved.
    static func timestamp(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 25, bytes.count == 25 || bytes[25] == 0x20 || bytes[25] == 0x09,
              bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x20, bytes[13] == 0x3A, bytes[16] == 0x3A,
              bytes[19] == 0x20, bytes[20] == 0x2B || bytes[20] == 0x2D,
              let year = number(bytes, 0..<4), let month = number(bytes, 5..<7), let day = number(bytes, 8..<10),
              let hour = number(bytes, 11..<13), let minute = number(bytes, 14..<16),
              let second = number(bytes, 17..<19),
              let offsetHours = number(bytes, 21..<23), let offsetMinutes = number(bytes, 23..<25),
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              hour < 24, minute < 60, second < 60, offsetHours <= 14, offsetMinutes < 60 else {
            return nil
        }
        let offset = (offsetHours * 3600 + offsetMinutes * 60) * (bytes[20] == 0x2D ? -1 : 1)
        let days = daysFromCivil(year: year, month: month, day: day)
        return Double(days * 86400 + hour * 3600 + minute * 60 + second - offset)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func range(of needle: String, in bytes: ArraySlice<UInt8>, last: Bool) -> Range<Int>? {
        let pattern = Array(needle.utf8)
        guard bytes.count >= pattern.count else {
            return nil
        }
        let starts = bytes.startIndex...(bytes.endIndex - pattern.count)
        let ordered: [Int] = last ? starts.reversed() : Array(starts)
        for start in ordered where bytes[start..<(start + pattern.count)].elementsEqual(pattern) {
            return start..<(start + pattern.count)
        }
        return nil
    }

    private static func isBootMarker(_ rest: ArraySlice<UInt8>) -> Bool {
        let trimmed = rest.drop { $0 == 0x20 || $0 == 0x09 }
        return trimmed.starts(with: Array("Start".utf8))
            && range(of: "powerd process is started", in: trimmed, last: false) != nil
    }

    /// The power source of a line (true for the battery) and its complete charge, if any.
    static func source(_ rest: ArraySlice<UInt8>) -> (onBattery: Bool, charge: Int?)? {
        guard let using = range(of: "Using ", in: rest, last: true) else {
            return nil
        }
        let token = rest[using.upperBound...]
        let onBattery: Bool
        if token.starts(with: Array("AC".utf8)) {
            onBattery = false
        } else if token.count >= 4, String(decoding: token.prefix(4), as: UTF8.self).lowercased() == "batt" {
            onBattery = true
        } else {
            return nil
        }
        return (onBattery, charge(token))
    }

    /// `Charge:`, an optional blank, one to three digits, an optional `%`, and `)`; 0 to 100.
    private static func charge(_ token: ArraySlice<UInt8>) -> Int? {
        guard let label = range(of: "Charge:", in: token, last: false) else {
            return nil
        }
        var index = label.upperBound
        if index < token.endIndex, token[index] == 0x20 {
            index += 1
        }
        var value = 0
        var digits = 0
        while index < token.endIndex, isDigit(token[index]), digits < 4 {
            value = value * 10 + Int(token[index] - 0x30)
            digits += 1
            index += 1
        }
        guard (1...3).contains(digits) else {
            return nil
        }
        if index < token.endIndex, token[index] == 0x25 {
            index += 1
        }
        guard index < token.endIndex, token[index] == 0x29, value <= 100 else {
            return nil
        }
        return value
    }
}
