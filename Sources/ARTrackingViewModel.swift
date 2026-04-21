import ARKit
import Combine
import Foundation
import simd

private let maximumRenderedSemanticFacesPerChunk = 1800

@MainActor
final class ARTrackingViewModel: NSObject, ObservableObject, ARSessionDelegate {
    private let minimumSampleDistance: Float = 0.05
    private let featurePointVoxelSize: Float = 0.05
    private let maximumFeaturePoints = 6000
    private let maximumTrajectorySamples = 1200
    private let semanticPublishInterval: TimeInterval = 0.25
    private let poseLogInterval: TimeInterval = 0.1
    private let poseLogFileName = "world_pose.csv"
    private let eventLogFileName = "world_events.jsonl"

    @Published private(set) var supportText = "Checking ARKit support..."
    @Published private(set) var trackingStateText = "Starting..."
    @Published private(set) var mappingStateText = "Unavailable"
    @Published private(set) var featurePointCountText = "0"
    @Published private(set) var trajectoryDistanceText = "0.00 m"
    @Published private(set) var trajectorySampleCountText = "0"
    @Published private(set) var positionText = "x: 0.000  y: 0.000  z: 0.000"
    @Published private(set) var rotationText = "roll: 0.0  pitch: 0.0  yaw: 0.0"
    @Published private(set) var topDownTrajectoryPoints: [SIMD2<Float>] = []
    @Published private(set) var trajectory3DPoints: [SIMD3<Float>] = []
    @Published private(set) var mapFeaturePoints: [SIMD3<Float>] = []
    @Published private(set) var semanticMeshChunks: [SemanticMeshChunk] = []
    @Published private(set) var semanticStatusText = "Semantic mesh unavailable"
    @Published private(set) var currentCameraPosition: SIMD3<Float>?
    @Published private(set) var currentCameraYawRadians: Float = 0

    private weak var session: ARSession?
    private var lastTrajectoryPosition: SIMD3<Float>?
    private var totalTrajectoryDistance: Float = 0
    private var featurePointKeys: Set<Int64> = []
    private var semanticChunkByID: [UUID: SemanticMeshChunk] = [:]
    private var semanticPublishTask: Task<Void, Never>?
    private var lastSemanticPublishTime: TimeInterval = 0
    private var lastPoseLogTime: TimeInterval = 0
    private let logWriter = SessionLogWriter(
        prefix: "world",
        files: [
            SessionLogFileDefinition(
                name: "world_pose.csv",
                header: "timestamp,uptime_seconds,x,y,z,roll_deg,pitch_deg,yaw_deg,tracking_state,mapping_state,raw_feature_count,map_feature_count,semantic_chunk_count"
            ),
            SessionLogFileDefinition(name: "world_events.jsonl", header: nil)
        ]
    )

    var logFileURLs: [URL] {
        logWriter.fileURLs
    }

    func makeExportArchive() async -> URL? {
        await logWriter.makeArchive()
    }

    func attachSession(_ session: ARSession) {
        self.session = session

        guard ARWorldTrackingConfiguration.isSupported else {
            supportText = "ARWorldTrackingConfiguration is not supported on this device."
            trackingStateText = "Unsupported"
            return
        }

        supportText = "Live semantic camera on the left, followable 3D map on the right."
        logEvent(type: "attach_session", payload: ["supports_world_tracking": true])
        runSession(resetTracking: true)
    }

    func resetTracking() {
        logEvent(type: "reset_requested", payload: [:])
        runSession(resetTracking: true)
    }

    private func runSession(resetTracking: Bool) {
        guard let session, ARWorldTrackingConfiguration.isSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            semanticStatusText = "Semantic mesh on"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            semanticStatusText = "Mesh on, semantics unavailable"
        } else {
            semanticStatusText = "Semantic mesh unavailable"
        }

        var options: ARSession.RunOptions = []
        if resetTracking {
            options.insert(.resetTracking)
            options.insert(.removeExistingAnchors)
            resetTrajectoryState()
        }

        session.run(configuration, options: options)
        logEvent(
            type: "run_session",
            payload: [
                "reset_tracking": resetTracking,
                "semantic_status": semanticStatusText
            ]
        )
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let translation = frame.camera.transform.translation
        let euler = frame.camera.transform.eulerAnglesDegrees
        let featureCount = frame.rawFeaturePoints?.points.count ?? 0
        let trackingStateText = Self.describe(trackingState: frame.camera.trackingState)
        let mappingStateText = Self.describe(mappingState: frame.worldMappingStatus)
        let rawFeaturePoints = frame.rawFeaturePoints?.points ?? []
        let currentYaw = frame.camera.transform.planarYawRadians
        let now = ProcessInfo.processInfo.systemUptime
        let shouldRecordTrajectory: Bool

        if case .normal = frame.camera.trackingState {
            shouldRecordTrajectory = true
        } else {
            shouldRecordTrajectory = false
        }

        Task { @MainActor in
            self.trackingStateText = trackingStateText
            self.mappingStateText = mappingStateText
            self.featurePointCountText = "\(featureCount)"
            self.positionText = String(format: "x: %.3f  y: %.3f  z: %.3f", translation.x, translation.y, translation.z)
            self.rotationText = String(format: "roll: %.1f  pitch: %.1f  yaw: %.1f", euler.x, euler.y, euler.z)
            self.currentCameraPosition = translation
            self.currentCameraYawRadians = currentYaw

            if shouldRecordTrajectory {
                self.recordTrajectorySample(position: translation)
                self.recordFeaturePoints(rawFeaturePoints)
            }

            if now - self.lastPoseLogTime >= self.poseLogInterval {
                self.lastPoseLogTime = now
                self.logPoseSample(
                    uptime: now,
                    translation: translation,
                    euler: euler,
                    trackingStateText: trackingStateText,
                    mappingStateText: mappingStateText,
                    featureCount: featureCount
                )
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let snapshots = anchors.compactMap { anchor -> SemanticMeshChunk? in
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            return Self.makeSemanticMeshChunk(from: meshAnchor)
        }

        guard !snapshots.isEmpty else { return }
        Task { @MainActor in
            self.upsertSemanticChunks(snapshots)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let snapshots = anchors.compactMap { anchor -> SemanticMeshChunk? in
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            return Self.makeSemanticMeshChunk(from: meshAnchor)
        }

        guard !snapshots.isEmpty else { return }
        Task { @MainActor in
            self.upsertSemanticChunks(snapshots)
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { anchor -> UUID? in
            guard anchor is ARMeshAnchor else { return nil }
            return anchor.identifier
        }

        guard !ids.isEmpty else { return }
        Task { @MainActor in
            self.removeSemanticChunks(ids: ids)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            self.trackingStateText = "Failed"
            self.mappingStateText = description
            self.logEvent(type: "session_failed", payload: ["description": description])
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.trackingStateText = "Interrupted"
            self.logEvent(type: "session_interrupted", payload: [:])
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.trackingStateText = "Resuming..."
            self.logEvent(type: "session_interruption_ended", payload: [:])
            self.runSession(resetTracking: true)
        }
    }

    nonisolated private static func describe(trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .normal:
            return "Normal"
        case .notAvailable:
            return "Not available"
        case .limited(let reason):
            return "Limited: \(describe(reason: reason))"
        @unknown default:
            return "Unknown"
        }
    }

    nonisolated private static func describe(reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:
            return "Initializing"
        case .relocalizing:
            return "Relocalizing"
        case .excessiveMotion:
            return "Excessive motion"
        case .insufficientFeatures:
            return "Insufficient features"
        @unknown default:
            return "Unknown"
        }
    }

    nonisolated private static func describe(mappingState: ARFrame.WorldMappingStatus) -> String {
        switch mappingState {
        case .notAvailable:
            return "Not available"
        case .limited:
            return "Limited"
        case .extending:
            return "Extending"
        case .mapped:
            return "Mapped"
        @unknown default:
            return "Unknown"
        }
    }

    private func resetTrajectoryState() {
        semanticPublishTask?.cancel()
        semanticPublishTask = nil
        lastSemanticPublishTime = 0
        totalTrajectoryDistance = 0
        lastTrajectoryPosition = nil
        topDownTrajectoryPoints = []
        trajectory3DPoints = []
        mapFeaturePoints = []
        featurePointKeys.removeAll(keepingCapacity: true)
        semanticMeshChunks = []
        semanticChunkByID.removeAll(keepingCapacity: true)
        trajectoryDistanceText = "0.00 m"
        trajectorySampleCountText = "0"
        currentCameraPosition = nil
        currentCameraYawRadians = 0
        lastPoseLogTime = 0
    }

    deinit {
        let writer = logWriter
        Task {
            await writer.close()
        }
    }

    private func recordTrajectorySample(position: SIMD3<Float>) {
        guard let lastTrajectoryPosition else {
            lastTrajectoryPosition = position
            topDownTrajectoryPoints = [SIMD2(position.x, position.z)]
            trajectory3DPoints = [position]
            trajectorySampleCountText = "1"
            return
        }

        let delta = simd_distance(lastTrajectoryPosition, position)
        guard delta >= minimumSampleDistance else { return }

        totalTrajectoryDistance += delta
        self.lastTrajectoryPosition = position
        topDownTrajectoryPoints.append(SIMD2(position.x, position.z))
        trajectory3DPoints.append(position)

        if topDownTrajectoryPoints.count > maximumTrajectorySamples {
            let overflow = topDownTrajectoryPoints.count - maximumTrajectorySamples
            topDownTrajectoryPoints.removeFirst(overflow)
            trajectory3DPoints.removeFirst(min(overflow, trajectory3DPoints.count))
        }

        trajectoryDistanceText = String(format: "%.2f m", totalTrajectoryDistance)
        trajectorySampleCountText = "\(topDownTrajectoryPoints.count)"
    }

    private func recordFeaturePoints(_ points: [SIMD3<Float>]) {
        guard mapFeaturePoints.count < maximumFeaturePoints else {
            featurePointCountText = "\(points.count) / map \(mapFeaturePoints.count)"
            return
        }

        var added = 0

        for point in points {
            let key = quantizedKey(for: point)
            if featurePointKeys.insert(key).inserted {
                mapFeaturePoints.append(point)
                added += 1
                if mapFeaturePoints.count >= maximumFeaturePoints {
                    break
                }
            }
        }

        if added > 0 {
            featurePointCountText = "\(points.count) / map \(mapFeaturePoints.count)"
        } else {
            featurePointCountText = "\(points.count) / map \(mapFeaturePoints.count)"
        }
    }

    private func quantizedKey(for point: SIMD3<Float>) -> Int64 {
        let x = Int64((point.x / featurePointVoxelSize).rounded(.toNearestOrAwayFromZero))
        let y = Int64((point.y / featurePointVoxelSize).rounded(.toNearestOrAwayFromZero))
        let z = Int64((point.z / featurePointVoxelSize).rounded(.toNearestOrAwayFromZero))

        return (x & 0x1FFFFF) << 42 | (y & 0x1FFFFF) << 21 | (z & 0x1FFFFF)
    }

    private func upsertSemanticChunks(_ chunks: [SemanticMeshChunk]) {
        for chunk in chunks {
            semanticChunkByID[chunk.id] = chunk
        }
        scheduleSemanticMeshPublish()
    }

    private func removeSemanticChunks(ids: [UUID]) {
        for id in ids {
            semanticChunkByID.removeValue(forKey: id)
        }
        scheduleSemanticMeshPublish(force: true)
    }

    private func scheduleSemanticMeshPublish(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSemanticPublishTime

        if force || elapsed >= semanticPublishInterval {
            semanticPublishTask?.cancel()
            semanticPublishTask = nil
            publishSemanticMeshSnapshot()
            return
        }

        guard semanticPublishTask == nil else { return }

        let delay = semanticPublishInterval - elapsed
        semanticPublishTask = Task { [weak self] in
            let sleepDuration = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepDuration)
            self?.publishSemanticMeshSnapshot()
        }
    }

    private func publishSemanticMeshSnapshot() {
        semanticPublishTask = nil
        lastSemanticPublishTime = ProcessInfo.processInfo.systemUptime
        semanticMeshChunks = semanticChunkByID.values.sorted { $0.id.uuidString < $1.id.uuidString }

        let classifiedFaces = semanticMeshChunks
            .flatMap(\.groups)
            .filter { $0.semanticClass != .none }
            .reduce(0) { $0 + ($1.vertices.count / 3) }

        semanticStatusText = semanticMeshChunks.isEmpty ? "Semantic mesh on" : "Semantic faces \(classifiedFaces)"
    }

    private func logPoseSample(
        uptime: TimeInterval,
        translation: SIMD3<Float>,
        euler: SIMD3<Float>,
        trackingStateText: String,
        mappingStateText: String,
        featureCount: Int
    ) {
        let timestamp = makeLogTimestamp()
        let line = String(
            format: "%@,%.3f,%.5f,%.5f,%.5f,%.3f,%.3f,%.3f,%@,%@,%d,%d,%d",
            timestamp,
            uptime,
            translation.x,
            translation.y,
            translation.z,
            euler.x,
            euler.y,
            euler.z,
            Self.csvField(trackingStateText),
            Self.csvField(mappingStateText),
            featureCount,
            mapFeaturePoints.count,
            semanticMeshChunks.count
        )

        Task {
            await logWriter.append(line, to: poseLogFileName)
        }
    }

    private func logEvent(type: String, payload: [String: Any]) {
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

    nonisolated private static func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    nonisolated private static func makeSemanticMeshChunk(from anchor: ARMeshAnchor) -> SemanticMeshChunk {
        var verticesByClass: [SemanticSurfaceClass: [SIMD3<Float>]] = [:]
        let faceCount = anchor.geometry.faces.count
        let faceStride = max(1, Int(ceil(Double(faceCount) / Double(maximumRenderedSemanticFacesPerChunk))))

        for faceIndex in stride(from: 0, to: faceCount, by: faceStride) {
            let semanticClass = anchor.geometry.semanticClassOf(faceWithIndex: faceIndex)
            let indices = anchor.geometry.vertexIndicesOf(faceWithIndex: faceIndex)
            let localA = anchor.geometry.vertex(at: indices.0)
            let localB = anchor.geometry.vertex(at: indices.1)
            let localC = anchor.geometry.vertex(at: indices.2)
            let worldA = (anchor.transform * SIMD4(localA.x, localA.y, localA.z, 1)).xyz
            let worldB = (anchor.transform * SIMD4(localB.x, localB.y, localB.z, 1)).xyz
            let worldC = (anchor.transform * SIMD4(localC.x, localC.y, localC.z, 1)).xyz

            verticesByClass[semanticClass, default: []].append(contentsOf: [worldA, worldB, worldC])
        }

        let groups = verticesByClass
            .map { SemanticMeshGroup(semanticClass: $0.key, vertices: $0.value) }
            .sorted { $0.semanticClass.rawValue < $1.semanticClass.rawValue }

        return SemanticMeshChunk(id: anchor.identifier, groups: groups)
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    var planarYawRadians: Float {
        let forward = SIMD3(-columns.2.x, 0, -columns.2.z)
        return atan2(forward.x, -forward.z)
    }

    var eulerAnglesDegrees: SIMD3<Float> {
        let pitch = asin(-columns.2.y)
        let roll = atan2(columns.2.x, columns.2.z)
        let yaw = atan2(columns.0.y, columns.1.y)
        let scale = Float(180.0 / Double.pi)
        return SIMD3(roll * scale, pitch * scale, yaw * scale)
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}

private extension ARMeshGeometry {
    func vertex(at index: UInt32) -> SIMD3<Float> {
        let offset = vertices.offset + vertices.stride * Int(index)
        let pointer = vertices.buffer.contents().advanced(by: offset)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }

    func vertexIndicesOf(faceWithIndex index: Int) -> (UInt32, UInt32, UInt32) {
        let offset = faces.indexCountPerPrimitive * faces.bytesPerIndex * index
        let pointer = faces.buffer.contents().advanced(by: offset)

        switch faces.bytesPerIndex {
        case 2:
            let values = pointer.assumingMemoryBound(to: UInt16.self)
            return (UInt32(values[0]), UInt32(values[1]), UInt32(values[2]))
        default:
            let values = pointer.assumingMemoryBound(to: UInt32.self)
            return (values[0], values[1], values[2])
        }
    }

    func semanticClassOf(faceWithIndex index: Int) -> SemanticSurfaceClass {
        guard let classification else { return .none }
        let offset = classification.offset + (classification.stride * index)
        let pointer = classification.buffer.contents().advanced(by: offset)
        let value = Int(pointer.assumingMemoryBound(to: UInt8.self).pointee)
        let meshClass = ARMeshClassification(rawValue: value) ?? .none

        switch meshClass {
        case .floor: return .floor
        case .wall: return .wall
        case .ceiling: return .ceiling
        case .table: return .table
        case .seat: return .seat
        case .window: return .window
        case .door: return .door
        case .none: return .none
        @unknown default: return .none
        }
    }
}
