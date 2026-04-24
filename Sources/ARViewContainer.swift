import ARKit
import SceneKit
import SwiftUI
import simd

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARTrackingViewModel
    let visibleSemanticClasses: Set<SemanticSurfaceClass>

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.delegate = context.coordinator
        view.session.delegate = viewModel
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 60
        view.automaticallyUpdatesLighting = false
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        view.contentScaleFactor = UIScreen.main.scale
        context.coordinator.visibleSemanticClasses = visibleSemanticClasses
        viewModel.attachSession(view.session)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.visibleSemanticClasses = visibleSemanticClasses
        context.coordinator.refreshVisibility()
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        private struct OverlayKey: Hashable {
            let anchorID: UUID
            let semanticClass: SemanticSurfaceClass
        }

        var visibleSemanticClasses: Set<SemanticSurfaceClass> = SemanticSurfaceClass.defaultVisible
        private var overlayNodesByKey: [OverlayKey: SCNNode] = [:]
        private var overlaySignatureByKey: [OverlayKey: Int] = [:]

        func refreshVisibility() {
            for (key, node) in overlayNodesByKey {
                node.isHidden = !visibleSemanticClasses.contains(key.semanticClass)
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            updateSemanticOverlay(in: node, from: meshAnchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            updateSemanticOverlay(in: node, from: meshAnchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            guard anchor is ARMeshAnchor else { return }

            let staleKeys = overlayNodesByKey.keys.filter { $0.anchorID == anchor.identifier }
            for key in staleKeys {
                overlayNodesByKey.removeValue(forKey: key)
                overlaySignatureByKey.removeValue(forKey: key)
            }
        }

        private func updateSemanticOverlay(in anchorNode: SCNNode, from meshAnchor: ARMeshAnchor) {
            let groups = makeSemanticGroups(from: meshAnchor)
            var liveKeys: Set<OverlayKey> = []

            for group in groups where !group.vertices.isEmpty {
                let key = OverlayKey(anchorID: meshAnchor.identifier, semanticClass: group.semanticClass)
                liveKeys.insert(key)

                let node = overlayNodesByKey[key] ?? {
                    let node = SCNNode()
                    anchorNode.addChildNode(node)
                    overlayNodesByKey[key] = node
                    return node
                }()

                node.isHidden = !visibleSemanticClasses.contains(group.semanticClass)

                let signature = signature(for: group)
                guard overlaySignatureByKey[key] != signature else { continue }

                node.geometry = makeGeometry(for: group)
                overlaySignatureByKey[key] = signature
            }

            let staleKeys = overlayNodesByKey.keys.filter { $0.anchorID == meshAnchor.identifier && !liveKeys.contains($0) }
            for key in staleKeys {
                overlayNodesByKey[key]?.removeFromParentNode()
                overlayNodesByKey.removeValue(forKey: key)
                overlaySignatureByKey.removeValue(forKey: key)
            }
        }

        private func makeGeometry(for group: SemanticMeshGroup) -> SCNGeometry {
            let vertices = group.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: vertices)
            let indices: [UInt32]
            if group.triangleIndices.isEmpty {
                indices = Array(0..<group.vertices.count).map { UInt32($0) }
            } else {
                indices = group.triangleIndices.flatMap { [$0.x, $0.y, $0.z] }
            }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )

            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = group.semanticClass.uiColor.withAlphaComponent(0.55)
            material.emission.contents = group.semanticClass.uiColor.withAlphaComponent(0.2)
            material.isDoubleSided = true
            material.fillMode = .fill
            material.lightingModel = .constant
            geometry.materials = [material]
            return geometry
        }

        private func makeSemanticGroups(from anchor: ARMeshAnchor) -> [SemanticMeshGroup] {
            var accumulatorsByClass: [SemanticSurfaceClass: MeshAccumulator] = [:]
            let faceCount = anchor.geometry.faces.count
            let localVertices = anchor.geometry.localVertices()

            for faceIndex in 0..<faceCount {
                let semanticClass = anchor.geometry.semanticClassOf(faceWithIndex: faceIndex)
                let indices = anchor.geometry.vertexIndicesOf(faceWithIndex: faceIndex)
                var accumulator = accumulatorsByClass[semanticClass, default: MeshAccumulator()]
                let triangle = SIMD3(
                    accumulator.index(for: indices.0, in: localVertices),
                    accumulator.index(for: indices.1, in: localVertices),
                    accumulator.index(for: indices.2, in: localVertices)
                )
                accumulator.triangleIndices.append(triangle)
                accumulatorsByClass[semanticClass] = accumulator
            }

            return accumulatorsByClass
                .map { semanticClass, accumulator in
                    return SemanticMeshGroup(
                        semanticClass: semanticClass,
                        vertices: accumulator.vertices,
                        triangleIndices: accumulator.triangleIndices
                    )
                }
                .sorted { $0.semanticClass.rawValue < $1.semanticClass.rawValue }
        }

        private func signature(for group: SemanticMeshGroup) -> Int {
            var hasher = Hasher()
            hasher.combine(group.vertices.count)
            hasher.combine(group.triangleIndices.count)

            let sampleStride = max(1, group.vertices.count / 12)
            for index in stride(from: 0, to: group.vertices.count, by: sampleStride) {
                let vertex = group.vertices[index]
                hasher.combine(vertex.x.bitPattern)
                hasher.combine(vertex.y.bitPattern)
                hasher.combine(vertex.z.bitPattern)
            }

            let triangleSampleStride = max(1, group.triangleIndices.count / 12)
            for index in stride(from: 0, to: group.triangleIndices.count, by: triangleSampleStride) {
                let triangle = group.triangleIndices[index]
                hasher.combine(triangle.x)
                hasher.combine(triangle.y)
                hasher.combine(triangle.z)
            }

            return hasher.finalize()
        }
    }
}

private extension ARMeshGeometry {
    func localVertices() -> [SIMD3<Float>] {
        (0..<vertices.count).map { index in
            vertex(at: UInt32(index))
        }
    }

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
        guard let classification else { return .geometry }
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
        case .none: return .geometry
        @unknown default: return .geometry
        }
    }
}

private extension ARViewContainer.Coordinator {
    struct MeshAccumulator {
        var vertices: [SIMD3<Float>] = []
        var triangleIndices: [SIMD3<UInt32>] = []
        var remappedIndicesByOriginalIndex: [UInt32: UInt32] = [:]

        mutating func index(for originalIndex: UInt32, in sourceVertices: [SIMD3<Float>]) -> UInt32 {
            if let remapped = remappedIndicesByOriginalIndex[originalIndex] {
                return remapped
            }

            let newIndex = UInt32(vertices.count)
            vertices.append(sourceVertices[Int(originalIndex)])
            remappedIndicesByOriginalIndex[originalIndex] = newIndex
            return newIndex
        }
    }
}
