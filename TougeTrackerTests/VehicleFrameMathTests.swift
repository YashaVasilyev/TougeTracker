import XCTest
@testable import TougeTracker
import CoreMotion

/// Tests the vehicle-frame g-force projection math.
/// Uses identity rotation matrices (convention-unambiguous) plus one general
/// rotation to exercise the runtime convention-detection in `VehicleFrameMath`.
final class VehicleFrameMathTests: XCTestCase {

    private let tol = 1e-9

    // MARK: - Identity (device frame == reference frame)

    func testPureForwardAcceleration() {
        let m = identityMatrix()
        let g = VehicleFrameMath.project(acceleration: SIMD3<Double>(0.5, 0, 0),
                                         gravity: SIMD3<Double>(0, 0, -1),
                                         matrix: m, courseRadians: 0)
        XCTAssertEqual(g.forwardG, 0.5, accuracy: tol)
        XCTAssertEqual(g.lateralG, 0, accuracy: tol)
    }

    func testLateralLeftAcceleration() {
        let m = identityMatrix()
        let g = VehicleFrameMath.project(acceleration: SIMD3<Double>(0, 0.5, 0),
                                         gravity: SIMD3<Double>(0, 0, -1),
                                         matrix: m, courseRadians: 0)
        XCTAssertEqual(g.forwardG, 0, accuracy: tol)
        XCTAssertEqual(g.lateralG, -0.5, accuracy: tol) // negative = left
    }

    func testCourse90RotatesFrame() {
        // Facing east: device +y (reference west) is backward; device −y (east) → forward.
        let m = identityMatrix()
        let g = VehicleFrameMath.project(acceleration: SIMD3<Double>(0, -1, 0),
                                         gravity: SIMD3<Double>(0, 0, -1),
                                         matrix: m, courseRadians: .pi / 2)
        XCTAssertEqual(g.forwardG, 1, accuracy: tol)
        XCTAssertEqual(g.lateralG, 0, accuracy: tol)
    }

    // MARK: - Yaw rate

    func testRightTurnYawRate() {
        // rotationRate (0,0,−0.5): clockwise about up → right turn → +0.5.
        let m = identityMatrix()
        let y = VehicleFrameMath.verticalYawRate(rotationRate: SIMD3<Double>(0, 0, -0.5),
                                                 gravity: SIMD3<Double>(0, 0, -1),
                                                 matrix: m)
        XCTAssertEqual(y, 0.5, accuracy: tol)
    }

    func testLeftTurnYawRate() {
        let m = identityMatrix()
        let y = VehicleFrameMath.verticalYawRate(rotationRate: SIMD3<Double>(0, 0, 0.5),
                                                 gravity: SIMD3<Double>(0, 0, -1),
                                                 matrix: m)
        XCTAssertEqual(y, -0.5, accuracy: tol)
    }

    func testNoCourseReturnsZero() {
        let m = identityMatrix()
        let g = VehicleFrameMath.project(acceleration: SIMD3<Double>(0.5, 0.3, 0),
                                         gravity: SIMD3<Double>(0, 0, -1),
                                         matrix: m, courseRadians: 0)
        // With course=0 the projection still runs; this just checks it executes.
        XCTAssertEqual(g.forwardG, 0.5, accuracy: tol)
    }

    // MARK: - General rotation (validates convention auto-selection)

    func testTiltedDeviceConventionSelection() {
        let axis = normalize(1, 1, 1)
        let m = rotationMatrix(axis: axis, angle: 30.0 * .pi / 180.0)

        // Device gravity reading for orientation m under the correct (A) convention:
        // g_dev = Mᵀ · referenceDown = M⁻¹·(0,0,−1).
        let gDev = SIMD3<Double>(-m.m31, -m.m32, -m.m33)

        let refForward = apply(m, SIMD3<Double>(1, 0, 0))        // reference forward
        let expectedCourse = atan2(-refForward.y, refForward.x)
        let expectedForward = sqrt(refForward.x * refForward.x + refForward.y * refForward.y)

        let g = VehicleFrameMath.project(acceleration: SIMD3<Double>(1, 0, 0),
                                         gravity: gDev,
                                         matrix: m, courseRadians: expectedCourse)

        XCTAssertEqual(g.forwardG, expectedForward, accuracy: 0.02,
                       "Convention selection wrong (got \(g.forwardG), expected \(expectedForward))")
        XCTAssertEqual(abs(g.lateralG), 0, accuracy: 0.03)
    }

    // MARK: - Helpers

    private func identityMatrix() -> CMRotationMatrix {
        CMRotationMatrix(m11: 1, m12: 0, m13: 0,
                         m21: 0, m22: 1, m23: 0,
                         m31: 0, m32: 0, m33: 1)
    }

    private func normalize(_ x: Double, _ y: Double, _ z: Double) -> (x: Double, y: Double, z: Double) {
        let n = sqrt(x * x + y * y + z * z)
        return (x / n, y / n, z / n)
    }

    private func rotationMatrix(axis: (x: Double, y: Double, z: Double), angle: Double) -> CMRotationMatrix {
        let (nx, ny, nz) = axis
        let c = cos(angle), s = sin(angle), sc = 1 - c
        return CMRotationMatrix(
            m11: c + sc * nx * nx,            m12: sc * nx * ny - s * nz,        m13: sc * nx * nz + s * ny,
            m21: sc * nx * ny + s * nz,        m22: c + sc * ny * ny,             m23: sc * ny * nz - s * nx,
            m31: sc * nx * nz - s * ny,        m32: sc * ny * nz + s * nx,        m33: c + sc * nz * nz)
    }

    private func apply(_ m: CMRotationMatrix, _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            m.m11 * v.x + m.m12 * v.y + m.m13 * v.z,
            m.m21 * v.x + m.m22 * v.y + m.m23 * v.z,
            m.m31 * v.x + m.m32 * v.y + m.m33 * v.z)
    }
}
