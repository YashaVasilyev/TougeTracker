import Foundation
import CoreLocation
import CoreMotion
import Observation
import QuartzCore
import SwiftData

/// Engine powering the Drive tab: owns the GPS + motion sensors, the live
/// pacenote navigator, the telemetry sample stream, and the HUD state machine
/// (idle → recording → paused → finished). Inject via `.environment(DriveEngine.shared)`.
@MainActor
@Observable
public final class DriveEngine: NSObject, CLLocationManagerDelegate {
    public static let shared = DriveEngine()

    // MARK: - Public observable state

    public private(set) var state: RecordingState = .idle
    public private(set) var currentSpeedMps: Double = 0
    public private(set) var forwardG: Double = 0
    public private(set) var lateralG: Double = 0
    public private(set) var currentNote: String?
    public private(set) var nextNotes: [String] = []
    public private(set) var progress: Double = 0
    public private(set) var offRoute = false
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var currentDistance: Double = 0
    public private(set) var lastLocation: CLLocationCoordinate2D?
    public private(set) var locationAuthorized = false
    public private(set) var lastFixAccuracy: Double = -1
    public private(set) var locationTick: Int = 0
    public var toast: String? = nil

    public private(set) var drivenPath: [CLLocationCoordinate2D] = []
    public private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    public private(set) var pacenoteAnnotations: [TurnMarker] = []

    public var onSave: ((Drive) -> Void)?
    public private(set) var lastDrive: Drive?

    // MARK: - Internal

    private let settings = AppSettings.shared
    private let locationMgr = CLLocationManager()
    private let motion = MotionService()
    private var navigator: PacenoteNavigator?
    private var timer: Timer?

    private var samples: [TelemetrySample] = []
    private var driveStart = Date()
    private var startMediaTime: TimeInterval = 0
    private var lastProgressTick: TimeInterval = 0
    private var accumulatedDist: Double = 0
    private var latestLocation: CLLocation?
    private var lastGPS: CLLocation?

    private var currentRouteName: String?
    private var currentRouteID: Int64?

    private override init() {
        super.init()
        locationMgr.delegate = self
        locationMgr.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationMgr.activityType = .automotiveNavigation
        locationMgr.pausesLocationUpdatesAutomatically = false
        locationMgr.allowsBackgroundLocationUpdates = true
        locationMgr.showsBackgroundLocationIndicator = true
    }

    // MARK: - Lifecycle

    public func start(route: RecordedRoute? = nil) {
        // Starting while already running would leak the old timer: it is only
        // reachable through `timer`, so the first one would never be
        // invalidated, and both would tick at 20Hz.
        if timer != nil { timer?.invalidate(); timer = nil }
        currentRouteID = route?.roadID
        currentRouteName = route?.name
        if let r = route, !r.coordinates.isEmpty {
            navigator = PacenoteNavigator(coordinates: r.coordinates)
            navigator?.callDistanceScale = settings.callDistanceScale
            routeCoordinates = r.coordinates
        } else {
            navigator = nil
            routeCoordinates = []
        }
        pacenoteAnnotations = navigator?.pacenotes.enumerated().map { _, note in
            TurnMarker(coordinate: note.apex.clLocation,
                       title: note.text, subtitle: "")
        } ?? []

        samples.removeAll()
        drivenPath.removeAll()
        currentNote = nil
        nextNotes = []
        progress = 0
        offRoute = false
        forwardG = 0
        lateralG = 0
        currentSpeedMps = 0
        elapsed = 0
        currentDistance = 0
        lastFixAccuracy = -1

        driveStart = Date()
        startMediaTime = CACurrentMediaTime()
        lastProgressTick = startMediaTime
        accumulatedDist = 0
        latestLocation = nil
        lastGPS = nil
        state = .recording

        requestAuthorizationIfNeeded()
        locationMgr.startUpdatingLocation()
        locationMgr.startUpdatingHeading()
        motion.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func pause() {
        guard state == .recording else { return }
        state = .paused
        locationMgr.stopUpdatingLocation()
        motion.stop()
        timer?.invalidate()
        timer = nil
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
        locationMgr.startUpdatingLocation()
        motion.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Stops the drive and returns the finalized `Drive` record.
    @discardableResult
    public func stop() -> Drive? {
        guard state == .recording || state == .paused else { return nil }
        state = .finished
        locationMgr.stopUpdatingLocation()
        motion.stop()
        timer?.invalidate()
        timer = nil
        let drive = buildDrive()
        lastDrive = drive
        onSave?(drive)
        onSave = nil
        return drive
    }

    /// Leaves the finished-drive summary and returns the Drive tab to its
    /// starting state.
    ///
    /// The drive has already been persisted by `stop()`, so this only clears the
    /// on-screen summary. `navigator` is dropped as well: leaving it in place
    /// would let a subsequent drive inherit the previous route's notes if a new
    /// route were never supplied.
    public func dismissLastDrive() {
        guard state == .finished else { return }
        state = .idle
        lastDrive = nil
        navigator = nil
        routeCoordinates = []
        pacenoteAnnotations = []
        drivenPath = []
        currentNote = nil
        nextNotes = []
        progress = 0
        offRoute = false
        forwardG = 0
        lateralG = 0
        currentSpeedMps = 0
        elapsed = 0
        currentDistance = 0
        currentRouteID = nil
        currentRouteName = nil
    }

    private func requestAuthorizationIfNeeded() {
        let status = locationMgr.authorizationStatus
        locationAuthorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
        if status == .notDetermined {
            locationMgr.requestWhenInUseAuthorization()
        }
    }

    public func requestAuthorization() {
        requestAuthorizationIfNeeded()
        motion.start()
    }

    // MARK: - 20 Hz fusion tick

    private func tick() {
        guard state == .recording, let loc = latestLocation,
              loc.coordinate.latitude.isFinite else { return }

        let t = CACurrentMediaTime() - startMediaTime
        currentSpeedMps = max(0, loc.speed)
        lastLocation = loc.coordinate
        lastFixAccuracy = loc.horizontalAccuracy

        if let nav = navigator {
            if let call = nav.update(location: loc, speed: currentSpeedMps) {
                announce(call)
            }
            progress = nav.progress
            offRoute = nav.offRoute
            nextNotes = (nav.pacenotes)
                .dropFirst(min(nav.nextNoteIndex, nav.pacenotes.count))
                .prefix(2)
                .map { PacenoteGenerator.formatted($0, format: settings.pacenoteFormat) }
        }

        let m = motion.latest
        let sample = TelemetrySample(
            t: t, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
            speed: loc.speed >= 0 ? Float(loc.speed) : Float(currentSpeedMps),
            course: Float(loc.course), altitude: Float(loc.altitude),
            forwardG: Float(m?.forwardG ?? 0), lateralG: Float(m?.lateralG ?? 0),
            yawRate: Float(m?.yawRate ?? 0))
        samples.append(sample)

        if t - lastProgressTick >= 0.05 || samples.count == 1 {
            lastProgressTick = t
            drivenPath.append(loc.coordinate)
        }

        elapsed = t
        forwardG = m?.forwardG ?? forwardG
        lateralG = m?.lateralG ?? lateralG
        currentDistance = accumulatedDist
    }

    // MARK: - Location delegate

    // CLLocationManager delivers on the queue its manager was created on, which
    // is the main queue, so the hop below is not a hop in practice. It is written
    // as `assumeIsolated` rather than `Task { @MainActor in }` on purpose: a Task
    // can be scheduled late and land after a newer fix, and on a drive recorder
    // that means the track is out of order.
    nonisolated public func locationManager(_ manager: CLLocationManager,
                                           didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated {
            let prev = lastGPS
            lastGPS = loc
            latestLocation = loc
            lastLocation = loc.coordinate
            locationTick += 1

            if loc.speed >= 0 {
                currentSpeedMps = max(0, loc.speed)
                motion.updateCourse(degrees: loc.course, speed: loc.speed)
            }

            // Only accumulate between fixes that are actually usable: an
            // accuracy of -1 means invalid and a jump of kilometres otherwise.
            if let p = prev, p.horizontalAccuracy >= 0, p.horizontalAccuracy <= 60,
               loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 60 {
                accumulatedDist += GeoMath.distanceMeters(GeoPoint.from(p.coordinate),
                                                          GeoPoint.from(loc.coordinate))
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager,
                                           didChangeAuthorization status: CLAuthorizationStatus) {
        let authorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
        MainActor.assumeIsolated { locationAuthorized = authorized }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager,
                                           didFailWithError error: any Error) {
        if (error as? CLError)?.code == .locationUnknown { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated { toast = message }
    }

    // MARK: - Co-driver

    private func announce(_ call: PacenoteCall) {
        let fmt = settings.pacenoteFormat
        var displayParts: [String] = []
        for (i, item) in call.items.enumerated() {
            // A straight shows as a bare distance so the HUD reads the same way
            // the co-driver calls it: "3 L · 100 · 2 R".
            if item.note.isStraight {
                let length = max(Int((item.note.length / 10).rounded(.down) * 10), 10)
                displayParts.append("\(length) m")
                continue
            }
            let text = PacenoteGenerator.formatted(item.note, format: fmt)
            if i == 0 {
                var p = text
                if item.remaining > 12 {
                    p = "\(Int((item.remaining / 10).rounded(.down) * 10)) m \(text)"
                }
                displayParts.append(p)
            } else if let connector = item.connector {
                displayParts.append("\(connector) \(text)")
            } else {
                displayParts.append(text)
            }
        }
        currentNote = displayParts.joined(separator: " · ")

        if let nav = navigator {
            nextNotes = nav.upcoming(count: 2).map {
                PacenoteGenerator.formatted($0, format: fmt)
            }
        } else {
            nextNotes = []
        }

        CoDriverSpeaker.shared.speakCall(call, format: fmt)
    }

    // MARK: - Drive assembly

    private func buildDrive() -> Drive {
        let end = Date()
        let dur = end.timeIntervalSince(driveStart)
        // One pass, not four. A long drive is tens of thousands of samples and
        // this ran at the end of every one, building four throwaway arrays to
        // take four maxima.
        var maxSpeed = Float(0), maxLat = Float(0), maxFwd = Float(0), maxBrake = Float(0)
        for s in samples {
            maxSpeed = max(maxSpeed, s.speed)
            maxLat = max(maxLat, abs(s.lateralG))
            maxFwd = max(maxFwd, max(0, s.forwardG))
            maxBrake = max(maxBrake, max(0, -s.forwardG))
        }
        return Drive(
            startedAt: driveStart, endedAt: end,
            routeName: currentRouteName, routeID: currentRouteID,
            distanceMeters: accumulatedDist, durationSeconds: dur,
            maxSpeed: Double(maxSpeed), maxLateralG: Double(maxLat),
            maxForwardG: Double(maxFwd), maxBrakeG: Double(maxBrake), samples: samples)
    }
}
