import Foundation
import CoreLocation

/// Decides how much road geometry the map is allowed to draw.
///
/// Zooming out used to be fatal. Each bundled tile holds roughly a dozen roads
/// and a few hundred vertices, and the tile grid is 0.25°; a view spanning 2°
/// therefore covers 64 tiles and hands MapKit on the order of 770 separate
/// `MapPolyline` overlays carrying ~29,000 vertices. The map stutters, then the
/// process is killed for memory.
///
/// Two limits are applied together, because each alone leaves a hole:
/// * a cap on the number of roads bounds the overlay count MapKit has to track;
/// * a cap on the vertices per road bounds the geometry it has to tessellate —
///   one pathological 563-vertex road can outweigh a hundred short ones.
///
/// Above `detailSpanDegrees` (a single tile) the budget is generous enough that
/// nothing is dropped, so street-level driving is unaffected.
public enum RenderBudget {

    /// The tile grid the data is cut on, and the span at which a single tile
    /// fills the view.
    public static let detailSpanDegrees: Double = 0.25

    /// Hard ceiling on overlays, reached only when zoomed well out.
    public static let maxRoads: Int = 150

    /// Hard ceiling on vertices per road, reached only when zoomed well out.
    public static let maxPointsPerRoad: Int = 24

    /// How far out (in degrees of span) the budgets reach their limits. Between
    /// `detailSpanDegrees` and this, the limits scale in smoothly.
    public static let fullBudgetSpanDegrees: Double = 1.0

    /// Reduces `roads` to what is safe to draw at `spanDegrees` across.
    ///
    /// Best-scoring roads are kept: a zoomed-out map should still show the good
    /// roads, and dropping the top of the list is what a driver would notice.
    public static func roads(_ roads: [TougeRoad], spanDegrees: Double) -> [TougeRoad] {
        guard roads.count > maxRoads else { return roads }
        // Highest score first, so the prefix kept below is the best roads.
        let best = roads.sorted { ($0.totalScore ?? 0) > ($1.totalScore ?? 0) }
        return Array(best.prefix(maxRoads))
    }

    /// Vertices a road may contribute at `spanDegrees` across.
    public static func maxPoints(spanDegrees: Double) -> Int {
        guard spanDegrees > detailSpanDegrees else { return Int.max }
        let t = min((spanDegrees - detailSpanDegrees) / (fullBudgetSpanDegrees - detailSpanDegrees), 1)
        // Ease from "no limit" down to `maxPointsPerRoad` as the view widens.
        let limit = Double(maxPointsPerRoad) + (1 - t) * 4096
        return Int(limit.rounded())
    }
}

/// Thins a polyline for display without changing its shape at the current zoom.
///
/// Uses radial-distance decimation rather than a naive every-Nth-point stride:
/// a stride drops alternating vertices on a tight switchback and visibly
/// straightens the corner, whereas this only drops points that are closer
/// together than the on-screen tolerance.
public enum PolylineSimplifier {

    /// Keeps at most `maxPoints` vertices, dropping any whose neighbours are
    /// closer than `minSpacingMeters`. Endpoints are always kept so the line
    /// still spans the same road.
    public static func thin(_ points: [GeoPoint], maxPoints: Int,
                            minSpacingMeters: CLLocationDistance) -> [GeoPoint] {
        guard points.count > maxPoints, maxPoints >= 2 else { return points }

        // Doubling the spacing until the result fits keeps this O(n) rather than
        // looping a naive "thin then check" over and over.
        var spacing = max(minSpacingMeters, 0.1)
        for _ in 0..<16 {
            let result = thin(points, spacing: spacing)
            if result.count <= maxPoints { return result }
            spacing *= 2
        }
        // Radial thinning cannot always reach the budget (a zigzag can keep
        // alternating just inside the spacing forever), so finish with a stride
        // chosen from the *actual* surviving count. Computing the stride from the
        // original count instead would still overshoot.
        return stride(thin(points, spacing: spacing), to: maxPoints)
    }

    /// Uniformly subsamples `points` to exactly `maxPoints`, always keeping the
    /// first and last vertex.
    private static func stride(_ points: [GeoPoint], to maxPoints: Int) -> [GeoPoint] {
        guard points.count > maxPoints, maxPoints >= 2 else { return points }
        let step = Double(points.count - 1) / Double(maxPoints - 1)
        var out: [GeoPoint] = []
        for i in 0..<maxPoints {
            let idx = min(points.count - 1, Int((Double(i) * step).rounded()))
            out.append(points[idx])
        }
        if out[out.count - 1] != points[points.count - 1] {
            out[out.count - 1] = points[points.count - 1]
        }
        return out
    }

    private static func thin(_ points: [GeoPoint],
                             spacing: CLLocationDistance) -> [GeoPoint] {
        guard points.count > 2 else { return points }
        var out: [GeoPoint] = [points[0]]
        for p in points.dropFirst().dropLast() {
            if GeoMath.distanceMeters(out[out.count - 1], p) >= spacing { out.append(p) }
        }
        out.append(points[points.count - 1])
        return out
    }
}
