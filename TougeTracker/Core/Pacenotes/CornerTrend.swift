import Foundation

/// Whether a corner gets tighter or opens out as it goes.
///
/// A corner is a change of direction; this is a change of *how hard* it is. It is
/// the thing a co-driver says when a road that looked like a four tightens into
/// something a two, or opens out into a six — and it is information the severity
/// grade cannot carry, because a corner that tightens and a corner that is
/// simply tight are the same grade.
///
/// Measured before it was built. Fitting a line to log(radius) against distance
/// along the corner separates the cases; comparing the radius at the start to
/// the radius at the end does not. The ratio version is a smooth continuum
/// centred on 1.0 — its median is exactly 1.00, and a 25% band either side of
/// that fires on 20% of corners, which is two corners in five called "tightens".
public enum CornerTrend: String, Codable, Equatable, Sendable {
    case none
    case tightens
    case opens

    /// Whether the corner is called as changing at all.
    public var isNoted: Bool { self != .none }

    /// The word a co-driver uses, appended to the corner: "three left tightens".
    public var word: String {
        switch self {
        case .none: return ""
        case .tightens: return " tightens"
        case .opens: return " opens"
        }
    }
}

extension CornerTrend {
    /// The word for a trend, or nothing for a straight.
    ///
    /// A straight has no radius to change, so it is never called as changing.
    static func spelling(_ trend: CornerTrend) -> String { trend.word }
}

public enum CornerTrendDetector {

    /// Sample spacing for the trend pass, in metres.
    ///
    /// Finer than the severity pass on purpose. Severity asks "how tight is this
    /// corner", which wants a long stable baseline; the trend asks how the
    /// tightness *changes along* it, which wants readings close enough together
    /// to see a slope. Resampling the whole pipeline at 3m instead of 5m costs
    /// 11% more notes across the road set and shifts the grade mix, which is
    /// not a price worth paying for a modifier on 3% of corners.
    public static let sampleStep = 3.0

    /// Samples either side used to measure the radius at each reading.
    ///
    /// 5 at 3m is a 15m baseline, longer than the severity pass's 10m. A shorter
    /// baseline would put the measurement below the resolution of the data.
    public static let lookSamples = 5

    /// Corners shorter than this cannot show a trend, and are not asked to.
    ///
    /// Half of all corners are under 39m long, and with a 15m measurement
    /// window the profile is smeared across the corner itself. It is measured
    /// geometry, not a tuning value: there is no signal there to find.
    public static let minimumLength = 40.0

    /// How well the radius has to fit a straight line in log space.
    ///
    /// Only about a tenth of corners achieve this, which is the point: most
    /// corners do not change monotonically, and saying so is better than
    /// guessing at a slope through noise.
    public static let minimumFit = 0.5

    /// How much the radius has to change across the corner, in log space.
    ///
    /// Stated as a total change rather than a slope per metre, because the fit
    /// runs over the whole corner and the corners range from 40m to several
    /// hundred. A per-metre rate would silently demand a far larger change from
    /// a long corner than from a short one — at 0.02 per metre, a 200m corner
    /// would have to shrink its radius fifty-fold, which no road does.
    ///
    /// 0.35 is a factor of about 1.4 end to end: a corner that goes from 40m
    /// radius to 30m, or one that opens from 60m to 85m. That is a change you
    /// can feel, and the r2 gate below is what stops it firing on noise.
    public static let minimumLogChange = 0.35

    /// The trend for a corner, given the road's own geometry.
    ///
    /// - Parameters:
    ///   - coordinates: the road, in driving order.
    ///   - start: metres from the start of the road.
    ///   - end: metres from the start of the road.
    public static func trend(along coordinates: [GeoPoint],
                             from start: Double, to end: Double) -> CornerTrend {
        guard end - start >= minimumLength, coordinates.count > 3 else { return .none }

        let samples = radii(along: coordinates, from: start - 10, to: end + 10)
        guard samples.count >= 8 else { return .none }

        // Fit log(radius) against distance. A straight line through the
        // readings, weighted least squares by hand so this stays free of any
        // statistics framework for four coefficients.
        let n = Double(samples.count)
        let meanX = samples.reduce(0) { $0 + $1.distance } / n
        let meanY = samples.reduce(0) { $0 + log($1.radius) } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for sample in samples {
            let dx = sample.distance - meanX
            let dy = log(sample.radius) - meanY
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return .none }
        let slope = sxy / sxx
        let fit = (sxy * sxy) / (sxx * syy)
        // The total change across the corner, not the rate.
        let span = samples.last!.distance - samples.first!.distance
        guard fit >= minimumFit, abs(slope) * span >= minimumLogChange else { return .none }
        return slope < 0 ? .tightens : .opens
    }

    /// Corner radius every `sampleStep` metres, over a stretch of road.
    private static func radii(along coordinates: [GeoPoint],
                               from start: Double, to end: Double) -> [(distance: Double, radius: Double)] {
        let smoothed = GeoMath.chaikinSmooth(coordinates, iterations: 2)
        let total = GeoMath.lengthMeters(smoothed)
        let from = max(0, start), to = min(total, end)
        guard to > from else { return [] }
        // Three points either side of each reading, at the 3m spacing.
        let guard_ = Double(lookSamples) * sampleStep

        var out: [(distance: Double, radius: Double)] = []
        var d = from
        while d <= to {
            let before = GeoMath.along(smoothed, distance: max(0, d - guard_))
            let here = GeoMath.along(smoothed, distance: d)
            let after = GeoMath.along(smoothed, distance: min(total, d + guard_))
            let radius = GeoMath.circumRadiusMeters(before, here, after)
            if radius.isFinite, radius > 0 { out.append((d, radius)) }
            d += sampleStep
        }
        return out
    }
}
