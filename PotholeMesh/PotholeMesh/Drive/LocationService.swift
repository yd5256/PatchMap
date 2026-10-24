//
//  LocationService.swift
//  PotholeMesh
//
//  When-In-Use `CLLocationManager` wrapper (Requirement 16). Updates run only during a
//  Drive session, inaccurate or stale fixes are dropped, and only the latest accepted
//  fix is kept, in memory (9.6). No background location.
//

import CoreLocation
import Foundation
import Observation

nonisolated enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case whenInUse
    case denied
    case restricted

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        // The app never requests Always; treat it like When-In-Use if granted elsewhere.
        case .authorizedWhenInUse, .authorizedAlways: self = .whenInUse
        @unknown default: self = .notDetermined
        }
    }

    var isDeniedOrRestricted: Bool { self == .denied || self == .restricted }
}

/// One accepted location fix. Speed is nil when the fix reported it as unknown.
nonisolated struct LocationFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyM: Double
    let speedMps: Double?
    let timestamp: Date

    func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(timestamp)
    }

    /// No older than `maxFixAgeSeconds` with accuracy within `maxHorizontalAccuracyM`.
    func isFresh(at now: Date, config: DetectionConfig = .standard) -> Bool {
        age(at: now) <= config.maxFixAgeSeconds
            && horizontalAccuracyM >= 0
            && horizontalAccuracyM <= config.maxHorizontalAccuracyM
    }

    /// Applies the acceptance filter (Requirement 16.4, 16.5). Returns nil for fixes with
    /// negative or > 20 m accuracy, or older than 5 s; exactly 20 m and exactly 5 s pass.
    /// A negative speed becomes nil (unknown).
    static func accepting(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        speed: Double,
        timestamp: Date,
        now: Date,
        config: DetectionConfig = .standard
    ) -> LocationFix? {
        guard horizontalAccuracy >= 0,
              horizontalAccuracy <= config.maxHorizontalAccuracyM,
              now.timeIntervalSince(timestamp) <= config.maxFixAgeSeconds else {
            return nil
        }
        return LocationFix(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyM: horizontalAccuracy,
            speedMps: speed >= 0 ? speed : nil,
            timestamp: timestamp
        )
    }
}

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: LocationAuthorization = .notDetermined
    /// The latest accepted fix. Replaced on every accepted fix; cleared when updates stop.
    private(set) var latestFix: LocationFix?
    /// True once any fix (accepted or not) arrived during the current session, which
    /// lets the Drive tab tell "searching" from "poor".
    private(set) var hasReceivedAnyFix = false
    private(set) var isUpdating = false

    /// Called with each accepted fix while updating.
    @ObservationIgnored var onFix: ((LocationFix) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let config: DetectionConfig
    @ObservationIgnored private let now: () -> Date

    init(config: DetectionConfig = .standard, now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = false
        authorization = LocationAuthorization(manager.authorizationStatus)
    }

    /// Requests When-In-Use authorization if needed and starts updates.
    func start() {
        guard !isUpdating else { return }
        latestFix = nil
        hasReceivedAnyFix = false
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        isUpdating = true
    }

    /// Stops updates and drops the last fix; nothing more is published until `start()`.
    func stop() {
        manager.stopUpdatingLocation()
        isUpdating = false
        latestFix = nil
        hasReceivedAnyFix = false
    }

    // MARK: Ingest

    /// Filters and publishes one raw fix. Internal so tests can drive it without hardware.
    func receive(latitude: Double, longitude: Double, horizontalAccuracy: Double, speed: Double, timestamp: Date) {
        guard isUpdating else { return }
        hasReceivedAnyFix = true
        guard let fix = LocationFix.accepting(
            latitude: latitude, longitude: longitude,
            horizontalAccuracy: horizontalAccuracy, speed: speed,
            timestamp: timestamp, now: now(), config: config
        ) else { return }
        latestFix = fix
        onFix?(fix)
    }

    // MARK: CLLocationManagerDelegate (delivered on the main run loop that created the manager)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = LocationAuthorization(manager.authorizationStatus)
        MainActor.assumeIsolated {
            self.authorization = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Only the newest location matters; no trail is kept.
        guard let location = locations.last else { return }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy
        let speed = location.speed
        let timestamp = location.timestamp
        MainActor.assumeIsolated {
            self.receive(latitude: latitude, longitude: longitude,
                         horizontalAccuracy: accuracy, speed: speed, timestamp: timestamp)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (e.g. no fix yet) leave the latest fix as-is; GPS status
        // degrades to searching/poor on its own as the fix ages out.
    }
}
