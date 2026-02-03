import Foundation
import UIKit

struct VehicleAsset: Identifiable {
    let id: String
    let displayName: String
    let type: VehicleAssetType
    let iconName: String
    let mapAssetName: String
}

enum VehicleAssetType: String {
    case emergency
    case utility
    case sport
    case suv
    case kart
    case taxi
    case standard

    var iconName: String {
        switch self {
        case .emergency:
            return "cross.case.fill"
        case .utility:
            return "truck.box.fill"
        case .sport:
            return "car.circle.fill"
        case .suv:
            return "car.2.fill"
        case .kart:
            return "steeringwheel"
        case .taxi:
            return "car.fill"
        case .standard:
            return "car.fill"
        }
    }

    var mapAssetName: String {
        "vehicle_\(rawValue)"
    }
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
            guard let urls = Bundle.main.urls(
                forResourcesWithExtension: "obj",
                subdirectory: "vehicle_assets"
            ) else {
                return []
            }

            return urls
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
                    let slug = url.deletingPathExtension().lastPathComponent
                    let metadata = metadata(for: slug)
                    return VehicleAsset(
                        id: slug,
                        displayName: metadata.displayName,
                        type: metadata.type,
                        iconName: metadata.type.iconName,
                        mapAssetName: metadata.type.mapAssetName
                    )
                }
        }

        private static let metadataBySlug: [String: (displayName: String, type: VehicleAssetType)] = [
            "ambulance": ("Ambulance", .emergency),
            "delivery": ("Delivery Van", .utility),
            "delivery-flat": ("Delivery Flatbed", .utility),
            "garbage-truck": ("Garbage Truck", .utility),
            "hatchback-sports": ("Sports Hatchback", .sport),
            "kart-oobi": ("Kart Oobi", .kart),
            "kart-oodi": ("Kart Oodi", .kart),
            "kart-oopi": ("Kart Oopi", .kart),
            "kart-oozi": ("Kart Oozi", .kart),
            "police": ("Police", .emergency),
            "race": ("Race Car", .sport),
            "race-future": ("Future Race Car", .sport),
            "suv": ("SUV", .suv),
            "suv-luxury": ("Luxury SUV", .suv),
            "taxi": ("Taxi", .taxi),
            "tractor-shovel": ("Tractor Shovel", .utility)
        ]

        private static func metadata(for slug: String) -> (displayName: String, type: VehicleAssetType) {
            if let metadata = metadataBySlug[slug] {
                return metadata
            }

            let displayName = slug
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
            return (displayName, .standard)
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
