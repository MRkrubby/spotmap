import Foundation
import CoreLocation
import MapKit

struct JourneyPoint: Codable, Hashable {
    let lat: Double
    let lon: Double
    let ts: Date
    let speedMps: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// Stored journey record with a compressed polyline.
struct JourneyRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var maxSpeedMps: Double
    var avgSpeedMps: Double
    var startLat: Double
    var startLon: Double
    var endLat: Double
    var endLon: Double
    var pointsZlib: Data

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var startCoordinate: CLLocationCoordinate2D { .init(latitude: startLat, longitude: startLon) }
    var endCoordinate: CLLocationCoordinate2D { .init(latitude: endLat, longitude: endLon) }

    func decodedPoints() -> [JourneyPoint] {
        do {
            let raw = try JourneyCompression.decompress(pointsZlib)
            return try JSONDecoder().decode([JourneyPoint].self, from: raw)
        } catch {
            return []
        }
    }

    static func make(from points: [JourneyPoint], startedAt: Date, endedAt: Date, distanceMeters: Double, maxSpeedMps: Double, avgSpeedMps: Double) -> JourneyRecord {
        let start = points.first?.coordinate ?? .init(latitude: 0, longitude: 0)
        let end = points.last?.coordinate ?? start

        let raw = (try? JSONEncoder().encode(points)) ?? Data()
        let zipped = (try? JourneyCompression.compress(raw)) ?? raw

        return JourneyRecord(
            id: UUID(),
            startedAt: startedAt,
            endedAt: endedAt,
            distanceMeters: distanceMeters,
            maxSpeedMps: maxSpeedMps,
            avgSpeedMps: avgSpeedMps,
            startLat: start.latitude,
            startLon: start.longitude,
            endLat: end.latitude,
            endLon: end.longitude,
            pointsZlib: zipped
        )
    }
}

extension JourneyRecord {
    func boundingRegion(paddingFactor: Double = 1.25) -> MKCoordinateRegion {
        let pts = decodedPoints()
        guard !pts.isEmpty else {
            return MKCoordinateRegion(center: startCoordinate, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        }

        var minLat = pts[0].lat, maxLat = pts[0].lat
        var minLon = pts[0].lon, maxLon = pts[0].lon
        for p in pts {
            minLat = min(minLat, p.lat)
            maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon)
            maxLon = max(maxLon, p.lon)
        }

        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let latDelta = max(0.01, (maxLat - minLat) * paddingFactor)
        let lonDelta = max(0.01, (maxLon - minLon) * paddingFactor)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}

enum JourneyFormat {
    static func km(_ meters: Double) -> String {
        let km = meters / 1000
        if km < 10 { return String(format: "%.1f km", km) }
        return String(format: "%.0f km", km) 
    }

    static func speedKmh(_ mps: Double) -> String {
        let kmh = max(0, mps) * 3.6
        if kmh < 10 { return String(format: "%.1f km/h", kmh) }
        return String(format: "%.0f km/h", kmh)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, r) }
        return String(format: "%d:%02d", m, r)
    }
}
