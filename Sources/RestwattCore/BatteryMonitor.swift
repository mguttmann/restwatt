import Foundation

/// The timer intervals of the app. Documented in the README.
public enum Sampling {
    /// Seconds between two ticks. The gauge itself refreshes about every 60 s, so a
    /// 30 s tick sees every gauge update with at most 30 s of latency.
    public static let interval: TimeInterval = 30
    /// Seconds after the launch tick until a one-shot second tick. The process list needs two
    /// readings; this one makes it appear within seconds instead of after a full interval.
    public static let secondSampleDelay: TimeInterval = 5
}

/// Everything the status item needs, as plain data.
public struct BatteryStatus: Equatable, Sendable {
    public var state: PowerState
    public var percent: Int
    public var remainingWattHours: Double
    /// Positive while the battery supplies energy, negative while it takes energy in.
    public var drawWatts: Double
    /// Time to empty while draining, time to full while charging; nil in the neutral states
    /// and before the first sample of the current direction.
    public var estimate: Estimate?
    /// macOS's own time to empty, for comparison; only while draining.
    public var systemTimeToEmptyMinutes: Int?
    /// Gauge time to full, for comparison; only while charging.
    public var avgTimeToFullMinutes: Int?
    public var processReport: ProcessEnergyReport
    public var sampledAt: TimeInterval
    /// Rated power of the external source in watts, if the gauge reports it.
    public var adapterWatts: Int?
    /// Energy per process name over the current day; nil while nothing of the day is sampled.
    public var today: DailyEnergyStatistic?

    public init(
        state: PowerState,
        percent: Int,
        remainingWattHours: Double,
        drawWatts: Double,
        estimate: Estimate?,
        systemTimeToEmptyMinutes: Int?,
        avgTimeToFullMinutes: Int?,
        processReport: ProcessEnergyReport,
        sampledAt: TimeInterval,
        adapterWatts: Int? = nil,
        today: DailyEnergyStatistic? = nil
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
        self.adapterWatts = adapterWatts
        self.today = today
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
    private let memory: EnergyMemory?

    private var estimator = EnergyFlowEstimator()
    /// Flow states whose estimator was already taken from memory this session; a later
    /// switch back into one of them starts fresh, as it did before there was a memory.
    private var resumedKeys: Set<String> = []
    private var lastUpdateTime: Int?
    private var lastExternalConnected: Bool?
    private var lastState: PowerState?
    /// `UpdateTime` of a gauge reading that provably predates a plug or unplug event; while
    /// the gauge still reports it, no flow figures are shown.
    private var settlingUpdateTime: Int?
    private var previousProcesses: [ProcessEnergySample] = []
    private var previousProcessTime: TimeInterval?

    public init(battery: BatteryReading, processes: ProcessReading, clock: ClockReading,
                memory: EnergyMemory? = nil) {
        self.battery = battery
        self.processes = processes
        self.clock = clock
        self.memory = memory
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

        let state = presentedState(for: snapshot)
        let drawWatts = PowerMath.drawWatts(snapshot)
        let remainingWattHours = PowerMath.remainingWattHours(snapshot)

        // The smoothing restarts whenever the presented state changes: on a flip of the flow
        // direction, and also between battery-only and weak-source draining, where the
        // measured watts change meaning (whole system draw versus the source's shortfall).
        // The first time a flow state is shown in this session its estimator comes from the
        // memory of earlier sessions, if the staleness rule allows it.
        if state != lastState {
            if let key = state.memoryKey, let memory, !resumedKeys.contains(key) {
                estimator = memory.resume(key)
                resumedKeys.insert(key)
            } else {
                estimator.reset()
            }
        }
        if snapshot.updateTime != lastUpdateTime {
            switch state {
            case .discharging, .drainingOnExternalPower:
                estimator.add(time: now, energyWattHours: remainingWattHours, watts: drawWatts)
            case .charging:
                estimator.add(
                    time: now, energyWattHours: PowerMath.missingWattHours(snapshot), watts: -drawWatts)
            case .onExternalPower, .powerSourceChanging:
                break
            }
        }
        if let key = state.memoryKey, estimator.estimate != nil {
            memory?.remember(estimator, for: key)
        }
        lastUpdateTime = snapshot.updateTime
        lastExternalConnected = snapshot.externalConnected
        lastState = state

        let currentProcesses = processes.readProcesses()
        let dt = previousProcessTime.map { now - $0 } ?? 0
        let aggregation = ProcessEnergyRanker.aggregate(
            previous: previousProcesses, current: currentProcesses, dt: dt)
        if let aggregation {
            memory?.record(aggregation.entries, dt: dt)
        }
        let report = aggregation?.report(drawWatts: drawWatts, batteryIsOnlySource: state.isOnBatteryOnly)
            ?? .warmingUp
        previousProcesses = currentProcesses
        previousProcessTime = now
        memory?.saveIfChanged()

        return .battery(BatteryStatus(
            state: state,
            percent: snapshot.currentCapacityPercent,
            remainingWattHours: remainingWattHours,
            drawWatts: drawWatts,
            estimate: estimator.estimate,
            systemTimeToEmptyMinutes: state.isDraining ? snapshot.systemTimeToEmptyMinutes : nil,
            avgTimeToFullMinutes: state == .charging ? snapshot.avgTimeToFullMinutes : nil,
            processReport: report,
            sampledAt: now,
            adapterWatts: snapshot.adapterWatts,
            today: memory?.today
        ))
    }

    /// Write the memory one last time; the app calls this when it quits.
    public func willTerminate() {
        memory?.saveIfChanged()
    }

    /// The snapshot's own state, unless the reading provably predates a power source change.
    ///
    /// Plugging in or unplugging triggers an immediate resample, but the gauge's flow values
    /// (`Amperage`, `BatteryPower`) only change together with `UpdateTime`, up to a minute
    /// later. If `ExternalConnected` flipped while `UpdateTime` stayed the same, the flow
    /// values are from before the change and would show a wrong direction; those readings are
    /// presented as `.powerSourceChanging` until `UpdateTime` moves on. A flip that arrives
    /// together with a new `UpdateTime` is trusted as is.
    private func presentedState(for snapshot: BatterySnapshot) -> PowerState {
        if let lastExternalConnected, lastExternalConnected != snapshot.externalConnected,
           snapshot.updateTime == lastUpdateTime {
            settlingUpdateTime = snapshot.updateTime
        }
        if let settlingUpdateTime, settlingUpdateTime == snapshot.updateTime {
            return .powerSourceChanging
        }
        settlingUpdateTime = nil
        return snapshot.powerState
    }
}
