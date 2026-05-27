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
    @Published var isLocationServiceEnabled = CLLocationManager.locationServicesEnabled()
    @Published var isSimulatedBySoftware: Bool?
    @Published var isProducedByAccessory: Bool?
    
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    private var previousLocation: CLLocation?
    private var locationRefreshTimer: Timer?
    
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
        
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.acceleration = SensorVector(
                x: motion.userAcceleration.x,
                y: motion.userAcceleration.y,
                z: motion.userAcceleration.z
            )
            self.rotationRate = SensorVector(
                x: motion.rotationRate.x,
                y: motion.rotationRate.y,
                z: motion.rotationRate.z
            )
            self.attitude = SensorVector(
                x: motion.attitude.roll,
                y: motion.attitude.pitch,
                z: motion.attitude.yaw
            )
        }
    }
    
    private func startLocationUpdates() {
        isLocationServiceEnabled = CLLocationManager.locationServicesEnabled()
        authorizationStatus = locationManager.authorizationStatus
        
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
        startLocationUpdates()
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
