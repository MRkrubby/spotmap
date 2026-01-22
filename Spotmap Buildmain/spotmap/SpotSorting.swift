import Foundation
import CoreLocation

enum SpotSortMode: String, CaseIterable, Identifiable {
    case recent
    case title
    case distance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent:
            return "Recent"
        case .title:
            return "Naam"
        case .distance:
            return "Afstand"
        }
    }
}

struct SpotSortConfiguration: Equatable {
    var mode: SpotSortMode
    var isAscending: Bool

    func sorted(spots: [Spot], referenceLocation: CLLocation?) -> [Spot] {
        let sorted: [Spot]
        switch mode {
        case .recent:
            sorted = spots.sorted { $0.createdAt > $1.createdAt }
        case .title:
            sorted = spots.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .distance:
            guard let referenceLocation else {
                sorted = spots.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                break
            }
            sorted = spots.sorted {
                $0.location.distance(from: referenceLocation) < $1.location.distance(from: referenceLocation)
            }
        }

        if isAscending {
            return sorted
        }
        return sorted.reversed()
    }
}

enum SpotDistanceFormatter {
    static func string(for distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f m", distance)
        }
        return String(format: "%.1f km", distance / 1000.0)
    }
}
