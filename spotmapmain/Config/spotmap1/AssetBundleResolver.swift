import Foundation
import os

struct AssetBundleResolver {
    static func resolveURL(for assetPath: String, bundle: Bundle = .main, log: Logger? = nil) -> URL? {
        let (subdir, filename, name, ext) = parse(assetPath: assetPath)
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

    private static func parse(assetPath: String) -> (subdir: String?, filename: String, name: String, ext: String) {
        let parts = assetPath.split(separator: "/")
        let filename = String(parts.last ?? "")
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
}
