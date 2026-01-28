import Foundation
import UIKit

struct VehicleAsset: Identifiable, Decodable {
    let id: String
    let displayName: String
    let iconName: String
    let mapAssetName: String
}

enum VehicleAssetsCatalog {
    static let shared = Catalog()

    final class Catalog {
        private(set) var assets: [VehicleAsset] = []

        init() {
            assets = Self.loadAssets()
        }

        func asset(for id: String) -> VehicleAsset? {
            assets.first { $0.id == id }
        }

        static func loadAssets() -> [VehicleAsset] {
            guard let url = Bundle.main.url(
                forResource: "vehicle_assets",
                withExtension: "json",
                subdirectory: "VehicleAssets"
            ) else {
                return []
            }

            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([VehicleAsset].self, from: data)
            } catch {
                return []
            }
        }
    }
}

extension VehicleAsset {
    var fallbackImage: UIImage? {
        UIImage(systemName: iconName)
    }

    var mapImage: UIImage? {
        UIImage(named: mapAssetName)
    }
}
