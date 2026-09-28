import Foundation
import CoreLocation
import MapKit

public enum RecordingState: Sendable {
    case idle
    case recording
    case paused
    case finished
}

/// A single on-screen marker at a pacenote apex.
public struct TurnMarker: Identifiable, Sendable {
    public let id = UUID()
    public var coordinate: CLLocationCoordinate2D
    public var title: String
    public var subtitle: String

    public init(coordinate: CLLocationCoordinate2D, title: String, subtitle: String) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }
}

public struct RecordedRoute: Sendable {
    public var coordinates: [CLLocationCoordinate2D]
    public var annotations: [TurnMarker]
    public var totalLengthMeters: Double
    public var callDistanceMeters: Double
    public var roadID: Int64?
    public var name: String?

    public init(coordinates: [CLLocationCoordinate2D],
                annotations: [TurnMarker],
                totalLengthMeters: Double,
                callDistanceMeters: Double,
                roadID: Int64? = nil,
                name: String? = nil) {
        self.coordinates = coordinates
        self.annotations = annotations
        self.totalLengthMeters = totalLengthMeters
        self.callDistanceMeters = callDistanceMeters
        self.roadID = roadID
        self.name = name
    }
}
