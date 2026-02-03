import SwiftUI
import SceneKit
import UIKit
import simd
import MapKit

/// A renderable cloud item in world coordinates.
struct CloudVoxelItem: Identifiable, Hashable {
    let id: UInt64
    let coordinate: CLLocationCoordinate2D
    let sizeMeters: Double
    let altitudeMeters: Double
    let asset: CloudAsset
    let seed: UInt64
}

/// True 3D voxel/low-poly clouds rendered in a single SceneKit view.
///
/// This avoids the old sprite-snapshot approach (which can create pink halos)
/// and ensures clouds remain true 3D when the map is rotated/pitched.
struct CloudVoxelOverlayView: UIViewRepresentable {
    let items: [CloudVoxelItem]
    let viewportSize: CGSize
    let centerCoordinate: CLLocationCoordinate2D
    let metersPerPoint: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.allowsCameraControl = false
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = .multisampling4X

        v.scene = context.coordinator.scene
        context.coordinator.configureIfNeeded(for: v)
        return v
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.update(
            items: items,
            viewportSize: viewportSize,
            centerCoordinate: centerCoordinate,
            metersPerPoint: metersPerPoint
        )
    }

    // MARK: - Coordinator

    final class Coordinator {
        private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "CloudVoxelOverlay")
        let scene = SCNScene()
        private let cloudRoot = SCNNode()
        private let cameraNode = SCNNode()
        private let lightNode = SCNNode()

        // Cache nodes per cloud id to avoid re-creating geometry each frame.
        private var cloudNodes: [UInt64: SCNNode] = [:]

        // Prototypes loaded from bundled USDZ assets.
        // We clone these per cloud so we get TRUE 3D from the supplied models.
        private var prototypes: [CloudAsset: SCNNode] = [:]

        private var didConfigure: Bool = false

        init() {
            scene.rootNode.addChildNode(cloudRoot)

            let cam = SCNCamera()
            cam.usesOrthographicProjection = true
            cam.orthographicScale = 500 // updated per-frame
            cam.zNear = 0.1
            cam.zFar = 10000
            cameraNode.camera = cam
            cameraNode.position = SCNVector3(0, 0, 1200)
            scene.rootNode.addChildNode(cameraNode)

            let light = SCNLight()
            light.type = .directional
            light.intensity = 1200
            lightNode.light = light
            lightNode.eulerAngles = SCNVector3(-0.8, 0.6, 0)
            scene.rootNode.addChildNode(lightNode)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 320
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)
        }

        func configureIfNeeded(for view: SCNView) {
            guard !didConfigure else { return }
            didConfigure = true
            // Ensure the SceneKit layer keeps alpha.
            view.layer.isOpaque = false
            view.layer.backgroundColor = UIColor.clear.cgColor
            // Explicitly set the camera.
            view.pointOfView = cameraNode
        }

        func update(
            items: [CloudVoxelItem],
            viewportSize: CGSize,
            centerCoordinate: CLLocationCoordinate2D,
            metersPerPoint: Double
        ) {
            // Prevent implicit SceneKit animations when we update transforms.
            // Without this, SceneKit may interpolate Euler angles across wrap boundaries (±π)
            // and you can get an unwanted full 360° spin.
            SCNTransaction.begin()
            SCNTransaction.disableActions = true

            // IMPORTANT: the clouds must stay anchored to the map content.
            // If we rotate/tilt the *camera* while positioning clouds in screen-space,
            // the projection changes and the clouds will “swim”/move with the camera.
            // So we keep the SceneKit camera fixed and keep cloud orientation stable.
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
            if let cam = cameraNode.camera {
                cam.usesOrthographicProjection = true
                let viewportHeightMeters = Double(viewportSize.height) * max(0.0001, metersPerPoint)
                cam.orthographicScale = max(200.0, viewportHeightMeters * 0.5)
            }

            // Keep the SceneKit world origin stable; we map map-world deltas into scene units.
            cloudRoot.position = SCNVector3(0, 0, 0)

            let centerMapPoint = MKMapPoint(centerCoordinate)
            let metersPerMapPoint = max(0.0001, MKMetersPerMapPointAtLatitude(centerCoordinate.latitude))
            let sceneUnitsPerMeter = 1.0

            // Remove missing.
            let incoming = Set(items.map { $0.id })
            for (id, node) in cloudNodes where !incoming.contains(id) {
                node.removeFromParentNode()
                cloudNodes.removeValue(forKey: id)
            }

            // Update / create.
            for item in items {
                let node: SCNNode
                if let existing = cloudNodes[item.id] {
                    node = existing
                } else {
                    node = makeAssetCloud(asset: item.asset, seed: item.seed)
                    cloudNodes[item.id] = node
                    cloudRoot.addChildNode(node)
                }

                if node.parent !== cloudRoot {
                    node.removeFromParentNode()
                    cloudRoot.addChildNode(node)
                }

                // Position in map/world space -> SceneKit world space (no screen-space projection).
                let mapPoint = MKMapPoint(item.coordinate)
                let dxMeters = (mapPoint.x - centerMapPoint.x) * metersPerMapPoint
                let dyMeters = (mapPoint.y - centerMapPoint.y) * metersPerMapPoint
                let x = Float(dxMeters * sceneUnitsPerMeter)
                let y = Float(dyMeters * sceneUnitsPerMeter)

                // Height: user wants clouds LOWER.
                // Keep them above buildings when pitched, but not floating too high.
                // ~200m -> ~45 Scene units.
                let z = Float(min(24, max(0, item.altitudeMeters * 0.06 * sceneUnitsPerMeter)))
                node.position = SCNVector3(x, -y, z)

                // Scale: use world size (meters) projected into points.
                // USDZ units vary, so keep a conservative world scale.
                let scaleBase: Float
                switch item.asset {
                case .stylized: scaleBase = 0.95
                case .cartoon:  scaleBase = 0.88
                case .tiny:     scaleBase = 0.74
                }
                // Bigger overall scaling (user asked: MUCH larger clouds).
                let sizeUnits = item.sizeMeters * sceneUnitsPerMeter
                let s = Float(max(0.10, sizeUnits / 340.0)) * scaleBase
                node.scale = SCNVector3(s, s, s)

                // Orientation: deterministic, seed-only yaw (no camera-driven pitch/roll).
                let baseYaw = Float((Double(item.seed & 0xFFFF) / 65535.0) * 2.0 * .pi)

                // Fixed yaw offset to keep a subtle, consistent facing adjustment.
                let yaw: Float = Self.wrapRadians(baseYaw + Self.facingYawOffset)
                let qYaw: simd_quatf = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                node.simdOrientation = qYaw
            }

            SCNTransaction.commit()
        }

        private static func centerPivot(_ node: SCNNode) {
            // Ensure rotations don't shift the node in screen-space.
            // Pivot affects how SceneKit applies rotations. 
            let (minV, maxV) = node.boundingBox
            let cx = (minV.x + maxV.x) * 0.5
            let cy = (minV.y + maxV.y) * 0.5
            let cz = (minV.z + maxV.z) * 0.5
            node.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)
        }


        private func makeAssetCloud(asset: CloudAsset, seed: UInt64) -> SCNNode {
            // Load prototype once.
            let proto: SCNNode
            if let cached = prototypes[asset] {
                proto = cached
            } else {
                proto = loadPrototype(asset: asset)
                prototypes[asset] = proto
            }

            // Clone to keep per-cloud transforms independent.
            // Flattened clone is cheaper to render than a deep graph.
            let node = proto.flattenedClone()
            Self.enforceYAxisBillboards(node)
            Self.centerPivot(node)

            // Ensure we keep alpha if the model uses it.
            node.enumerateChildNodes { child, _ in
                child.geometry?.materials.forEach { m in
                    m.writesToDepthBuffer = true
                    m.readsFromDepthBuffer = true
                    // Keep whatever the asset provides, but ensure alpha blending is allowed.
                    if m.transparency < 1.0 {
                        m.blendMode = .alpha
                    }
                }
            }

            return node
        }

        private static func enforceYAxisBillboards(_ node: SCNNode) {
            if let constraints = node.constraints {
                for constraint in constraints {
                    if let billboard = constraint as? SCNBillboardConstraint {
                        billboard.freeAxes = [.Y]
                    }
                }
            }
            node.enumerateChildNodes { child, _ in
                if let constraints = child.constraints {
                    for constraint in constraints {
                        if let billboard = constraint as? SCNBillboardConstraint {
                            billboard.freeAxes = [.Y]
                        }
                    }
                }
            }
        }

        private static func makeFallbackVoxelCloud() -> SCNNode {
            // Simple low-poly fallback so clouds are never invisible if the USDZ is missing.
            let container = SCNNode()
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = UIColor(white: 1.0, alpha: 0.95)
            mat.roughness.contents = 0.9
            mat.metalness.contents = 0.0

            // Build a small voxel blob out of boxes.
            let boxes: [(Float, Float, Float, Float)] = [
                (0, 0, 0, 1.2),
                (1.1, 0.2, 0.1, 0.95),
                (-1.0, -0.1, 0.0, 0.9),
                (0.3, 0.9, 0.0, 0.85),
                (-0.4, 0.8, -0.1, 0.8),
                (0.7, -0.8, 0.0, 0.8),
            ]
            for (x, y, z, s) in boxes {
                let g = SCNBox(width: CGFloat(120 * s), height: CGFloat(90 * s), length: CGFloat(90 * s), chamferRadius: 12)
                g.materials = [mat]
                let n = SCNNode(geometry: g)
                n.position = SCNVector3(x * 70, y * 60, z * 40)
                container.addChildNode(n)
            }
            return node
        }

        // MARK: - Tiny RNG

        private struct SplitMix {
            private var state: UInt64
            init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
            mutating func nextUInt64() -> UInt64 {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            mutating func nextDouble() -> Double {
                Double(nextUInt64() >> 11) / Double(1 << 53)
            }
        }
    }
}
