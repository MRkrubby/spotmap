import Foundation

enum DeepLink: Equatable {
    case home
    case spot(recordName: String)
    case navigateSpot(recordName: String)
    case journeys
    case journeyToggle

    init?(url: URL) {
        guard url.scheme == "spotmap" else { return nil }

        let pathSegments = url.pathComponents.filter { $0 != "/" }
        let segments: [String]

        if let host = url.host, !host.isEmpty {
            segments = [host] + pathSegments
        } else {
            segments = pathSegments
        }

        guard let first = segments.first else {
            self = .home
            return
        }

        switch first {
        case "spot":
            guard segments.count >= 2 else { return nil }
            self = .spot(recordName: segments[1])

        case "navigate":
            guard segments.count >= 3, segments[1] == "spot" else { return nil }
            self = .navigateSpot(recordName: segments[2])

        case "journeys":
            self = .journeys

        case "journey":
            guard segments.count >= 2, segments[1] == "toggle" else { return nil }
            self = .journeyToggle

        default:
            return nil
        }
    }
}
