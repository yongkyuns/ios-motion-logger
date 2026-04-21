import SceneKit
import SwiftUI
import simd

struct ThreeDMapView: UIViewRepresentable {
    let trajectoryPoints: [SIMD3<Float>]
    let featurePoints: [SIMD3<Float>]
    let semanticMeshChunks: [SemanticMeshChunk]
    let visibleSemanticClasses: Set<SemanticSurfaceClass>
    let currentDevicePosition: SIMD3<Float>?
    let currentDeviceYawRadians: Float
    let isFollowingDevice: Bool
    let onManualCameraControl: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = context.coordinator.scene
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.05, alpha: 1.0)
        view.pointOfView = context.coordinator.cameraNode
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 60
        view.defaultCameraController.inertiaEnabled = false
        view.defaultCameraController.interactionMode = .orbitTurntable
        context.coordinator.configureScene()
        context.coordinator.installInteractionObservers(on: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.onManualCameraControl = onManualCameraControl
        context.coordinator.update(
            trajectoryPoints: trajectoryPoints,
            featurePoints: featurePoints,
            semanticMeshChunks: semanticMeshChunks,
            visibleSemanticClasses: visibleSemanticClasses,
            currentDevicePosition: currentDevicePosition,
            currentDeviceYawRadians: currentDeviceYawRadians,
            isFollowingDevice: isFollowingDevice
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private struct SemanticMeshKey: Hashable {
            let chunkID: UUID
            let semanticClass: SemanticSurfaceClass
        }

        let scene = SCNScene()

        private let rootNode = SCNNode()
        private let followRigNode = SCNNode()
        let cameraNode = SCNNode()
        private let trajectoryNode = SCNNode()
        private let featureNode = SCNNode()
        private let semanticMeshNode = SCNNode()
        private let currentPositionNode = SCNNode()
        private let deviceNode = SCNNode()
        private var semanticNodesByKey: [SemanticMeshKey: SCNNode] = [:]
        private var semanticSignatureByKey: [SemanticMeshKey: Int] = [:]

        var onManualCameraControl: (() -> Void)?

        func configureScene() {
            scene.rootNode.addChildNode(rootNode)
            scene.rootNode.addChildNode(followRigNode)

            rootNode.addChildNode(trajectoryNode)
            rootNode.addChildNode(featureNode)
            rootNode.addChildNode(semanticMeshNode)
            rootNode.addChildNode(currentPositionNode)
            rootNode.addChildNode(deviceNode)

            let camera = SCNCamera()
            camera.zNear = 0.01
            camera.zFar = 300
            camera.fieldOfView = 42
            cameraNode.camera = camera
            followRigNode.addChildNode(cameraNode)
            cameraNode.position = SCNVector3(0, 3.4, 0.001)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 600
            ambient.light?.color = UIColor(white: 0.86, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let omni = SCNNode()
            omni.light = SCNLight()
            omni.light?.type = .omni
            omni.light?.intensity = 850
            omni.position = SCNVector3(0, 5, 4)
            scene.rootNode.addChildNode(omni)

            rootNode.addChildNode(makeGroundGrid(size: 8, step: 0.25))
            rootNode.addChildNode(makeAxis(length: 1.0, color: .systemRed, direction: SCNVector3(1, 0, 0)))
            rootNode.addChildNode(makeAxis(length: 1.0, color: .systemGreen, direction: SCNVector3(0, 1, 0)))
            rootNode.addChildNode(makeAxis(length: 1.0, color: .systemBlue, direction: SCNVector3(0, 0, 1)))

            let marker = SCNSphere(radius: 0.04)
            marker.firstMaterial?.diffuse.contents = UIColor.systemYellow
            marker.firstMaterial?.lightingModel = .constant
            currentPositionNode.geometry = marker
            currentPositionNode.isHidden = true

            deviceNode.addChildNode(makeDeviceIndicator())
            deviceNode.isHidden = true
        }

        func installInteractionObservers(on view: SCNView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleUserGesture(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleUserGesture(_:)))
            pinch.cancelsTouchesInView = false
            pinch.delegate = self
            view.addGestureRecognizer(pinch)

            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleUserGesture(_:)))
            rotation.cancelsTouchesInView = false
            rotation.delegate = self
            view.addGestureRecognizer(rotation)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc
        private func handleUserGesture(_ gestureRecognizer: UIGestureRecognizer) {
            guard gestureRecognizer.state == .began else { return }
            onManualCameraControl?()
        }

        func update(
            trajectoryPoints: [SIMD3<Float>],
            featurePoints: [SIMD3<Float>],
            semanticMeshChunks: [SemanticMeshChunk],
            visibleSemanticClasses: Set<SemanticSurfaceClass>,
            currentDevicePosition: SIMD3<Float>?,
            currentDeviceYawRadians: Float,
            isFollowingDevice: Bool
        ) {
            updateTrajectory(trajectoryPoints)
            updateFeatureCloud(featurePoints, hidden: !semanticMeshChunks.isEmpty)
            updateSemanticMesh(semanticMeshChunks, visibleClasses: visibleSemanticClasses)
            updateCurrentDevice(position: currentDevicePosition, yawRadians: currentDeviceYawRadians)

            if isFollowingDevice, let currentDevicePosition {
                applyFollowCamera(position: currentDevicePosition, yawRadians: currentDeviceYawRadians)
            }
        }

        private func updateTrajectory(_ points: [SIMD3<Float>]) {
            guard points.count >= 2 else {
                trajectoryNode.geometry = nil
                currentPositionNode.isHidden = points.isEmpty
                if let point = points.last {
                    currentPositionNode.position = SCNVector3(point.x, point.y, point.z)
                }
                return
            }

            let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let indices = (0..<(points.count - 1)).flatMap { [UInt32($0), UInt32($0 + 1)] }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(data: data, primitiveType: .line, primitiveCount: points.count - 1, bytesPerIndex: MemoryLayout<UInt32>.size)

            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemPink
            material.emission.contents = UIColor.systemPink
            material.lightingModel = .constant
            geometry.materials = [material]
            trajectoryNode.geometry = geometry

            if let point = points.last {
                currentPositionNode.position = SCNVector3(point.x, point.y, point.z)
                currentPositionNode.isHidden = false
            }
        }

        private func updateFeatureCloud(_ points: [SIMD3<Float>], hidden: Bool) {
            guard !points.isEmpty, !hidden else {
                featureNode.geometry = nil
                return
            }

            let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let indices = Array(0..<points.count).map { UInt32($0) }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(data: data, primitiveType: .point, primitiveCount: points.count, bytesPerIndex: MemoryLayout<UInt32>.size)

            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemTeal
            material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.8)
            material.lightingModel = .constant
            geometry.materials = [material]
            featureNode.geometry = geometry
        }

        private func updateSemanticMesh(_ chunks: [SemanticMeshChunk], visibleClasses: Set<SemanticSurfaceClass>) {
            var liveKeys: Set<SemanticMeshKey> = []
            for chunk in chunks {
                for group in chunk.groups where visibleClasses.contains(group.semanticClass) && !group.vertices.isEmpty {
                    let key = SemanticMeshKey(chunkID: chunk.id, semanticClass: group.semanticClass)
                    liveKeys.insert(key)

                    let signature = signature(for: group.vertices)
                    let node = semanticNodesByKey[key] ?? {
                        let node = SCNNode()
                        semanticMeshNode.addChildNode(node)
                        semanticNodesByKey[key] = node
                        return node
                    }()

                    node.isHidden = false

                    guard semanticSignatureByKey[key] != signature else { continue }

                    node.geometry = makeSemanticGeometry(for: group)
                    semanticSignatureByKey[key] = signature
                }
            }

            let staleKeys = Set(semanticNodesByKey.keys).subtracting(liveKeys)
            for key in staleKeys {
                semanticNodesByKey[key]?.removeFromParentNode()
                semanticNodesByKey.removeValue(forKey: key)
                semanticSignatureByKey.removeValue(forKey: key)
            }
        }

        private func updateCurrentDevice(position: SIMD3<Float>?, yawRadians: Float) {
            guard let position else {
                deviceNode.isHidden = true
                return
            }

            deviceNode.position = SCNVector3(position.x, position.y + 0.02, position.z)
            deviceNode.eulerAngles = SCNVector3(0, yawRadians, 0)
            deviceNode.isHidden = false
        }

        private func applyFollowCamera(position: SIMD3<Float>, yawRadians: Float) {
            followRigNode.position = SCNVector3(position.x, position.y, position.z)
            followRigNode.eulerAngles = SCNVector3(0, yawRadians, 0)
            cameraNode.position = SCNVector3(0, 3.4, 0.001)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        }

        private func makeSemanticGeometry(for group: SemanticMeshGroup) -> SCNGeometry {
            let vertices = group.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let indices = Array(0..<group.vertices.count).map { UInt32($0) }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: group.vertices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )

            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = group.semanticClass.uiColor.withAlphaComponent(0.72)
            material.emission.contents = group.semanticClass.uiColor.withAlphaComponent(0.18)
            material.isDoubleSided = true
            material.lightingModel = .lambert
            geometry.materials = [material]
            return geometry
        }

        private func makeDeviceIndicator() -> SCNNode {
            let container = SCNNode()

            let body = SCNBox(width: 0.075, height: 0.012, length: 0.16, chamferRadius: 0.008)
            let bodyMaterial = SCNMaterial()
            bodyMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.92)
            bodyMaterial.emission.contents = UIColor.systemYellow.withAlphaComponent(0.2)
            bodyMaterial.lightingModel = .lambert
            body.materials = [bodyMaterial]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0, 0)
            container.addChildNode(bodyNode)

            let nose = SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.05)
            let noseMaterial = SCNMaterial()
            noseMaterial.diffuse.contents = UIColor.systemYellow
            noseMaterial.emission.contents = UIColor.systemYellow.withAlphaComponent(0.25)
            noseMaterial.lightingModel = .constant
            nose.materials = [noseMaterial]
            let noseNode = SCNNode(geometry: nose)
            noseNode.position = SCNVector3(0, 0.018, -0.105)
            noseNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            container.addChildNode(noseNode)

            return container
        }

        private func signature(for vertices: [SIMD3<Float>]) -> Int {
            var hasher = Hasher()
            hasher.combine(vertices.count)

            guard !vertices.isEmpty else {
                return hasher.finalize()
            }

            let sampleStride = max(1, vertices.count / 12)
            for index in stride(from: 0, to: vertices.count, by: sampleStride) {
                let vertex = vertices[index]
                hasher.combine(vertex.x.bitPattern)
                hasher.combine(vertex.y.bitPattern)
                hasher.combine(vertex.z.bitPattern)
            }

            return hasher.finalize()
        }

        private func makeGroundGrid(size: Float, step: Float) -> SCNNode {
            let container = SCNNode()
            let half = size / 2
            var offset: Float = -half

            while offset <= half {
                let lineX = SCNNode(geometry: lineGeometry(from: SCNVector3(-half, 0, offset), to: SCNVector3(half, 0, offset), color: UIColor.white.withAlphaComponent(0.08)))
                let lineZ = SCNNode(geometry: lineGeometry(from: SCNVector3(offset, 0, -half), to: SCNVector3(offset, 0, half), color: UIColor.white.withAlphaComponent(0.08)))
                container.addChildNode(lineX)
                container.addChildNode(lineZ)
                offset += step
            }

            return container
        }

        private func makeAxis(length: Float, color: UIColor, direction: SCNVector3) -> SCNNode {
            let endpoint = SCNVector3(direction.x * length, direction.y * length, direction.z * length)
            return SCNNode(geometry: lineGeometry(from: SCNVector3Zero, to: endpoint, color: color))
        }

        private func lineGeometry(from start: SCNVector3, to end: SCNVector3, color: UIColor) -> SCNGeometry {
            let vertices = [start, end]
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [UInt32] = [0, 1]
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(data: data, primitiveType: .line, primitiveCount: 1, bytesPerIndex: MemoryLayout<UInt32>.size)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color
            material.lightingModel = .constant
            geometry.materials = [material]
            return geometry
        }
    }
}
