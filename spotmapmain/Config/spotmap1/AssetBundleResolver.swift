import Foundation
import os
import SceneKit
import UIKit

struct AssetBundleResolver {
    enum FallbackNode {
        case empty
        case voxelCloud
    }

    static func resolveURL(for assetPath: String, bundle: Bundle = .main, log: Logger? = nil) -> URL? {
        guard let (subdir, filename, name, ext) = parse(assetPath: assetPath, log: log) else {
            return nil
        }
        let extValue: String? = ext.isEmpty ? nil : ext

        if let subdir, let url = bundle.url(forResource: name, withExtension: extValue, subdirectory: subdir) {
            return url
        }

        if let url = bundle.url(forResource: name, withExtension: extValue) {
            return url
        }

        if let url = bundle.url(forResource: filename, withExtension: nil) {
            return url
        }

        if let resourceURL = bundle.resourceURL,
           let url = caseInsensitiveSearch(for: filename, in: resourceURL) {
            return url
        }

        log?.error("Missing asset in bundle: \(assetPath, privacy: .public)")
        return nil
    }

    static func loadSceneNode(
        assetPath: String,
        bundle: Bundle = .main,
        log: Logger? = nil,
        fallback: FallbackNode = .empty,
        loader: (URL) -> SCNNode?
    ) -> SCNNode {
        let url = resolveURL(for: assetPath, bundle: bundle, log: log)
        if let url, let node = loader(url) {
            return node
        }

        if let url {
            log?.error("Failed to load asset at URL: \(url.absoluteString, privacy: .public)")
        }

        switch fallback {
        case .empty:
            return SCNNode()
        case .voxelCloud:
            return makeFallbackVoxelCloud()
        }
    }

    private static func parse(assetPath: String, log: Logger?) -> (subdir: String?, filename: String, name: String, ext: String)? {
        let parts = assetPath.split(separator: "/")
        guard let filenamePart = parts.last else {
            log?.error("Asset path missing filename: \(assetPath, privacy: .public)")
            return nil
        }
        let filename = String(filenamePart)
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        if parts.count >= 2 {
            let subdir = parts.dropLast().joined(separator: "/")
            return (subdir, filename, name, ext)
        }

        return (nil, filename, name, ext)
    }

    private static func caseInsensitiveSearch(for filename: String, in resourceURL: URL) -> URL? {
        let target = filename.lowercased()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: resourceURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent.lowercased() == target {
                return url
            }
        }
        return nil
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

        // Center pivot.
        let (minV, maxV) = container.boundingBox
        let center = SCNVector3((minV.x + maxV.x) * 0.5, (minV.y + maxV.y) * 0.5, (minV.z + maxV.z) * 0.5)
        container.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        return container
    }
}
