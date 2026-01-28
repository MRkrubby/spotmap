import SwiftUI

enum UserLocationStyle: String, CaseIterable, Identifiable {
    case system
    case personalCar
    case assetPack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "Standaard"
        case .personalCar:
            return "Persoonlijke auto"
        case .assetPack:
            return "Asset pack"
        }
    }

    var systemImageName: String {
        switch self {
        case .system:
            return "location.fill"
        case .personalCar:
            return "car.fill"
        case .assetPack:
            return "car.2.fill"
        }
    }

    func mapImage(for asset: VehicleAsset?) -> UIImage? {
        guard self == .assetPack, let asset else { return nil }
        return asset.mapImage ?? asset.fallbackImage
    }
}

extension UserLocationStyle {
    static func from(rawValue: String) -> UserLocationStyle {
        UserLocationStyle(rawValue: rawValue) ?? .system
    }
}

struct UserLocationMarkerView: View {
    let style: UserLocationStyle
    let asset: VehicleAsset?

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .shadow(radius: 6)

            if let image = style.mapImage(for: asset) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityLabel(Text(asset?.displayName ?? style.displayName))
            } else {
                Image(systemName: style.systemImageName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityLabel(Text(style.displayName))
            }
        }
    }
}
