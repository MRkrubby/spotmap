import Foundation

struct AchievementBadge: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let progress: Double
    let isUnlocked: Bool
}

struct ExploreFact: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
}

enum AchievementsCatalog {
    static func badges(totalKm: Double, visitedCities: Int, visitedTiles: Int, journeys: [JourneyRecord]) -> [AchievementBadge] {
        let distanceBadge = badge(
            id: "distance-500",
            title: "Road Warrior",
            subtitle: "Rijd 500 km totaal",
            systemImage: "car.fill",
            current: totalKm,
            target: 500
        )

        let explorerBadge = badge(
            id: "tiles-500",
            title: "Explorer",
            subtitle: "Ontdek 500 kaart-tegels",
            systemImage: "square.grid.3x3.fill",
            current: Double(visitedTiles),
            target: 500
        )

        let citiesBadge = badge(
            id: "cities-25",
            title: "City Hopper",
            subtitle: "Bezoek 25 steden",
            systemImage: "building.2.fill",
            current: Double(visitedCities),
            target: 25
        )

        let streakBadge = badge(
            id: "streak-7",
            title: "Daily Driver",
            subtitle: "7 dagen rijden",
            systemImage: "calendar",
            current: Double(uniqueJourneyDays(journeys)),
            target: 7
        )

        return [distanceBadge, explorerBadge, citiesBadge, streakBadge]
    }

    static func facts(totalKm: Double, visitedCities: Int, visitedTiles: Int, journeys: [JourneyRecord]) -> [ExploreFact] {
        let longest = journeys.map(\.distanceMeters).max() ?? 0
        let duration = journeys.map(\.duration).reduce(0, +)
        let weightedSpeedTotal = journeys.reduce(0) { $0 + ($1.avgSpeedMps * $1.duration) }
        let avgSpeed = duration > 0 ? weightedSpeedTotal / duration : 0

        return [
            ExploreFact(
                id: "total-km",
                title: "Totale afstand",
                value: String(format: "%.0f km", totalKm),
                detail: "Alle ritten samen"
            ),
            ExploreFact(
                id: "longest",
                title: "Langste rit",
                value: JourneyFormat.km(longest),
                detail: "Grootste afstand in één rit"
            ),
            ExploreFact(
                id: "avg-speed",
                title: "Gem. snelheid",
                value: JourneyFormat.speedKmh(avgSpeed),
                detail: "Gewogen gemiddelde snelheid op basis van ritduur"
            ),
            ExploreFact(
                id: "cities",
                title: "Steden ontdekt",
                value: "\(visitedCities)",
                detail: "Unieke steden en dorpen"
            ),
            ExploreFact(
                id: "tiles",
                title: "Kaart-tegels",
                value: "\(visitedTiles)",
                detail: "Unieke kaart-tegels verkend"
            ),
            ExploreFact(
                id: "drive-time",
                title: "Rijtijd",
                value: JourneyFormat.duration(duration),
                detail: "Totale tijd onderweg"
            )
        ]
    }

    private static func badge(id: String, title: String, subtitle: String, systemImage: String, current: Double, target: Double) -> AchievementBadge {
        let progress = min(1, max(0, current / max(1, target)))
        return AchievementBadge(
            id: id,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            progress: progress,
            isUnlocked: current >= target
        )
    }

    private static func uniqueJourneyDays(_ journeys: [JourneyRecord]) -> Int {
        let cal = Calendar.current
        let days = journeys.map { cal.startOfDay(for: $0.startedAt) }
        return Set(days).count
    }
}
