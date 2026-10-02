import Foundation

/// A thing on the road ahead that is worth saying out loud, which is not a
/// corner.
///
/// Pacenotes come from curvature: a co-driver sees a bend. These come from the
/// map instead — a junction where the road ends, a lane joining, a stop sign on
/// a back road — and none of them bend enough to be a corner. A merge is
/// invisible to a pacenote generator because the road does not deviate; it just
/// becomes more of one thing.
public enum RoadFeature: String, Codable, Sendable, CaseIterable {
    /// The road ahead ends and you must turn. From the router's "end of road".
    case tJunction
    /// A junction on the way. From a road-name change at one.
    case crossroads
    /// Another road joins from the side. From the router's "merge".
    case merge
    case roundabout
    case stopSign
    case trafficLights
    case giveWay

    /// What the HUD shows and what the system voice says when there is no clip.
    public var spoken: String {
        switch self {
        case .tJunction: return "T junction"
        case .crossroads: return "crossroads"
        case .merge: return "merge"
        case .roundabout: return "roundabout"
        case .stopSign: return "stop sign"
        case .trafficLights: return "traffic lights"
        case .giveWay: return "give way"
        }
    }

    /// The word each feature is written with, and the clip that carries it,
    /// in one place, because the pack lookup and the HUD both need to agree.
    public static let spokenWords: [String: String] = [
        "t junction": "AtJunction", "merge": "AtJunction",
        "crossroads": "AtTheCrossroad", "roundabout": "AtTheCrossroad",
        "stop sign": "Caution", "traffic lights": "Caution", "give way": "Caution",
    ]

    /// The recorded clip that carries this.
    ///
    /// The rally pack has three of the four warnings recorded — AtJunction,
    /// AtTheCrossroad and Caution — and no stop sign or set of lights, because a
    /// rally co-driver never says those. A stop sign is said as "caution": a
    /// slightly wrong word still warns, and silence warns of nothing. The HUD
    /// shows the exact thing either way, so the precise information is never
    /// lost to the vocabulary of the pack.
    public var clip: String {
        switch self {
        case .tJunction, .merge: return "AtJunction"
        case .crossroads, .roundabout: return "AtTheCrossroad"
        case .stopSign, .trafficLights, .giveWay: return "Caution"
        }
    }

    /// The features the router's maneuver types mean for a driver.
    ///
    /// Only maneuvers that say something the pacenotes do not are mapped. A
    /// plain "turn" is a corner and the geometry already calls it — announcing
    /// both would say the same thing twice — and "depart"/"arrive" are the ends
    /// of the route rather than anything on the road. A road-name change is
    /// treated as a junction: on a back road it is nearly always where another
    /// road comes in, and where it is not, a junction said at a place that is
    /// merely a name change is a small price.
    public init?(routerManeuver type: String) {
        switch type {
        case "end of road": self = .tJunction
        case "merge", "on ramp", "fork": self = .merge
        case "roundabout", "rotary", "exit roundabout": self = .roundabout
        case "new name", "continue": self = .crossroads
        default: return nil
        }
    }

    /// The OSM tags Overpass can report for a sign or signal node.
    public init?(osmTag tag: String) {
        switch tag {
        case "stop": self = .stopSign
        case "traffic_signals": self = .trafficLights
        case "give_way": self = .giveWay
        default: return nil
        }
    }
}

/// One feature, placed along a window of road.
public struct FeatureNote: Equatable, Sendable {
    /// Metres from the start of the window — the same coordinate pacenotes use,
    /// so the two can be interleaved by distance without conversion.
    public var distance: Double
    public var feature: RoadFeature

    public init(distance: Double, feature: RoadFeature) {
        self.distance = distance
        self.feature = feature
    }
}