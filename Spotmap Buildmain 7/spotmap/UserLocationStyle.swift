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
}

extension UserLocationStyle {
    static func from(rawValue: String) -> UserLocationStyle {
        UserLocationStyle(rawValue: rawValue) ?? .system
    }
}

struct UserLocationMarkerView: View {
    let style: UserLocationStyle

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .shadow(radius: 6)

            Image(systemName: style.systemImageName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityLabel(Text(style.displayName))
        }
    }
}
