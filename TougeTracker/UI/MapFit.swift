import SwiftUI
import MapKit

/// Fits a map camera around a set of coordinates.
///
/// This was a private method on `RouteDetailView`, and the drive summary needed
/// exactly the same arithmetic to frame the run it recorded. Two copies of a
/// bounding box is two places for a "the map opened on Null Island" bug to live.
enum MapFit {
    /// The region containing every coordinate, padded so the line is not flush
    /// against the edges of the view.
    ///
    /// Returns a zeroed region for fewer than two points: there is no extent to
    /// fit, and inventing one from a single fix would drop the user somewhere
    /// arbitrary. Callers that have nothing to show should not be showing a map
    /// at all — `RouteDetailView` has always used the zeroed region here.
    static func region(for coords: [CLLocationCoordinate2D],
                       padding: Double = 1.2,
                       minSpan: Double = 0.002) -> MKCoordinateRegion {
        guard coords.count > 1 else { return MKCoordinateRegion() }
        var minLat = coords[0].latitude, maxLat = minLat
        var minLon = coords[0].longitude, maxLon = minLon
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let span = max(minSpan, max(maxLat - minLat, maxLon - minLon) * padding)
        let lat = (minLat + maxLat) / 2
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: (minLon + maxLon) / 2),
            // Longitude degrees shrink with latitude, so a square span in degrees
            // is a rectangle on the ground. Dividing by cos(lat) keeps it square.
            span: MKCoordinateSpan(latitudeDelta: span,
                                   longitudeDelta: span / max(abs(cos(lat * .pi / 180)), 0.01)))
    }
}
