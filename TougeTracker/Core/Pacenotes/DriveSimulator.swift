import Foundation
import CoreLocation

/// One co-driver call, stamped with when and where it happened.
public struct SimulatedCall: Equatable, Sendable {
    /// Seconds from the start of the drive.
    public let seconds: TimeInterval
    /// Metres from the start of the route.
    public let distanceAlong: Double
    /// What the co-driver would say, e.g. "three left, 100, two right".
    public let phrase: String
}

/// Replays a route as if it were being driven, and records the pacenote calls
/// the co-driver would make along the way.
///
/// This exists so the timing and phrasing of a drive can be checked without
/// going to a car: the navigator is driven with synthetic locations along the
/// route's own geometry, at a chosen speed, and every call it produces is
/// captured. Bugs that are obvious in a transcript — a call swallowed, two
/// corners announced as one, a note called far too early — are invisible in a
/// unit test that only asserts counts.
public final class DriveSimulator {

    public struct Options: Sendable {
        /// Speed along the route, m/s. ~22 m/s is 50 mph.
        public var speedMps: Double
        /// How often a location fix is fed in, seconds. The Drive tab runs at
        /// 20 Hz; 10 Hz is plenty to see the behaviour and keeps a long route
        /// from producing a runaway number of steps.
        public var fixInterval: TimeInterval
        public var format: PacenoteFormat
        /// Multiplier on the navigator's call distance, mirroring the setting.
        public var callDistanceScale: Double

        public init(speedMps: Double = 22, fixInterval: TimeInterval = 0.1,
                    format: PacenoteFormat = .rally, callDistanceScale: Double = 1.0) {
            self.speedMps = speedMps
            self.fixInterval = fixInterval
            self.format = format
            self.callDistanceScale = callDistanceScale
        }
    }

    public init() {}

    /// Drives `coordinates` from end to end and returns every call made.
    public func simulate(coordinates: [GeoPoint],
                         options: Options = Options()) -> [SimulatedCall] {
        guard coordinates.count > 1 else { return [] }

        let navigator = PacenoteNavigator(coordinates: coordinates.map(\.clLocation))
        navigator.callDistanceScale = options.callDistanceScale
        let routePoints = coordinates
        let total = GeoMath.lengthMeters(routePoints)
        guard total > 0 else { return [] }

        var calls: [SimulatedCall] = []
        let step = max(options.speedMps * options.fixInterval, 0.5)
        var travelled = 0.0
        var seconds: TimeInterval = 0

        while travelled <= total {
            let here = GeoMath.along(routePoints, distance: travelled)
            let next = GeoMath.along(routePoints, distance: min(travelled + step, total))
            // A real CLLocation carries a course, and the navigator uses it to
            // decide whether the driver started the route backwards. Without one
            // it can only ever assume forward, which is the case we are testing.
            let course = GeoMath.bearing(here, next)

            let location = CLLocation(coordinate: here.clLocation,
                                      altitude: 0,
                                      horizontalAccuracy: 5,
                                      verticalAccuracy: 5,
                                      course: course,
                                      speed: options.speedMps,
                                      timestamp: Date(timeIntervalSince1970: seconds))

            if let call = navigator.update(location: location, speed: options.speedMps) {
                calls.append(SimulatedCall(
                    seconds: seconds,
                    distanceAlong: travelled,
                    phrase: CoDriverPhrases.phrase(for: call, format: options.format)))
            }
            travelled += step
            seconds += options.fixInterval
        }
        return calls
    }

    /// A readable transcript, for eyeballing a drive.
    public func transcript(coordinates: [GeoPoint],
                           options: Options = Options()) -> String {
        let calls = simulate(coordinates: coordinates, options: options)
        let total = GeoMath.lengthMeters(coordinates)
        var lines = ["route \(Int(total))m at \(Int(options.speedMps * 3.6)) km/h "
                     + "— \(calls.count) calls\n"]
        for call in calls {
            let mm = String(format: "%02d:%02d", Int(call.seconds) / 60, Int(call.seconds) % 60)
            lines.append("\(mm)  \(Int(call.distanceAlong))m  \(call.phrase)")
        }
        return lines.joined(separator: "\n")
    }
}
