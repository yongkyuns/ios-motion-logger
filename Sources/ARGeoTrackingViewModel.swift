import CoreLocation
import CoreMotion
import Foundation

struct GeoSignalSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let series: String
    let segmentID: Int
    let value: Double
}

@MainActor
final class ARGeoTrackingViewModel: NSObject, ObservableObject {
    private let locationLogFileName = "geo_location.csv"
    private let headingLogFileName = "geo_heading.csv"
    private let motionLogFileName = "geo_device_motion.csv"
    private let accelerometerLogFileName = "geo_accelerometer.csv"
    private let gyroLogFileName = "geo_gyro.csv"
    private let magnetometerLogFileName = "geo_magnetometer.csv"
    private let barometerLogFileName = "geo_barometer.csv"
    private let statusLogFileName = "geo_status.jsonl"
    private let eventLogFileName = "geo_events.jsonl"

    @Published private(set) var supportText = "Core Motion + Core Location global sensor demo."
    @Published private(set) var permissionText = "Waiting for location authorization"
    @Published private(set) var sensorStateText = "Idle"
    @Published private(set) var positionText = "Locating..."
    @Published private(set) var altitudeText = "Altitude unavailable"
    @Published private(set) var headingText = "Heading unavailable"
    @Published private(set) var attitudeText = "Attitude unavailable"
    @Published private(set) var imuText = "IMU unavailable"
    @Published private(set) var barometerText = "Barometer unavailable"
    @Published private(set) var accuracyText = "GPS accuracy unavailable"
    @Published private(set) var motionText = "Motion streams idle"

    @Published private(set) var headingDegrees: Double = 0
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var pitchDegrees: Double = 0
    @Published private(set) var yawDegrees: Double = 0
    @Published private(set) var currentLocationSnapshot: CLLocation?
    @Published private(set) var traceCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var locationHistory: [GeoSignalSample] = []
    @Published private(set) var headingHistory: [GeoSignalSample] = []
    @Published private(set) var attitudeHistory: [GeoSignalSample] = []
    @Published private(set) var accelerometerHistory: [GeoSignalSample] = []
    @Published private(set) var gyroHistory: [GeoSignalSample] = []
    @Published private(set) var magnetometerHistory: [GeoSignalSample] = []
    @Published private(set) var barometerHistory: [GeoSignalSample] = []

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private let motionActivityManager = CMMotionActivityManager()
    private let altimeter = CMAltimeter()
    private let sensorQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.example.motionlogger.sensor-queue"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var hasStarted = false
    private var latestLocation: CLLocation?
    private var referenceLocation: CLLocation?
    private var latestPressureKPa: Double?
    private var latestRelativeAltitudeMeters: Double?
    private var lastStatusLogTime: TimeInterval = 0
    private let statusLogInterval: TimeInterval = 0.5
    private let maxHistorySamples = 240
    private let maxTracePoints = 1_500
    private var historySegmentID = 0
    private var isBarometerUpdating = false
    private var isRequestingBarometerAuthorization = false
    private var hasRetriedBarometerStart = false

    private let logWriter = SessionLogWriter(
        prefix: "geo",
        files: [
            SessionLogFileDefinition(
                name: "geo_location.csv",
                header: "timestamp,latitude,longitude,horizontal_accuracy_m,vertical_accuracy_m,altitude_m,speed_mps,course_deg"
            ),
            SessionLogFileDefinition(
                name: "geo_heading.csv",
                header: "timestamp,magnetic_heading_deg,true_heading_deg,heading_accuracy_deg,x,y,z"
            ),
            SessionLogFileDefinition(
                name: "geo_device_motion.csv",
                header: "timestamp,roll_deg,pitch_deg,yaw_deg,gravity_x,gravity_y,gravity_z,user_accel_x,user_accel_y,user_accel_z,rotation_x,rotation_y,rotation_z,mag_field_x,mag_field_y,mag_field_z,mag_accuracy"
            ),
            SessionLogFileDefinition(
                name: "geo_accelerometer.csv",
                header: "timestamp,ax_g,ay_g,az_g"
            ),
            SessionLogFileDefinition(
                name: "geo_gyro.csv",
                header: "timestamp,gx_rps,gy_rps,gz_rps"
            ),
            SessionLogFileDefinition(
                name: "geo_magnetometer.csv",
                header: "timestamp,mx_uT,my_uT,mz_uT"
            ),
            SessionLogFileDefinition(
                name: "geo_barometer.csv",
                header: "timestamp,relative_altitude_m,pressure_kpa"
            ),
            SessionLogFileDefinition(name: "geo_status.jsonl", header: nil),
            SessionLogFileDefinition(name: "geo_events.jsonl", header: nil)
        ]
    )

    var logFileURLs: [URL] {
        logWriter.fileURLs
    }

    func makeExportArchive() async -> URL? {
        await logWriter.makeArchive()
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .otherNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.headingFilter = kCLHeadingFilterNone
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        sensorStateText = "Starting sensors"
        supportText = "Global position from GPS, attitude from device motion, and raw IMU/barometer streams."
        logEvent(type: "start_requested", payload: sensorAvailabilityPayload())

        startMotionStreams()
        updateAuthorizationState(locationManager.authorizationStatus)
    }

    func resetTracking() {
        logEvent(type: "reset_requested", payload: [:])
        stopAllSensors()
        historySegmentID += 1

        latestLocation = nil
        referenceLocation = nil
        latestPressureKPa = nil
        latestRelativeAltitudeMeters = nil
        currentLocationSnapshot = nil
        isBarometerUpdating = false
        isRequestingBarometerAuthorization = false
        hasRetriedBarometerStart = false

        positionText = "Locating..."
        altitudeText = "Altitude unavailable"
        headingText = "Heading unavailable"
        attitudeText = "Attitude unavailable"
        imuText = "IMU unavailable"
        barometerText = "Barometer unavailable"
        accuracyText = "GPS accuracy unavailable"
        motionText = "Motion streams restarting"
        sensorStateText = "Restarting sensors"
        headingDegrees = 0
        rollDegrees = 0
        pitchDegrees = 0
        yawDegrees = 0
        clearHistories()

        startMotionStreams()
        updateAuthorizationState(locationManager.authorizationStatus)
    }

    func stop() {
        guard hasStarted else { return }
        stopAllSensors()
        hasStarted = false
        historySegmentID += 1
        sensorStateText = "Sensors paused"
        motionText = "Motion streams paused"
        logEvent(type: "stop_requested", payload: [:])
        logStatus(force: true)
    }

    private func updateAuthorizationState(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            permissionText = "Location authorized"
            sensorStateText = "Streaming sensors"
            locationManager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                locationManager.startUpdatingHeading()
            }
            logEvent(type: "authorization_changed", payload: ["status": "authorized"])
        case .notDetermined:
            permissionText = "Waiting for location authorization"
            sensorStateText = "Awaiting permission"
            logEvent(type: "authorization_changed", payload: ["status": "not_determined"])
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            permissionText = "Location denied or restricted"
            sensorStateText = "Location unavailable"
            positionText = "Enable location access in Settings"
            accuracyText = "No GPS fix"
            logEvent(type: "authorization_changed", payload: ["status": "denied_or_restricted"])
        @unknown default:
            permissionText = "Location authorization unknown"
            sensorStateText = "Unknown authorization state"
            logEvent(type: "authorization_changed", payload: ["status": "unknown"])
        }

        logStatus(force: true)
    }

    private func startMotionStreams() {
        startDeviceMotionUpdates()
        startAccelerometerUpdates()
        startGyroUpdates()
        startMagnetometerUpdates()
        startBarometerUpdates()
    }

    private func startDeviceMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            motionText = "Device motion unavailable"
            logEvent(type: "device_motion_unavailable", payload: [:])
            return
        }

        guard let referenceFrame = preferredAttitudeReferenceFrame() else {
            motionText = "No supported attitude reference frame"
            logEvent(type: "device_motion_reference_frame_unavailable", payload: [:])
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        logEvent(type: "device_motion_started", payload: ["reference_frame": Self.describe(referenceFrame: referenceFrame)])
        motionManager.startDeviceMotionUpdates(
            using: referenceFrame,
            to: sensorQueue,
            withHandler: Self.makeDeviceMotionHandler(owner: self)
        )
    }

    private func startAccelerometerUpdates() {
        guard motionManager.isAccelerometerAvailable else {
            logEvent(type: "accelerometer_unavailable", payload: [:])
            return
        }

        motionManager.accelerometerUpdateInterval = 1.0 / 50.0
        motionManager.startAccelerometerUpdates(
            to: sensorQueue,
            withHandler: Self.makeAccelerometerHandler(owner: self)
        )
    }

    private func startGyroUpdates() {
        guard motionManager.isGyroAvailable else {
            logEvent(type: "gyro_unavailable", payload: [:])
            return
        }

        motionManager.gyroUpdateInterval = 1.0 / 50.0
        motionManager.startGyroUpdates(
            to: sensorQueue,
            withHandler: Self.makeGyroHandler(owner: self)
        )
    }

    private func startMagnetometerUpdates() {
        guard motionManager.isMagnetometerAvailable else {
            logEvent(type: "magnetometer_unavailable", payload: [:])
            return
        }

        motionManager.magnetometerUpdateInterval = 1.0 / 20.0
        motionManager.startMagnetometerUpdates(
            to: sensorQueue,
            withHandler: Self.makeMagnetometerHandler(owner: self)
        )
    }

    private func startBarometerUpdates() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            barometerText = "Barometer unavailable"
            logEvent(type: "barometer_unavailable", payload: [:])
            return
        }

        switch CMAltimeter.authorizationStatus() {
        case .authorized:
            beginBarometerUpdates()
        case .notDetermined:
            requestBarometerAuthorizationAndStart()
        case .denied:
            barometerText = "Enable Motion & Fitness for barometer"
            logEvent(type: "barometer_authorization_denied", payload: [:])
            logStatus(force: true)
        case .restricted:
            barometerText = "Enable Fitness Tracking in Settings"
            logEvent(type: "barometer_authorization_restricted", payload: [:])
            logStatus(force: true)
        @unknown default:
            barometerText = "Barometer authorization unknown"
            logEvent(type: "barometer_authorization_unknown", payload: [:])
            logStatus(force: true)
        }
    }

    private func requestBarometerAuthorizationAndStart() {
        guard !isRequestingBarometerAuthorization else { return }

        barometerText = "Waiting for Motion & Fitness permission"
        isRequestingBarometerAuthorization = true
        logEvent(type: "barometer_authorization_requested", payload: [:])
        logStatus(force: true)

        guard CMMotionActivityManager.isActivityAvailable() else {
            isRequestingBarometerAuthorization = false
            logEvent(type: "motion_activity_unavailable_for_barometer_auth", payload: [:])
            beginBarometerUpdates()
            return
        }

        let now = Date()
        motionActivityManager.queryActivityStarting(from: now, to: now, to: sensorQueue) { [weak self] _, error in
            guard let self else { return }
            let description = error?.localizedDescription

            Task { @MainActor in
                self.isRequestingBarometerAuthorization = false

                if let description {
                    self.logEvent(
                        type: "barometer_authorization_query_error",
                        payload: ["description": description]
                    )
                }

                self.beginBarometerUpdates()
            }
        }
    }

    private func beginBarometerUpdates() {
        guard !isBarometerUpdating else { return }

        isBarometerUpdating = true
        barometerText = "Starting barometer"
        logEvent(
            type: "barometer_started",
            payload: ["authorization": Self.describe(motionAuthorization: CMAltimeter.authorizationStatus())]
        )
        altimeter.startRelativeAltitudeUpdates(
            to: sensorQueue,
            withHandler: Self.makeBarometerHandler(owner: self)
        )
    }

    private func stopAllSensors() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        isBarometerUpdating = false
        isRequestingBarometerAuthorization = false
    }

    private func handleDeviceMotionSample(
        timestamp: Date,
        roll: Double,
        pitch: Double,
        yaw: Double,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        userAccelX: Double,
        userAccelY: Double,
        userAccelZ: Double,
        rotationX: Double,
        rotationY: Double,
        rotationZ: Double,
        magFieldX: Double,
        magFieldY: Double,
        magFieldZ: Double,
        magAccuracy: String
    ) {
        rollDegrees = roll
        pitchDegrees = pitch
        yawDegrees = yaw

        attitudeText = String(format: "R %.1f°  P %.1f°  Y %.1f°", roll, pitch, yaw)
        imuText = String(
            format: "accel %.2f %.2f %.2f g | gyro %.2f %.2f %.2f rad/s",
            userAccelX,
            userAccelY,
            userAccelZ,
            rotationX,
            rotationY,
            rotationZ
        )
        motionText = "Device motion, accelerometer, gyro, and magnetometer active"

        let line = String(
            format: "%@,%.3f,%.3f,%.3f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%@",
            makeLogTimestamp(),
            roll,
            pitch,
            yaw,
            gravityX,
            gravityY,
            gravityZ,
            userAccelX,
            userAccelY,
            userAccelZ,
            rotationX,
            rotationY,
            rotationZ,
            magFieldX,
            magFieldY,
            magFieldZ,
            magAccuracy
        )

        Task {
            await logWriter.append(line, to: motionLogFileName)
        }

        appendHistorySample(timestamp: timestamp, series: "Roll", value: roll, to: &attitudeHistory)
        appendHistorySample(timestamp: timestamp, series: "Pitch", value: pitch, to: &attitudeHistory)
        appendHistorySample(timestamp: timestamp, series: "Yaw", value: yaw, to: &attitudeHistory)
        logStatus()
    }

    private func handleAccelerometerSample(timestamp: Date, x: Double, y: Double, z: Double) {
        let line = String(
            format: "%@,%.6f,%.6f,%.6f",
            makeLogTimestamp(),
            x,
            y,
            z
        )

        Task {
            await logWriter.append(line, to: accelerometerLogFileName)
        }

        appendHistorySample(timestamp: timestamp, series: "X", value: x, to: &accelerometerHistory)
        appendHistorySample(timestamp: timestamp, series: "Y", value: y, to: &accelerometerHistory)
        appendHistorySample(timestamp: timestamp, series: "Z", value: z, to: &accelerometerHistory)
    }

    private func handleGyroSample(timestamp: Date, x: Double, y: Double, z: Double) {
        let line = String(
            format: "%@,%.6f,%.6f,%.6f",
            makeLogTimestamp(),
            x,
            y,
            z
        )

        Task {
            await logWriter.append(line, to: gyroLogFileName)
        }

        appendHistorySample(timestamp: timestamp, series: "X", value: x, to: &gyroHistory)
        appendHistorySample(timestamp: timestamp, series: "Y", value: y, to: &gyroHistory)
        appendHistorySample(timestamp: timestamp, series: "Z", value: z, to: &gyroHistory)
    }

    private func handleMagnetometerSample(timestamp: Date, x: Double, y: Double, z: Double) {
        let line = String(
            format: "%@,%.6f,%.6f,%.6f",
            makeLogTimestamp(),
            x,
            y,
            z
        )

        Task {
            await logWriter.append(line, to: magnetometerLogFileName)
        }

        appendHistorySample(timestamp: timestamp, series: "X", value: x, to: &magnetometerHistory)
        appendHistorySample(timestamp: timestamp, series: "Y", value: y, to: &magnetometerHistory)
        appendHistorySample(timestamp: timestamp, series: "Z", value: z, to: &magnetometerHistory)
    }

    private func handleAltitudeSample(timestamp: Date, relativeAltitude: Double, pressure: Double) {
        latestRelativeAltitudeMeters = relativeAltitude
        latestPressureKPa = pressure

        barometerText = String(format: "rel %.2f m | pressure %.2f kPa", relativeAltitude, pressure)

        let line = String(
            format: "%@,%.4f,%.4f",
            makeLogTimestamp(),
            relativeAltitude,
            pressure
        )

        Task {
            await logWriter.append(line, to: barometerLogFileName)
        }

        appendHistorySample(timestamp: timestamp, series: "Relative Altitude", value: relativeAltitude, to: &barometerHistory)
        logStatus()
    }

    deinit {
        let writer = logWriter
        Task {
            await writer.close()
        }
    }
}

extension ARGeoTrackingViewModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.updateAuthorizationState(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else { return }

        Task { @MainActor in
            if self.referenceLocation == nil {
                self.referenceLocation = latestLocation
            }
            self.latestLocation = latestLocation
            self.currentLocationSnapshot = latestLocation
            self.positionText = String(
                format: "%.6f, %.6f",
                latestLocation.coordinate.latitude,
                latestLocation.coordinate.longitude
            )
            self.altitudeText = String(
                format: "alt %.1f m | speed %.1f m/s | course %.1f°",
                latestLocation.altitude,
                max(latestLocation.speed, 0),
                latestLocation.course >= 0 ? latestLocation.course : 0
            )
            self.accuracyText = String(
                format: "hAcc ±%.1f m | vAcc ±%.1f m",
                latestLocation.horizontalAccuracy,
                latestLocation.verticalAccuracy
            )
            self.appendLocationHistorySample(for: latestLocation)
            self.appendTraceCoordinate(for: latestLocation)
            self.logLocation(latestLocation)
            self.logStatus()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let magneticHeading = newHeading.magneticHeading
        let trueHeading = newHeading.trueHeading
        let headingAccuracy = newHeading.headingAccuracy
        let x = newHeading.x
        let y = newHeading.y
        let z = newHeading.z

        Task { @MainActor in
            let preferredHeading = trueHeading >= 0 ? trueHeading : magneticHeading
            self.headingDegrees = preferredHeading
            self.headingText = String(
                format: "true %.1f° | magnetic %.1f° | acc ±%.1f°",
                trueHeading >= 0 ? trueHeading : 0,
                magneticHeading,
                headingAccuracy
            )
            self.appendHistorySample(timestamp: Date(), series: "Heading", value: preferredHeading, to: &self.headingHistory)
            self.logHeading(
                magneticHeading: magneticHeading,
                trueHeading: trueHeading,
                headingAccuracy: headingAccuracy,
                x: x,
                y: y,
                z: z
            )
            self.logStatus()
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            self.positionText = "Location failed"
            self.accuracyText = description
            self.logEvent(type: "location_failed", payload: ["description": description])
            self.logStatus(force: true)
        }
    }
}

private extension ARGeoTrackingViewModel {
    nonisolated static func makeDeviceMotionHandler(
        owner: ARGeoTrackingViewModel
    ) -> CMDeviceMotionHandler {
        { [weak owner] motion, error in
            guard let owner else { return }

            if let error {
                let description = error.localizedDescription
                Task { @MainActor in
                    owner.motionText = "Device motion error"
                    owner.logEvent(type: "device_motion_error", payload: ["description": description])
                    owner.logStatus(force: true)
                }
                return
            }

            guard let motion else { return }
            let roll = motion.attitude.roll * 180 / .pi
            let pitch = motion.attitude.pitch * 180 / .pi
            let yaw = motion.attitude.yaw * 180 / .pi
            let gravityX = motion.gravity.x
            let gravityY = motion.gravity.y
            let gravityZ = motion.gravity.z
            let userAccelX = motion.userAcceleration.x
            let userAccelY = motion.userAcceleration.y
            let userAccelZ = motion.userAcceleration.z
            let rotationX = motion.rotationRate.x
            let rotationY = motion.rotationRate.y
            let rotationZ = motion.rotationRate.z
            let magFieldX = motion.magneticField.field.x
            let magFieldY = motion.magneticField.field.y
            let magFieldZ = motion.magneticField.field.z
            let magAccuracy = describe(magneticFieldAccuracy: motion.magneticField.accuracy)
            let timestamp = Date()

            Task { @MainActor in
                owner.handleDeviceMotionSample(
                    timestamp: timestamp,
                    roll: roll,
                    pitch: pitch,
                    yaw: yaw,
                    gravityX: gravityX,
                    gravityY: gravityY,
                    gravityZ: gravityZ,
                    userAccelX: userAccelX,
                    userAccelY: userAccelY,
                    userAccelZ: userAccelZ,
                    rotationX: rotationX,
                    rotationY: rotationY,
                    rotationZ: rotationZ,
                    magFieldX: magFieldX,
                    magFieldY: magFieldY,
                    magFieldZ: magFieldZ,
                    magAccuracy: magAccuracy
                )
            }
        }
    }

    nonisolated static func makeAccelerometerHandler(
        owner: ARGeoTrackingViewModel
    ) -> CMAccelerometerHandler {
        { [weak owner] data, error in
            guard let owner else { return }

            if let error {
                let description = error.localizedDescription
                Task { @MainActor in
                    owner.logEvent(type: "accelerometer_error", payload: ["description": description])
                }
                return
            }

            guard let data else { return }
            let x = data.acceleration.x
            let y = data.acceleration.y
            let z = data.acceleration.z
            let timestamp = Date()

            Task { @MainActor in
                owner.handleAccelerometerSample(timestamp: timestamp, x: x, y: y, z: z)
            }
        }
    }

    nonisolated static func makeGyroHandler(
        owner: ARGeoTrackingViewModel
    ) -> CMGyroHandler {
        { [weak owner] data, error in
            guard let owner else { return }

            if let error {
                let description = error.localizedDescription
                Task { @MainActor in
                    owner.logEvent(type: "gyro_error", payload: ["description": description])
                }
                return
            }

            guard let data else { return }
            let x = data.rotationRate.x
            let y = data.rotationRate.y
            let z = data.rotationRate.z
            let timestamp = Date()

            Task { @MainActor in
                owner.handleGyroSample(timestamp: timestamp, x: x, y: y, z: z)
            }
        }
    }

    nonisolated static func makeMagnetometerHandler(
        owner: ARGeoTrackingViewModel
    ) -> CMMagnetometerHandler {
        { [weak owner] data, error in
            guard let owner else { return }

            if let error {
                let description = error.localizedDescription
                Task { @MainActor in
                    owner.logEvent(type: "magnetometer_error", payload: ["description": description])
                }
                return
            }

            guard let data else { return }
            let x = data.magneticField.x
            let y = data.magneticField.y
            let z = data.magneticField.z
            let timestamp = Date()

            Task { @MainActor in
                owner.handleMagnetometerSample(timestamp: timestamp, x: x, y: y, z: z)
            }
        }
    }

    nonisolated static func makeBarometerHandler(
        owner: ARGeoTrackingViewModel
    ) -> CMAltitudeHandler {
        { [weak owner] data, error in
            guard let owner else { return }

            if let error {
                let nsError = error as NSError
                let description = error.localizedDescription
                let isNotAuthorizedError = nsError.domain == CMErrorDomain && nsError.code == 105
                Task { @MainActor in
                    owner.isBarometerUpdating = false

                    if isNotAuthorizedError {
                        let status = CMAltimeter.authorizationStatus()
                        owner.logEvent(
                            type: "barometer_error",
                            payload: [
                                "description": description,
                                "code": nsError.code,
                                "authorization": Self.describe(motionAuthorization: status)
                            ]
                        )

                        switch status {
                        case .notDetermined where !owner.hasRetriedBarometerStart:
                            owner.hasRetriedBarometerStart = true
                            owner.requestBarometerAuthorizationAndStart()
                        case .denied:
                            owner.barometerText = "Enable Motion & Fitness for barometer"
                            owner.logStatus(force: true)
                        case .restricted:
                            owner.barometerText = "Enable Fitness Tracking in Settings"
                            owner.logStatus(force: true)
                        default:
                            owner.barometerText = "Barometer not authorized"
                            owner.logStatus(force: true)
                        }
                        return
                    }

                    owner.barometerText = "Barometer error"
                    owner.logEvent(
                        type: "barometer_error",
                        payload: ["description": description, "code": nsError.code]
                    )
                    owner.logStatus(force: true)
                }
                return
            }

            guard let data else { return }
            let relativeAltitude = data.relativeAltitude.doubleValue
            let pressure = data.pressure.doubleValue
            let timestamp = Date()

            Task { @MainActor in
                owner.handleAltitudeSample(timestamp: timestamp, relativeAltitude: relativeAltitude, pressure: pressure)
            }
        }
    }

    func appendLocationHistorySample(for location: CLLocation) {
        guard let referenceLocation else { return }

        let latitudeScale = 111_132.0
        let longitudeScale = max(cos(referenceLocation.coordinate.latitude * .pi / 180.0) * 111_320.0, 0.0001)
        let northMeters = (location.coordinate.latitude - referenceLocation.coordinate.latitude) * latitudeScale
        let eastMeters = (location.coordinate.longitude - referenceLocation.coordinate.longitude) * longitudeScale
        let altitudeDelta = location.altitude - referenceLocation.altitude
        let timestamp = Date()

        appendHistorySample(timestamp: timestamp, series: "North", value: northMeters, to: &locationHistory)
        appendHistorySample(timestamp: timestamp, series: "East", value: eastMeters, to: &locationHistory)
        appendHistorySample(timestamp: timestamp, series: "Altitude", value: altitudeDelta, to: &locationHistory)
    }

    func appendTraceCoordinate(for location: CLLocation) {
        let coordinate = location.coordinate

        if let previousCoordinate = traceCoordinates.last {
            let previousLocation = CLLocation(
                latitude: previousCoordinate.latitude,
                longitude: previousCoordinate.longitude
            )
            if previousLocation.distance(from: location) < 0.5 {
                return
            }
        }

        traceCoordinates.append(coordinate)
        let overflow = traceCoordinates.count - maxTracePoints
        if overflow > 0 {
            traceCoordinates.removeFirst(overflow)
        }
    }

    func appendHistorySample(
        timestamp: Date,
        series: String,
        value: Double,
        to storage: inout [GeoSignalSample]
    ) {
        storage.append(
            GeoSignalSample(
                timestamp: timestamp,
                series: series,
                segmentID: historySegmentID,
                value: value
            )
        )
        let overflow = storage.count - maxHistorySamples
        if overflow > 0 {
            storage.removeFirst(overflow)
        }
    }

    func clearHistories() {
        traceCoordinates = []
        locationHistory = []
        headingHistory = []
        attitudeHistory = []
        accelerometerHistory = []
        gyroHistory = []
        magnetometerHistory = []
        barometerHistory = []
    }

    func sensorAvailabilityPayload() -> [String: Any] {
        [
            "device_motion_available": motionManager.isDeviceMotionAvailable,
            "accelerometer_available": motionManager.isAccelerometerAvailable,
            "gyro_available": motionManager.isGyroAvailable,
            "magnetometer_available": motionManager.isMagnetometerAvailable,
            "barometer_available": CMAltimeter.isRelativeAltitudeAvailable(),
            "barometer_authorization": Self.describe(motionAuthorization: CMAltimeter.authorizationStatus()),
            "motion_activity_authorization": Self.describe(motionAuthorization: CMMotionActivityManager.authorizationStatus()),
            "heading_available": CLLocationManager.headingAvailable(),
            "attitude_reference_frames_raw": CMMotionManager.availableAttitudeReferenceFrames().rawValue
        ]
    }

    func preferredAttitudeReferenceFrame() -> CMAttitudeReferenceFrame? {
        let frames = CMMotionManager.availableAttitudeReferenceFrames()

        if frames.contains(.xTrueNorthZVertical) {
            return .xTrueNorthZVertical
        }
        if frames.contains(.xMagneticNorthZVertical) {
            return .xMagneticNorthZVertical
        }
        if frames.contains(.xArbitraryCorrectedZVertical) {
            return .xArbitraryCorrectedZVertical
        }
        if frames.contains(.xArbitraryZVertical) {
            return .xArbitraryZVertical
        }
        return nil
    }

    func logLocation(_ location: CLLocation) {
        let speed = max(location.speed, 0)
        let course = location.course >= 0 ? location.course : -1
        let line = String(
            format: "%@,%.7f,%.7f,%.2f,%.2f,%.2f,%.2f,%.2f",
            makeLogTimestamp(),
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.horizontalAccuracy,
            location.verticalAccuracy,
            location.altitude,
            speed,
            course
        )

        Task {
            await logWriter.append(line, to: locationLogFileName)
        }
    }

    func logHeading(
        magneticHeading: CLLocationDirection,
        trueHeading: CLLocationDirection,
        headingAccuracy: CLLocationDirection,
        x: CLHeadingComponentValue,
        y: CLHeadingComponentValue,
        z: CLHeadingComponentValue
    ) {
        let line = String(
            format: "%@,%.3f,%.3f,%.3f,%.6f,%.6f,%.6f",
            makeLogTimestamp(),
            magneticHeading,
            trueHeading,
            headingAccuracy,
            x,
            y,
            z
        )

        Task {
            await logWriter.append(line, to: headingLogFileName)
        }
    }

    func logStatus(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || (now - lastStatusLogTime) >= statusLogInterval else { return }
        lastStatusLogTime = now

        var payload: [String: Any] = [
            "timestamp": makeLogTimestamp(),
            "permission": permissionText,
            "sensor_state": sensorStateText,
            "position": positionText,
            "altitude": altitudeText,
            "heading": headingText,
            "attitude": attitudeText,
            "imu": imuText,
            "barometer": barometerText,
            "barometer_authorization": Self.describe(motionAuthorization: CMAltimeter.authorizationStatus()),
            "accuracy": accuracyText,
            "motion": motionText,
            "roll_deg": rollDegrees,
            "pitch_deg": pitchDegrees,
            "yaw_deg": yawDegrees,
            "heading_deg": headingDegrees
        ]

        if let latestLocation {
            payload["latitude"] = latestLocation.coordinate.latitude
            payload["longitude"] = latestLocation.coordinate.longitude
            payload["horizontal_accuracy_m"] = latestLocation.horizontalAccuracy
        }

        if let latestPressureKPa {
            payload["pressure_kpa"] = latestPressureKPa
        }

        if let latestRelativeAltitudeMeters {
            payload["relative_altitude_m"] = latestRelativeAltitudeMeters
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8) else { return }

        Task {
            await logWriter.append(line, to: statusLogFileName)
        }
    }

    func logEvent(type: String, payload: [String: Any]) {
        var eventPayload = payload
        eventPayload["type"] = type
        eventPayload["timestamp"] = makeLogTimestamp()

        guard JSONSerialization.isValidJSONObject(eventPayload),
              let data = try? JSONSerialization.data(withJSONObject: eventPayload, options: []),
              let line = String(data: data, encoding: .utf8) else { return }

        Task {
            await logWriter.append(line, to: eventLogFileName)
        }
    }

    nonisolated static func describe(magneticFieldAccuracy: CMMagneticFieldCalibrationAccuracy) -> String {
        switch magneticFieldAccuracy {
        case .uncalibrated:
            return "uncalibrated"
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        @unknown default:
            return "unknown"
        }
    }

    nonisolated static func describe(referenceFrame: CMAttitudeReferenceFrame) -> String {
        switch referenceFrame {
        case .xArbitraryZVertical:
            return "xArbitraryZVertical"
        case .xArbitraryCorrectedZVertical:
            return "xArbitraryCorrectedZVertical"
        case .xMagneticNorthZVertical:
            return "xMagneticNorthZVertical"
        case .xTrueNorthZVertical:
            return "xTrueNorthZVertical"
        default:
            return "unknown"
        }
    }

    nonisolated static func describe(motionAuthorization status: CMAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }
}
