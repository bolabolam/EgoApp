//
//  SensorDataManager.swift
//  Unitree
//

import CoreLocation
import CoreMotion
import Foundation

final class SensorDataManager: NSObject, ObservableObject {
    @Published var acceleration = SensorVector()
    @Published var rotationRate = SensorVector()
    @Published var attitude = SensorVector()
    @Published var magneticHeading: Double?
    @Published var trueHeading: Double?
    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var altitude: Double?
    @Published var horizontalAccuracy: Double?
    @Published var verticalAccuracy: Double?
    @Published var speed: Double?
    @Published var speedAccuracy: Double?
    @Published var course: Double?
    @Published var courseAccuracy: Double?
    @Published var verticalSpeed: Double?
    @Published var locationTimestamp: Date?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Whether the system location switch is on, for the status row only.
    ///
    /// Deliberately not read here. CLLocationManager.locationServicesEnabled()
    /// blocks on a daemon, and Apple warns about calling it on the main thread
    /// -- which a property initialiser on a @StateObject is. It ran twice on
    /// every launch, once here and once in startLocationUpdates, and both
    /// showed up in the log. Nothing gates on it either: the authorisation
    /// callback below decides whether updates start.
    @Published var isLocationServiceEnabled = false
    @Published var isSimulatedBySoftware: Bool?
    @Published var isProducedByAccessory: Bool?
    
    /// Called on every device-motion sample (~50 Hz) with the raw acceleration
    /// and rotation-rate vectors. Wired up by the view to publish/log IMU at the
    /// full sensor rate, independent of the 5 Hz frame_meta/GPS timer.
    var onImuSample: ((SensorVector, SensorVector) -> Void)?

    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    private var previousLocation: CLLocation?
    private var locationRefreshTimer: Timer?
    /// Counts motion samples so the @Published UI vars update at ~10 Hz instead
    /// of the full 50 Hz, keeping SwiftUI from recomputing `body` 50x/sec.
    private var imuUiThrottle = 0
    
    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
        configureLocationManager()
    }
    
    deinit {
        stopUpdates()
    }
    
    func startUpdates() {
        startMotionUpdates()
        startLocationUpdates()
    }
    
    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        locationRefreshTimer?.invalidate()
        locationRefreshTimer = nil
    }
    
    private func configureLocationManager() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = kCLHeadingFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }
    
    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        motionManager.deviceMotionUpdateInterval = 0.02 // 50 Hz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let accel = SensorVector(
                x: motion.userAcceleration.x,
                y: motion.userAcceleration.y,
                z: motion.userAcceleration.z
            )
            let gyro = SensorVector(
                x: motion.rotationRate.x,
                y: motion.rotationRate.y,
                z: motion.rotationRate.z
            )

            // Publish/log every sample at the full 50 Hz rate.
            self.onImuSample?(accel, gyro)

            // Throttle UI-bound @Published updates to ~10 Hz.
            self.imuUiThrottle += 1
            if self.imuUiThrottle >= 5 {
                self.imuUiThrottle = 0
                self.acceleration = accel
                self.rotationRate = gyro
                self.attitude = SensorVector(
                    x: motion.attitude.roll,
                    y: motion.attitude.pitch,
                    z: motion.attitude.yaw
                )
            }
        }
    }
    
    /// Reads the system switch off the main thread, for display only.
    private func refreshLocationServicesFlag() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            DispatchQueue.main.async { self?.isLocationServiceEnabled = enabled }
        }
    }

    private func startLocationUpdates() {
        authorizationStatus = locationManager.authorizationStatus
        refreshLocationServicesFlag()
        
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
            startLocationRefreshTimer()
            if CLLocationManager.headingAvailable() {
                locationManager.startUpdatingHeading()
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
    
    private func updateLocation(_ location: CLLocation) {
        let nativeSpeed = location.speed >= 0 ? location.speed : nil
        let nativeCourse = location.course >= 0 ? location.course : nil
        var derivedSpeed: Double?
        var derivedCourse: Double?
        var derivedVerticalSpeed: Double?
        
        if let previousLocation {
            let elapsed = location.timestamp.timeIntervalSince(previousLocation.timestamp)
            if elapsed > 0 {
                let distance = location.distance(from: previousLocation)
                derivedSpeed = distance / elapsed
                derivedVerticalSpeed = (location.altitude - previousLocation.altitude) / elapsed
                
                if distance > 0.2 {
                    derivedCourse = bearing(from: previousLocation.coordinate, to: location.coordinate)
                }
            }
        }
        
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        speed = nativeSpeed ?? derivedSpeed
        course = nativeCourse ?? derivedCourse ?? trueHeading ?? magneticHeading
        verticalSpeed = derivedVerticalSpeed
        locationTimestamp = location.timestamp
        
        if #available(iOS 13.4, *) {
            speedAccuracy = location.speedAccuracy >= 0 ? location.speedAccuracy : nil
            courseAccuracy = location.courseAccuracy >= 0 ? location.courseAccuracy : nil
        }
        
        if #available(iOS 15.0, *) {
            isSimulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware
            isProducedByAccessory = location.sourceInformation?.isProducedByAccessory
        }
        
        previousLocation = location
    }
    
    private func startLocationRefreshTimer() {
        locationRefreshTimer?.invalidate()
        locationRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.locationManager.requestLocation()
        }
    }
    
    private func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let lon2 = end.longitude * .pi / 180
        let deltaLon = lon2 - lon1
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }
}

extension SensorDataManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        refreshLocationServicesFlag()
        // Only act on an answer. Re-entering startLocationUpdates while the
        // status is still notDetermined would ask for permission again on the
        // back of the callback that permission was asked for.
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationUpdates()
        default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        updateLocation(location)
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        magneticHeading = newHeading.magneticHeading >= 0 ? newHeading.magneticHeading : nil
        trueHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : nil
        if course == nil {
            course = trueHeading ?? magneticHeading
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last valid values on screen. requestLocation can fail transiently indoors.
    }
}

struct SensorVector {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
}
