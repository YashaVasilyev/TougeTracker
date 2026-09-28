import Foundation
import Observation

/// Length unit preference.
public enum LengthUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case mph
    case kmh

    public var id: String { rawValue }
    public var symbol: String { self == .mph ? "mph" : "km/h" }
    public var distanceSymbol: String { self == .mph ? "mi" : "km" }

    public func speedValue(_ metersPerSecond: Double) -> Double {
        self == .mph ? metersPerSecond * 2.2369362920544 : metersPerSecond * 3.6
    }

    public func speedString(_ metersPerSecond: Double) -> String {
        "\(Int(speedValue(metersPerSecond).rounded()))"
    }

    public func distanceValue(_ meters: Double) -> Double {
        self == .mph ? meters / 1609.344 : meters / 1000
    }

    public func distanceString(_ meters: Double) -> String {
        String(format: "%.1f", distanceValue(meters))
    }
}

/// App-wide settings, persisted in UserDefaults. Injected into the view tree with
/// `.environment(AppSettings.shared)` and bound in Settings with `@Bindable`.
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        units = LengthUnit(rawValue: defaults.string(forKey: "settings.units") ?? "") ?? Self.defaultUnits()
        pacenoteFormat = PacenoteFormat(rawValue: defaults.string(forKey: "settings.pacenoteFormat") ?? "") ?? .rally
        voiceEnabled = defaults.object(forKey: "settings.voiceEnabled") as? Bool ?? true
        speechRate = defaults.object(forKey: "settings.speechRate") as? Double ?? 1.0
        callDistanceScale = defaults.object(forKey: "settings.callDistanceScale") as? Double ?? 1.0
    }

    public static func defaultUnits() -> LengthUnit {
        Locale.current.measurementSystem == .metric ? .kmh : .mph
    }

    public var units: LengthUnit = defaultUnits() {
        didSet { defaults.set(units.rawValue, forKey: "settings.units") }
    }

    public var pacenoteFormat: PacenoteFormat = .rally {
        didSet { defaults.set(pacenoteFormat.rawValue, forKey: "settings.pacenoteFormat") }
    }

    public var voiceEnabled: Bool = true {
        didSet { defaults.set(voiceEnabled, forKey: "settings.voiceEnabled") }
    }

    /// AVSpeechUtterance rate multiplier relative to the default rate.
    public var speechRate: Double = 1.0 {
        didSet { defaults.set(speechRate, forKey: "settings.speechRate") }
    }

    /// Scales the distance ahead at which pacenotes are called (1.0 = default).
    public var callDistanceScale: Double = 1.0 {
        didSet { defaults.set(callDistanceScale, forKey: "settings.callDistanceScale") }
    }

}
