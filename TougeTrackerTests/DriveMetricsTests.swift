import XCTest
@testable import TougeTracker

/// The numbers on the post-drive screen, and the derivative underneath them.
///
/// The acceleration trace is the one thing here that can be wrong in a way that
/// still looks like a chart: a per-sample difference of a jittery GPS speed
/// produces a plausible-looking trace of nonsense. These pin the cases that
/// produce nonsense — uneven sample spacing, repeated timestamps, noise, and
/// decimation that would otherwise swallow a braking event.
final class DriveMetricsTests: XCTestCase {

    /// A sample with only the fields the arithmetic reads.
    private func sample(t: Double, speed: Float) -> TelemetrySample {
        TelemetrySample(t: t, lat: 0, lon: 0, speed: speed, course: 0,
                        altitude: 0, forwardG: 0, lateralG: 0, yawRate: 0)
    }

    /// Evenly spaced samples, one second apart.
    private func ramp(count: Int, speedAt: (Int) -> Float) -> [TelemetrySample] {
        (0..<count).map { sample(t: Double($0), speed: speedAt($0)) }
    }

    // MARK: - Average speed

    func testAverageSpeedIsDistanceOverTime() {
        // 2 km in 100 s is 20 m/s, and not the 25 m/s the sampled speeds would
        // average to if the GPS had been running the whole way.
        XCTAssertEqual(DriveMetrics.averageSpeed(distanceMeters: 2000, durationSeconds: 100),
                       20, accuracy: 0.0001)
    }

    func testAverageSpeedIsZeroForAnEmptyDrive() {
        // A drive that recorded no time must not report an average of infinity,
        // and one that recorded no distance must not report a divide-by-zero.
        XCTAssertEqual(DriveMetrics.averageSpeed(distanceMeters: 0, durationSeconds: 100), 0)
        XCTAssertEqual(DriveMetrics.averageSpeed(distanceMeters: 2000, durationSeconds: 0), 0)
        XCTAssertEqual(DriveMetrics.averageSpeed(distanceMeters: 0, durationSeconds: 0), 0)
    }

    func testAverageSpeedRejectsNegativeDuration() {
        // A clock that went backwards mid-drive would otherwise produce a
        // negative average speed and a nonsensical stat tile.
        XCTAssertEqual(DriveMetrics.averageSpeed(distanceMeters: 2000, durationSeconds: -5), 0)
    }

    // MARK: - Acceleration

    func testConstantSpeedHasNoAcceleration() {
        let points = DriveMetrics.series(from: ramp(count: 20) { _ in 30 }, smoothWindow: 1)
        XCTAssertEqual(points.count, 20)
        for p in points {
            XCTAssertEqual(p.accel, 0, accuracy: 0.0001, "flat speed should be flat acceleration")
        }
    }

    func testAccelerationIsTheDerivativeOfSpeed() {
        // 1 m/s per second, sampled once a second: 1 m/s².
        let points = DriveMetrics.series(from: ramp(count: 10) { Float($0) }, smoothWindow: 1)
        // Interior points have both neighbours, so the central difference is exact.
        for p in points[1..<(points.count - 1)] {
            XCTAssertEqual(p.accel, 1, accuracy: 0.0001, "expected +1 m/s² at t=\(p.t)")
        }
    }

    func testBrakingIsNegative() {
        // Speed falling 2 m/s per second must read as braking, not acceleration.
        let points = DriveMetrics.series(from: ramp(count: 10) { Float(20 - $0 * 2) },
                                         smoothWindow: 1)
        for p in points[1..<(points.count - 1)] {
            XCTAssertEqual(p.accel, -2, accuracy: 0.0001, "expected -2 m/s² at t=\(p.t)")
        }
    }


    /// The bug this guards: Core Location does not deliver samples on a regular
    /// cadence, and dividing by the sample index instead of elapsed time turns a
    /// gentle, real acceleration into a huge apparent one.
    func testAccelerationUsesElapsedTimeNotSampleIndex() {
        // 10 samples a second apart, gaining 1 m/s each: 1 m/s².
        let even = (0..<10).map { sample(t: Double($0), speed: Float($0)) }
        XCTAssertEqual(DriveMetrics.series(from: even, smoothWindow: 1)[5].accel,
                       1, accuracy: 0.0001)

        // The same ten samples two seconds apart: 10 m/s gained over 20 s is
        // 0.5 m/s². A per-sample difference would still report 1.
        let stretched = (0..<10).map { sample(t: Double($0) * 2, speed: Float($0)) }
        XCTAssertEqual(DriveMetrics.series(from: stretched, smoothWindow: 1)[5].accel,
                       0.5, accuracy: 0.0001, "10 m/s over 20 s is 0.5 m/s²")
    }

    func testRepeatedTimestampsProduceNoInfinity() {
        // Two samples at the same instant have no interval between them, so
        // there is nothing to divide by. A drive that briefly lost the radio
        // really does produce these.
        let samples = [
            sample(t: 0, speed: 20),
            sample(t: 1, speed: 20),
            sample(t: 1, speed: 30),   // same t as the previous sample
            sample(t: 2, speed: 30),
        ]
        for p in DriveMetrics.series(from: samples, smoothWindow: 1) {
            XCTAssertTrue(p.accel.isFinite, "acceleration must never be infinite")
        }
    }

    func testSmoothingSuppressesGPSJitter() {
        // Alternating ±2 m/s around 30, with no real change in speed. Unsmoothed
        // this reads as violent acceleration and braking; smoothed it is flat,
        // which is the entire reason the moving average is there.
        let jittery = ramp(count: 40) { $0.isMultiple(of: 2) ? 28 : 32 }
        let smoothed = DriveMetrics.series(from: jittery, smoothWindow: 5)
        let raw = DriveMetrics.series(from: jittery, smoothWindow: 1)

        let smoothedPeak = smoothed.map { abs($0.accel) }.max() ?? .infinity
        let rawPeak = raw.map { abs($0.accel) }.max() ?? 0
        XCTAssertLessThan(smoothedPeak, rawPeak,
                          "smoothing must reduce the peak the jitter produces")
        // 4 m/s of swing alternating every second: the raw derivative peaks at
        // 8 m/s². Smoothing over 5 samples has to cut that well below 2.
        XCTAssertLessThan(smoothedPeak, 2.0, "jitter must not survive as real acceleration")
    }

    func testSmoothingDoesNotInventAStopAtTheEndsOfTheDrive() {
        // A drive that starts and ends at 30 m/s. Padding the moving average
        // with zeroes — the obvious way to handle the edges — would show a full
        // stop at both ends, on a trace that is meant to be the truth.
        let points = DriveMetrics.series(from: ramp(count: 30) { _ in 30 }, smoothWindow: 5)
        XCTAssertEqual(points.first?.speed ?? 0, 30, accuracy: 0.0001)
        XCTAssertEqual(points.last?.speed ?? 0, 30, accuracy: 0.0001)
    }

    func testSingleSampleIsAPointWithNoAcceleration() {
        let points = DriveMetrics.series(from: [sample(t: 0, speed: 25)])
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.speed ?? 0, 25, accuracy: 0.0001)
        XCTAssertEqual(points.first?.accel ?? -1, 0, accuracy: 0.0001)
    }

    func testEmptySeriesIsEmpty() {
        XCTAssertTrue(DriveMetrics.series(from: []).isEmpty)
    }

    // MARK: - Decimation

    func testDecimationRespectsTheBudget() {
        let points = DriveMetrics.series(from: ramp(count: 10_000) { Float($0 % 90) },
                                         maxPoints: 500)
        XCTAssertLessThanOrEqual(points.count, 500)
    }

    /// The reason decimation is not a `stride`. A single hard braking event
    /// between two kept samples is the most interesting thing on the chart, and
    /// sampling the series at a fixed interval drops it.
    func testDecimationKeepsTheHardestBraking() {
        // 5,000 samples climbing gently, with one sample of hard braking
        // dropped in the middle.
        var samples = ramp(count: 5_000) { Float($0) * 0.01 }
        samples[2_500] = sample(t: 2_500, speed: 5)   // a hard stop, momentarily
        let points = DriveMetrics.series(from: samples, smoothWindow: 1, maxPoints: 200)
        XCTAssertTrue(points.contains { $0.accel < -1 },
                      "the braking spike must survive decimation")
    }

    func testDecimationIsANoOpWhenAlreadySmall() {
        let points = DriveMetrics.series(from: ramp(count: 50) { Float($0) }, maxPoints: 500)
        XCTAssertEqual(points.count, 50, "a series under the budget is untouched")
    }

    func testTimesAreNonDecreasingAfterDecimation() {
        // The charts index by time and scrub by nearest-t, so a reordered
        // series would draw a line that folds back on itself.
        let points = DriveMetrics.series(from: ramp(count: 3_000) { Float($0 % 70) },
                                         smoothWindow: 1, maxPoints: 300)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertLessThanOrEqual(a.t, b.t, "series must stay in time order")
        }
    }
}
