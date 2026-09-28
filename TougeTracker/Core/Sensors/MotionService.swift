import Foundation
import CoreMotion
import CoreMedia
import QuartzCore
import CoreLocation

/// Fused vehicle-frame acceleration sample from CoreMotion.
public struct GForceSample: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var forwardG: Double      // + accelerating, − braking
    public var lateralG: Double       // + right turn
    public var yawRate: Double        // rad/s, + right turn
    public var fromAccelerometer: Bool
}

/// Pure, testable math that rotates device-frame sensor readings into the
/// vehicle frame, auto-detecting the rotation-matrix convention from gravity so
/// the result is robust to Apple's undocumented direction of CMRotationMatrix.
public enum VehicleFrameMath {
    /// Projects device-frame acceleration/rotation-rate into vehicle frame.
    ///
    /// - Parameters:
    ///   - acc: device-frame user acceleration (g units), z out of the screen.
    ///   - gravity: device-frame gravity vector.
    ///   - matrix: `CMAttitude.rotationMatrix` (row-major m11..m33).
    ///   - courseRadians: vehicle heading clockwise from true north.
    /// - Returns: (forwardG, lateralG, yawRate, fromAccelerometer) in vehicle frame.
    public static func project(acceleration acc: SIMD3<Double>,
                               gravity g: SIMD3<Double>,
                               matrix m: CMRotationMatrix,
                               courseRadians c: Double) -> GForceSample {
        // Two candidate transforms (device→reference). The correct one maps the
        // measured gravity vector to (0, 0, −1) in the reference frame.
        func ref(_ v: SIMD3<Double>, ccw: Bool) -> SIMD3<Double> {
            if ccw {  // v_ref = Mᵀ · v  (convention B)
                return SIMD3<Double>(
                    m.m11 * v.x + m.m21 * v.y + m.m31 * v.z,
                    m.m12 * v.x + m.m22 * v.y + m.m32 * v.z,
                    m.m13 * v.x + m.m23 * v.y + m.m33 * v.z)
            } else {   // v_ref = M · v  (convention A)
                return SIMD3<Double>(
                    m.m11 * v.x + m.m12 * v.y + m.m13 * v.z,
                    m.m21 * v.x + m.m22 * v.y + m.m23 * v.z,
                    m.m31 * v.x + m.m32 * v.y + m.m33 * v.z)
            }
        }
        let ga = ref(g, ccw: false)
        let gb = ref(g, ccw: true)
        let errA = abs(ga.z + 1)
        let errB = abs(gb.z + 1)
        let ccw = errB < errA   // convention B wins iff it puts gravity closer to down
        let accRef = ref(acc, ccw: ccw)
        let om = SIMD3<Double>(accRef.x, accRef.y, accRef.z)
        let _ = om
        // Reference frame: x = north, y = west, z = up (CoreMotion north-referenced frames).
        // Course c measured clockwise from north.
        let cosC = cos(c), sinC = sin(c)
        let forwardG = accRef.x * cosC - accRef.y * sinC
        let lateralG = -accRef.x * sinC - accRef.y * cosC
        let gSample = GForceSample(timestamp: CACurrentMediaTime(),
                                   forwardG: forwardG, lateralG: lateralG,
                                   yawRate: 0, fromAccelerometer: true)
        return gSample
    }

    /// Vertical-axis yaw rate (rad/s, + right turn) from a 3×3 rotation-rate vector
    /// expressed in the reference frame, using the same convention auto-detection.
    public static func verticalYawRate(rotationRate omega: SIMD3<Double>,
                                       gravity g: SIMD3<Double>,
                                       matrix m: CMRotationMatrix) -> Double {
        func ref(_ v: SIMD3<Double>, ccw: Bool) -> SIMD3<Double> {
            if ccw {
                return SIMD3<Double>(
                    m.m11 * v.x + m.m21 * v.y + m.m31 * v.z,
                    m.m12 * v.x + m.m22 * v.y + m.m32 * v.z,
                    m.m13 * v.x + m.m23 * v.y + m.m33 * v.z)
            }
            return SIMD3<Double>(
                m.m11 * v.x + m.m12 * v.y + m.m13 * v.z,
                m.m21 * v.x + m.m22 * v.y + m.m23 * v.z,
                m.m31 * v.x + m.m32 * v.y + m.m33 * v.z)
        }
        let ga = ref(g, ccw: false)
        let ccw = abs(ref(g, ccw: true).z + 1) < abs(ga.z + 1)
        let omg = ref(omega, ccw: ccw)
        return -omg.z
    }
}

/// Wraps CMMotionManager, fusing CoreMotion into vehicle-frame g-forces.
@MainActor
public final class MotionService: NSObject {
    public static let sampleRate: Double = 50
    private let manager = CMMotionManager()
    private var latestSample: GForceSample?
    public private(set) var latest: GForceSample? {
        get { latestSample }
        set { latestSample = newValue }
    }
    private var courseRadians: Double?
    private var haveHeading = false

    public var onSample: ((GForceSample) -> Void)?

    public var isAvailable: Bool { manager.isDeviceMotionAvailable }

    public func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / Self.sampleRate
        let frame: CMAttitudeReferenceFrame = .xTrueNorthZVertical
        manager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] dm, _ in
            self?.handle(dm)
        }
    }

    public func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// GPS-derived course + heading; drives vehicle-frame alignment when speed > 5 m/s.
    public func updateCourse(degrees: Double, speed: Double) {
        guard degrees >= 0, speed > 5 else { return }
        courseRadians = degrees * .pi / 180
        haveHeading = true
    }

    public func handle(_ data: CMDeviceMotion?) {
        guard let data, haveHeading else {
            latest = nil
            return
        }
        let a = SIMD3<Double>(Double(data.userAcceleration.x),
                              Double(data.userAcceleration.y),
                              Double(data.userAcceleration.z))
        let g = SIMD3<Double>(Double(data.gravity.x),
                              Double(data.gravity.y),
                              Double(data.gravity.z))
        let omega = SIMD3<Double>(Double(data.rotationRate.x),
                                  Double(data.rotationRate.y),
                                  Double(data.rotationRate.z))
        let matrix = data.attitude.rotationMatrix
        let forward = VehicleFrameMath.project(acceleration: a, gravity: g,
                                               matrix: matrix,
                                               courseRadians: courseRadians!)
        var s = forward
        s.yawRate = VehicleFrameMath.verticalYawRate(rotationRate: omega,
                                                      gravity: g,
                                                      matrix: matrix)
        s.timestamp = CACurrentMediaTime()
        s.forwardG = forward.forwardG
        s.lateralG = forward.lateralG
        latest = s
        onSample?(s)
    }
}
