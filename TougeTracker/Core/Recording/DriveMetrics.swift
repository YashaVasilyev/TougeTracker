import Foundation

/// Speed and acceleration derived from a recorded drive's telemetry.
///
/// Split out of the drive summary view because these are the numbers a viewer
/// checks against their own memory of the drive ("I never touched 90"), and
/// because the derivative of GPS speed is the one genuinely error-prone piece
/// of arithmetic in this screen.
public enum DriveMetrics {

    /// One point on the speed/acceleration chart.
    public struct Point: Sendable, Equatable {
        public var t: Double        // seconds since drive start
        public var speed: Double    // m/s
        public var accel: Double    // m/s², + accelerating, − braking

        public init(t: Double, speed: Double, accel: Double) {
            self.t = t; self.speed = speed; self.accel = accel
        }
    }

    /// Mean speed over the whole drive, m/s. Zero for a zero-length or
    /// zero-duration drive rather than a division by zero or an infinity.
    ///
    /// This is distance ÷ elapsed time, not the mean of the sampled speeds: the
    /// two disagree wherever the GPS drops out, and distance is the number the
    /// summary text and the export already agree on.
    public static func averageSpeed(distanceMeters: Double, durationSeconds: Double) -> Double {
        guard durationSeconds > 0, distanceMeters > 0 else { return 0 }
        return distanceMeters / durationSeconds
    }

    /// The speed and acceleration series to plot, decimated to at most
    /// `maxPoints` entries.
    ///
    /// Acceleration is d(speed)/dt by central difference. That is the derivative
    /// the summary is asked to show, and it is noisy for two reasons: GPS speed
    /// jitters sample to sample, and `t` is not evenly spaced (samples arrive
    /// when Core Location feels like delivering them), so dividing by the sample
    /// *index* rather than by elapsed time turns ordinary jitter into a large
    /// spurious acceleration. A centred moving average over `smoothWindow`
    /// samples is applied to the speed series before differentiating, and two
    /// samples sharing a timestamp contribute no acceleration at all.
    ///
    /// `smoothWindow` is in samples, not seconds, because the series is what it
    /// is: a window of 1 disables smoothing, which is what the tests use to pin
    /// the arithmetic itself.
    public static func series(from samples: [TelemetrySample],
                              smoothWindow: Int = 5,
                              maxPoints: Int = 1200) -> [Point] {
        guard samples.count >= 2 else {
            // One sample is a point, not a series. It is kept so the chart has
            // something to draw, and it gets zero acceleration — unknowable.
            return samples.map { Point(t: $0.t, speed: Double($0.speed), accel: 0) }
        }

        let smoothed = movingAverage(samples.map { Double($0.speed) }, window: smoothWindow)

        var points: [Point] = []
        points.reserveCapacity(samples.count)
        for (i, s) in samples.enumerated() {
            points.append(Point(t: s.t, speed: smoothed[i],
                                accel: acceleration(in: samples, smoothed: smoothed, at: i)))
        }
        return decimate(points, maxPoints: maxPoints)
    }

    /// Central-difference acceleration at index `i`, m/s².
    ///
    /// Central rather than forward difference because a one-sided derivative
    /// systematically lags the signal by half a sample, which shows up as every
    /// braking point being called slightly late. The endpoints fall back to the
    /// one-sided difference against their single neighbour; there is no second
    /// side to difference against.
    ///
    /// Where the samples either side share an instant there is no interval to
    /// divide by, so the result is 0 rather than ±inf. Real drives do contain
    /// repeated timestamps.
    private static func acceleration(in samples: [TelemetrySample],
                                     smoothed: [Double], at i: Int) -> Double {
        let last = samples.count - 1
        let lower = max(0, i - 1)
        let upper = min(last, i + 1)
        guard upper > lower else { return 0 }
        let dt = samples[upper].t - samples[lower].t
        guard dt > 0 else { return 0 }
        return (smoothed[upper] - smoothed[lower]) / dt
    }


    /// Centred moving average, shrinking at the edges rather than padding.
    ///
    /// Edge samples use only the neighbours that exist, so the first and last
    /// points of a drive are not dragged toward zero by an imagined run of
    /// zeroes — which would otherwise show as a false full stop at both ends.
    private static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, values.count > 1 else { return values }
        // An odd window keeps the centre sample on a centre sample. An even one
        // is floored to odd, so this never silently becomes asymmetric.
        let half = max(1, (window - 1) / 2)
        var out = [Double](repeating: 0, count: values.count)
        for i in values.indices {
            let lower = max(0, i - half)
            let upper = min(values.count - 1, i + half)
            var sum = 0.0
            for j in lower...upper { sum += values[j] }
            out[i] = sum / Double(upper - lower + 1)
        }
        return out
    }

    /// Cuts a series down to at most `maxPoints`, keeping the shape of it.
    ///
    /// A two-hour drive is tens of thousands of samples and a chart cannot draw
    /// that, but plain `stride` sampling would drop exactly the points that
    /// matter: a single hard braking event between two kept samples vanishes.
    /// So each bucket keeps the point furthest from zero acceleration — a stride
    /// sample for the shape, and the peak of whatever was skipped.
    private static func decimate(_ points: [Point], maxPoints: Int) -> [Point] {
        guard maxPoints > 0, points.count > maxPoints else { return points }
        let bucketSize = Int(ceil(Double(points.count) / Double(maxPoints)))
        var out: [Point] = []
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < points.count {
            let end = min(i + bucketSize, points.count)
            var best = points[i]
            for j in (i + 1)..<end where abs(points[j].accel) > abs(best.accel) {
                best = points[j]
            }
            out.append(best)
            i = end
        }
        return out
    }
}
