import Foundation
import MapKit

enum FriendRouteDecoder {
    static func polyline(fromZlib data: Data) -> MKPolyline? {
        do {
            let raw = try JourneyCompression.decompress(data)
            let points = try JSONDecoder().decode([JourneyPoint].self, from: raw)
            let coords = points.map { $0.coordinate }
            return MKPolyline(coordinates: coords, count: coords.count)
        } catch {
            return nil
        }
    }
}

struct ExplorePolygon: Identifiable {
    let id: String
    let polygon: MKPolygon
}

enum ExploreOverlay {
    static func visibleVisitedPolygons(in region: MKCoordinateRegion, visitedTileIds: Set<String>) -> [ExplorePolygon] {
        // render only visited tiles that intersect current region (with margin)
        let zoom = 10
        let minLat = region.center.latitude - region.span.latitudeDelta * 0.75
        let maxLat = region.center.latitude + region.span.latitudeDelta * 0.75
        let minLon = region.center.longitude - region.span.longitudeDelta * 0.75
        let maxLon = region.center.longitude + region.span.longitudeDelta * 0.75

        func lon2x(_ lon: Double) -> Int { ExploreStore.lon2tileX(lon, zoom) }
        func lat2y(_ lat: Double) -> Int { ExploreStore.lat2tileY(lat, zoom) }

        let x0 = min(lon2x(minLon), lon2x(maxLon))
        let x1 = max(lon2x(minLon), lon2x(maxLon))
        let y0 = min(lat2y(minLat), lat2y(maxLat))
        let y1 = max(lat2y(minLat), lat2y(maxLat))

        var out: [ExplorePolygon] = []
        // cap to avoid overdraw
        let maxTiles = 220
        var count = 0

        for x in x0...x1 {
            for y in y0...y1 {
                let id = "\(zoom)/\(x)/\(y)"
                guard visitedTileIds.contains(id) else { continue }
                let b = ExploreStore.tileBounds(zoom: zoom, x: x, y: y)
                var coords = [
                    CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.minLon),
                    CLLocationCoordinate2D(latitude: b.maxLat, longitude: b.maxLon),
                    CLLocationCoordinate2D(latitude: b.minLat, longitude: b.maxLon),
                    CLLocationCoordinate2D(latitude: b.minLat, longitude: b.minLon)
                ]
                let poly = MKPolygon(coordinates: &coords, count: coords.count)
                out.append(ExplorePolygon(id: id, polygon: poly))
                count += 1
                if count >= maxTiles { return out }
            }
        }
        return out
    }
}
