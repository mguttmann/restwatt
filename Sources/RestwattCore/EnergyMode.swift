import Foundation

/// Apple's Energy Mode as `pmset` reports it: the `powermode` line of `pmset -g custom`
/// (read) and, as `pmset -g cap` lists it and outside documentation describes it, the key
/// `lowpowermode` (write). The value 1 = Low Power is confirmed against Apple's own menu on
/// the development Mac; 0 = Automatic and 2 = High Power are observed there and documented
/// elsewhere, not confirmed. Until then every menu row shows the raw value next to its label.
public enum EnergyMode: Int, CaseIterable, Equatable, Sendable {
    case automatic = 0
    case lowPower = 1
    case highPower = 2

    /// Apple's wording in its battery menu.
    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .lowPower: return "Low Power"
        case .highPower: return "High Power"
        }
    }

    /// The raw value hint shown next to the label: what `pmset -g custom` prints for it.
    public var rawDetail: String {
        "powermode \(rawValue)"
    }
}

/// The two power sources `pmset` addresses with `-b` and `-c`. The raw value is the block
/// header of `pmset -g custom` and the name in `Capabilities for <name>:` of `pmset -g cap`
/// (IOKit's `kIOPMBatteryPowerKey` and `kIOPMACPowerKey`).
public enum PowerSource: String, CaseIterable, Equatable, Sendable {
    case battery = "Battery Power"
    case ac = "AC Power"

    /// The `pmset` flag that scopes a write to this source.
    public var pmsetFlag: String {
        switch self {
        case .battery: return "-b"
        case .ac: return "-c"
        }
    }

    /// The word after `Power Source:` in the menu, as Apple's menu says it.
    public var label: String {
        switch self {
        case .battery: return "Battery"
        case .ac: return "AC"
        }
    }
}

/// What one refresh saw for the current power source.
public struct EnergyModeObservation: Equatable, Sendable {
    public var source: PowerSource
    /// `powermode` of that source in `pmset -g custom`; nil when the block has no such line.
    public var rawValue: Int?
    /// `pmset -g cap` lists `highpowermode` for that source.
    public var highPowerCapable: Bool

    public init(source: PowerSource, rawValue: Int?, highPowerCapable: Bool) {
        self.source = source
        self.rawValue = rawValue
        self.highPowerCapable = highPowerCapable
    }

    /// An absent line reads as Automatic (pmset omits the key when the mode is off); a value
    /// outside the known ones is nil and marks no row.
    public var mode: EnergyMode? {
        guard let rawValue else {
            return .automatic
        }
        return EnergyMode(rawValue: rawValue)
    }

    /// High Power is offered when the source can set it, or when it is set already so the
    /// state stays visible.
    public var offersHighPower: Bool {
        highPowerCapable || rawValue == EnergyMode.highPower.rawValue
    }
}
