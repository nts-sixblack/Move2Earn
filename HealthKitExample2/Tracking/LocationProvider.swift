//
//  LocationProvider.swift
//  HealthKitExample2
//
//  GPS tracking that keeps running in the background (UIBackgroundModes =
//  location + CLBackgroundActivitySession), and — with "Always" permission —
//  significant-change monitoring so iOS relaunches the app after it has been
//  terminated, letting the session resume and back-fill.
//

import CoreLocation
import Foundation

enum LocationAuth: String, Codable {
    case notDetermined, denied, restricted, whenInUse, always

    var canTrack: Bool { self == .whenInUse || self == .always }
}

protocol LocationTracking: AnyObject {
    var onPoints: (([LocationPoint]) -> Void)? { get set }
    var onAuthorizationChange: ((LocationAuth) -> Void)? { get set }
    var authorization: LocationAuth { get }
    var preciseLocation: Bool { get }
    func requestWhenInUse()
    func requestAlways()
    func start(config: TrackingConfig)
    func stop()
}

final class LocationProvider: NSObject, LocationTracking, CLLocationManagerDelegate {
    var onPoints: (([LocationPoint]) -> Void)?
    var onAuthorizationChange: ((LocationAuth) -> Void)?

    private let manager = CLLocationManager()
    /// `CLBackgroundActivitySession` on iOS 17+ (stored untyped so the app runs on iOS 15).
    private var backgroundSession: AnyObject?
    private(set) var isRunning = false

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: LocationAuth { Self.map(manager.authorizationStatus) }
    var preciseLocation: Bool { manager.accuracyAuthorization == .fullAccuracy }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    func start(config: TrackingConfig) {
        guard authorization.canTrack else { return }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = config.gpsDistanceFilter > 0 ? config.gpsDistanceFilter : kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if authorization == .always, CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        if #available(iOS 17.0, *), backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        isRunning = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        if #available(iOS 17.0, *) { (backgroundSession as? CLBackgroundActivitySession)?.invalidate() }
        backgroundSession = nil
        isRunning = false
    }

    // MARK: CLLocationManagerDelegate (delivered on the main thread: manager was created there)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let points = locations.map(Self.point)
        MainActor.assumeIsolated { onPoints?(points) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let auth = Self.map(manager.authorizationStatus)
        MainActor.assumeIsolated { onAuthorizationChange?(auth) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            _ = EventLogger.shared.log("locationError", level: .warning, ["error": message])
        }
    }

    nonisolated static func point(_ l: CLLocation) -> LocationPoint {
        LocationPoint(t: l.timestamp, lat: l.coordinate.latitude, lon: l.coordinate.longitude, alt: l.altitude,
                      hAcc: l.horizontalAccuracy, vAcc: l.verticalAccuracy, speed: l.speed,
                      speedAcc: l.speedAccuracy, course: l.course,
                      simulated: l.sourceInformation?.isSimulatedBySoftware ?? false,
                      accessory: l.sourceInformation?.isProducedByAccessory ?? false)
    }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuth {
        switch status {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
}
