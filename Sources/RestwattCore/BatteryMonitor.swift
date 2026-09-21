import Foundation

/// The one timer interval of the app. Documented in the README.
public enum Sampling {
    /// Seconds between two ticks. The gauge itself refreshes about every 60 s, so a
    /// 30 s tick sees every gauge update with at most 30 s of latency.
    public static let interval: TimeInterval = 30
}

/// Everything the status item needs, as plain data.
public struct BatteryStatus: Equatable, Sendable {
    public var state: PowerState
    public var percent: Int
    public var remainingWattHours: Double
    /// Positive while discharging, negative while charging.
    public var drawWatts: Double
    /// Nil while charging or before the first discharge sample.
    public var estimate: Estimate?
    /// macOS's own time to empty, for comparison.
    public var systemTimeToEmptyMinutes: Int?
    /// Gauge time to full, only meaningful while charging.
    public var avgTimeToFullMinutes: Int?
    public var processReport: ProcessEnergyReport
    public var sampledAt: TimeInterval

    public init(
        state: PowerState,
        percent: Int,
        remainingWattHours: Double,
        drawWatts: Double,
        estimate: Estimate?,
        systemTimeToEmptyMinutes: Int?,
        avgTimeToFullMinutes: Int?,
        processReport: ProcessEnergyReport,
        sampledAt: TimeInterval
    ) {
        self.state = state
        self.percent = percent
        self.remainingWattHours = remainingWattHours
        self.drawWatts = drawWatts
        self.estimate = estimate
        self.systemTimeToEmptyMinutes = systemTimeToEmptyMinutes
        self.avgTimeToFullMinutes = avgTimeToFullMinutes
        self.processReport = processReport
        self.sampledAt = sampledAt
    }
}

public enum DisplayModel: Equatable, Sendable {
    /// The battery could not be read; `reason` is a short English phrase.
    case unavailable(reason: String)
    case battery(BatteryStatus)
}

/// Ties reader, estimator and ranker together. One `tick()` per timer fire.
public final class BatteryMonitor {
    private let battery: BatteryReading
    private let processes: ProcessReading
    private let clock: ClockReading

    private var estimator = TimeToEmptyEstimator()
    private var lastUpdateTime: Int?
    private var previousProcesses: [ProcessEnergySample] = []
    private var previousProcessTime: TimeInterval?

    public init(battery: BatteryReading, processes: ProcessReading, clock: ClockReading) {
        self.battery = battery
        self.processes = processes
        self.clock = clock
    }

    public func tick() -> DisplayModel {
        let now = clock.now
        let snapshot: BatterySnapshot
        do {
            snapshot = try battery.readBattery()
        } catch BatteryReadError.noBattery {
            return .unavailable(reason: "No battery found")
        } catch {
            return .unavailable(reason: "Battery data unreadable")
        }

        let state = snapshot.powerState
        let drawWatts = PowerMath.drawWatts(snapshot)
        let remainingWattHours = PowerMath.remainingWattHours(snapshot)

        if state.isDischarging {
            if snapshot.updateTime != lastUpdateTime {
                estimator.add(time: now, remainingWattHours: remainingWattHours, drawWatts: drawWatts)
            }
        } else {
            estimator.reset()
        }
        lastUpdateTime = snapshot.updateTime

        let currentProcesses = processes.readProcesses()
        let dt = previousProcessTime.map { now - $0 } ?? 0
        let report = ProcessEnergyRanker.rank(
            previous: previousProcesses,
            current: currentProcesses,
            dt: dt,
            drawWatts: drawWatts,
            isDischarging: state.isDischarging
        )
        previousProcesses = currentProcesses
        previousProcessTime = now

        return .battery(BatteryStatus(
            state: state,
            percent: snapshot.currentCapacityPercent,
            remainingWattHours: remainingWattHours,
            drawWatts: drawWatts,
            estimate: state.isDischarging ? estimator.estimate : nil,
            systemTimeToEmptyMinutes: state.isDischarging ? snapshot.systemTimeToEmptyMinutes : nil,
            avgTimeToFullMinutes: state == .charging ? snapshot.avgTimeToFullMinutes : nil,
            processReport: report,
            sampledAt: now
        ))
    }
}
