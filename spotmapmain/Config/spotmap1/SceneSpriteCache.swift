import UIKit
import SceneKit
import SceneKit.ModelIO
import Metal
import os

/// Renders USDZ models into cached transparent sprites.
///
/// Why:
/// - Hundreds of `SCNView` instances (one per cloud/tree) kills responsiveness.
/// - Sprite caching keeps the "3D look" while rendering extremely fast.
///
/// This is intentionally conservative: we quantize variants to a small set
/// so the cache stays small and deterministic.
final class SceneSpriteCache {
    static let shared = SceneSpriteCache()

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "SpriteCache")
    private let lock = NSLock()

    private struct Key: Hashable {
        let assetPath: String
        let variant: Int
        let kind: Kind
        let size: Int
    }

    private enum Kind: Int {
        case cloud
        case tree
    }

    private var cache: [Key: UIImage] = [:]
    private var modelProto: [String: SCNNode] = [:]

    private lazy var device: MTLDevice? = {
        let d = MTLCreateSystemDefaultDevice()
        if d == nil { log.error("Metal device unavailable — sprite rendering may fail") }
        return d
    }()

    // MARK: - Public API

    func cloudSprite(asset: CloudAsset, variant: Int, size: Int = 256) -> UIImage {
        sprite(kind: .cloud, assetPath: asset.rawValue, variant: variant, size: size) { model in
            // Cloud camera: orthographic, slightly front-top.
            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.camera?.usesOrthographicProjection = true
            cam.camera?.orthographicScale = 1.2
            cam.position = SCNVector3(0, 0.35, 2.2)
            model.addChildNode(cam)
            return cam
        } lights: { root in
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 450
            root.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.eulerAngles = SCNVector3(-0.55, 0.3, 0)
            root.addChildNode(key)
        } pose: { node in
            // Deterministic pose per variant.
            var rng = SplitMix64(seed: UInt64(variant) &* 0x9E3779B97F4A7C15)
            let s = Float(0.92 + 0.22 * rng.nextDouble())
            let lift = Float(0.04 + 0.10 * rng.nextDouble())
            node.scale = SCNVector3(s, s, s)
            if let yaw = CloudOrientationPolicy.current.yawRadians(seed: UInt64(variant)) {
                node.eulerAngles = SCNVector3(0, yaw, 0)
            } else {
                let billboard = SCNBillboardConstraint()
                billboard.freeAxes = [.Y]
                node.constraints = (node.constraints ?? []) + [billboard]
            }
            node.position = SCNVector3(0, lift, 0)
        }
    }

    func treeSprite(asset: TreeAsset, variant: Int, size: Int = 256) -> UIImage {
        sprite(kind: .tree, assetPath: asset.rawValue, variant: variant, size: size) { model in
            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.camera?.usesOrthographicProjection = true
            cam.camera?.orthographicScale = 1.25
            cam.position = SCNVector3(0, 1.25, 2.35)
            cam.eulerAngles = SCNVector3(-0.32, 0, 0)
            model.addChildNode(cam)
            return cam
        } lights: { root in
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 520
            root.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 1150
            key.eulerAngles = SCNVector3(-0.65, 0.35, 0)
            root.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .directional
            fill.light?.intensity = 420
            fill.eulerAngles = SCNVector3(-0.25, -0.9, 0)
            root.addChildNode(fill)
        } pose: { node in
            var rng = SplitMix64(seed: UInt64(variant) &* 0xD1E5A11D)
            let rot = Float(rng.nextDouble() * Double.pi * 2.0)
            let s = Float(0.85 + 0.25 * rng.nextDouble())
            node.eulerAngles = SCNVector3(0, rot, 0)
            node.scale = SCNVector3(s, s, s)
            node.position = SCNVector3Zero
        }
    }

    // MARK: - Core rendering

    private func sprite(
        kind: Kind,
        assetPath: String,
        variant: Int,
        size: Int,
        camera: (SCNNode) -> SCNNode,
        lights: (SCNNode) -> Void,
        pose: (SCNNode) -> Void
    ) -> UIImage {
        let v = max(0, min(63, variant)) // hard cap: keeps cache bounded
        let key = Key(assetPath: assetPath, variant: v, kind: kind, size: size)

        lock.lock()
        if let img = cache[key] {
            lock.unlock()
            return img
        }
        lock.unlock()

        // Build scene.
        let scene = SCNScene()
        scene.background.contents = UIColor.magenta // chroma key -> transparent

        let root = scene.rootNode
        lights(root)

        // Load model prototype and clone it.
        let proto = loadPrototype(assetPath: assetPath, kind: kind)
        let model = proto.clone()
        normalizePivot(model)
        pose(model)
        root.addChildNode(model)

        let pov = camera(root)

        // Auto-frame the orthographic camera to the model bounds so we don't get empty sprites.
        self.frameOrthoCamera(pov, toFit: model, padding: kind == .cloud ? 1.25 : 1.15)

        let image: UIImage
        if let device {
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = pov
            let raw = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
            // Replace the magenta clear-color with transparency (works even if the snapshot is opaque).
            let keyed = Self.chromaKeyMagenta(raw)
            // If it's basically empty (all background), treat as missing to trigger fallbacks.
            image = Self.isMostlyTransparent(keyed) ? UIImage() : keyed
        } else {
            // Worst-case fallback: empty transparent image.
            image = UIImage()
        }

        lock.lock()
        cache[key] = image
        lock.unlock()

        return image
    }

    private func loadPrototype(assetPath: String, kind: Kind) -> SCNNode {
        lock.lock(); defer { lock.unlock() }
        if let p = modelProto[assetPath] { return p }

        let fallback: AssetBundleResolver.FallbackNode = kind == .cloud ? .voxelCloud : .empty
        let node = AssetBundleResolver.loadSceneNode(
            assetPath: assetPath,
            log: log,
            fallback: fallback
        ) { url in
            // Prefer ModelIO for USDZ: it tends to preserve materials and gives stable bounds.
            let mdlAsset = MDLAsset(url: url)
            let scene = SCNScene(mdlAsset: mdlAsset)
            // Flatten so bounding boxes/pivots are reliable for sprite framing.
            return scene.rootNode.flattenedClone()
        }

        Self.enforceYAxisBillboards(node)
        modelProto[assetPath] = node
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

    private func normalizePivot(_ node: SCNNode) {
        // Center pivot using a *recursive* bounds calculation.
        let (minV, maxV) = Self.recursiveBounds(node)
        let center = SCNVector3((minV.x + maxV.x) * 0.5, (minV.y + maxV.y) * 0.5, (minV.z + maxV.z) * 0.5)
        node.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
    }

    private func frameOrthoCamera(_ pov: SCNNode, toFit node: SCNNode, padding: CGFloat) {
        guard let cam = pov.camera else { return }
        cam.usesOrthographicProjection = true

        // Get recursive bounds AFTER pivot + pose.
        let (minV, maxV) = Self.recursiveBounds(node)
        let dx = CGFloat(maxV.x - minV.x)
        let dy = CGFloat(maxV.y - minV.y)
        let dz = CGFloat(maxV.z - minV.z)

        let span = max(dx, dy)
        // orthographicScale is the vertical span in scene units.
        cam.orthographicScale = Double(max(0.001, span * padding))

        // Distance doesn't affect size in ortho, but avoids clipping.
        let radius = max(0.05, max(span, dz) * 0.6)
        cam.zNear = 0.001
        cam.zFar = Double(radius * 40)

        // Place camera in front with a mild elevation for nicer shading.
        // Keep existing eulerAngles if caller set them.
        let cx = (minV.x + maxV.x) * 0.5
        let cy = (minV.y + maxV.y) * 0.5
        let lift = cy + Float(dy * 0.12)
        pov.position = SCNVector3(cx, lift, Float(radius * 3.0))
    }

    // MARK: - Chroma key + blank detection

    private static func chromaKeyMagenta(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Key out magenta (#FF00FF) with tolerance.
        let tol = 18
        var nonBg = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = Int(data[i + 0])
                let g = Int(data[i + 1])
                let b = Int(data[i + 2])
                let a = Int(data[i + 3])

                if abs(r - 255) <= tol && abs(g - 0) <= tol && abs(b - 255) <= tol {
                    data[i + 3] = 0
                } else if a > 10 {
                    nonBg += 1
                }
            }
        }

        if nonBg == 0 {
            // Entirely background.
            return UIImage()
        }

        guard let outCG = ctx.makeImage() else { return image }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func isMostlyTransparent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return true
        }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample a coarse grid for speed.
        let stepX = max(1, width / 32)
        let stepY = max(1, height / 32)
        var solid = 0
        var total = 0

        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let i = (y * bytesPerRow) + (x * bytesPerPixel)
                let a = Int(data[i + 3])
                total += 1
                if a > 8 { solid += 1 }
            }
        }

        // If <1.5% of sampled pixels are opaque, treat as empty.
        return solid * 1000 < total * 15
    }

    private static func recursiveBounds(_ node: SCNNode) -> (SCNVector3, SCNVector3) {
        // Combine bounds of all child geometries in the node's local space.
        var minV = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxV = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

        func include(_ n: SCNNode) {
            let (bmin, bmax) = n.boundingBox
            let isZeroBox = (bmin.x == 0 && bmin.y == 0 && bmin.z == 0 && bmax.x == 0 && bmax.y == 0 && bmax.z == 0)

            if !isZeroBox {
                let corners = [
                    SCNVector3(bmin.x, bmin.y, bmin.z), SCNVector3(bmin.x, bmin.y, bmax.z),
                    SCNVector3(bmin.x, bmax.y, bmin.z), SCNVector3(bmin.x, bmax.y, bmax.z),
                    SCNVector3(bmax.x, bmin.y, bmin.z), SCNVector3(bmax.x, bmin.y, bmax.z),
                    SCNVector3(bmax.x, bmax.y, bmin.z), SCNVector3(bmax.x, bmax.y, bmax.z)
                ]

                for c in corners {
                    let v = n.convertPosition(c, to: node)
                    minV.x = min(minV.x, v.x); minV.y = min(minV.y, v.y); minV.z = min(minV.z, v.z)
                    maxV.x = max(maxV.x, v.x); maxV.y = max(maxV.y, v.y); maxV.z = max(maxV.z, v.z)
                }
            }

            for ch in n.childNodes {
                include(ch)
            }
        }

        include(node)

        if minV.x == Float.greatestFiniteMagnitude {
            // Empty fallback
            minV = SCNVector3(-0.5, -0.5, -0.5)
            maxV = SCNVector3(0.5, 0.5, 0.5)
        }

        return (minV, maxV)
    }


}

    // MARK: - RNG

fileprivate struct SplitMix64 {
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
