import CoreLocation

/// Single-shot current location via `requestLocation`, suitable for UI one-shots
/// (route browsing "Near me", initial map framing).
@MainActor
public final class LocationReader: NSObject, ObservableObject {
    @Published public private(set) var coordinate: CLLocationCoordinate2D?
    @Published public private(set) var loading: Bool = false
    @Published public var authorization: CLAuthorizationStatus = .notDetermined

    private var pending: CheckedContinuation<CLLocation, Error>?
    private let mgr = CLLocationManager()

    public override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func requestAuthorization() {
        authorization = mgr.authorizationStatus
        if authorization == .notDetermined {
            mgr.requestWhenInUseAuthorization()
        }
    }

    /// Returns the last known coordinate, or waits (up to the system timeout)
    /// for a fresh fix. Throws if location services are denied/unavailable.
    public func currentLocation() async throws -> CLLocation {
        if let c = coordinate {
            return CLLocation(latitude: c.latitude, longitude: c.longitude)
        }
        requestAuthorization()
        loading = true
        defer { loading = false }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
            pending = cont
            mgr.requestLocation()
        }
    }
}

extension LocationReader: CLLocationManagerDelegate {
    // The manager delivers on the main queue, so `assumeIsolated` is a
    // statement of fact rather than a hop. Resuming a continuation has to be
    // ordered with the delegate call that resumed it, which a Task would not
    // guarantee.
    nonisolated public func locationManager(_ manager: CLLocationManager,
                                           didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated {
            coordinate = loc.coordinate
            if let cont = pending {
                pending = nil
                cont.resume(returning: loc)
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager,
                                           didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if let cont = pending {
                pending = nil
                cont.resume(throwing: error)
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager,
                                           didChangeAuthorization status: CLAuthorizationStatus) {
        let shouldRequest = (status == .authorizedWhenInUse || status == .authorizedAlways)
        if shouldRequest { manager.requestLocation() }
        MainActor.assumeIsolated { authorization = status }
    }
}
