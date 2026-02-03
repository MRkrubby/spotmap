import Foundation
import MapKit

struct RailNode: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
}

enum RailNetwork {
    static let lineNodes: [RailNode] = [
        RailNode(id: "line-ams-centraal", name: "Amsterdam Centraal", coordinate: .init(latitude: 52.3791, longitude: 4.9003)),
        RailNode(id: "line-ams-west", name: "Amsterdam West", coordinate: .init(latitude: 52.3770, longitude: 4.8950)),
        RailNode(id: "line-ams-mid", name: "Amsterdam Centrum", coordinate: .init(latitude: 52.3730, longitude: 4.8860)),
        RailNode(id: "line-ams-zuid", name: "Amsterdam Zuid", coordinate: .init(latitude: 52.3639, longitude: 4.8936)),
        RailNode(id: "line-amstelveen", name: "Amstelveen", coordinate: .init(latitude: 52.3340, longitude: 4.8730)),
        RailNode(id: "line-schiphol", name: "Schiphol", coordinate: .init(latitude: 52.3086, longitude: 4.7639))
    ]

    static let nodes: [RailNode] = [
        RailNode(id: "ams-centraal", name: "Amsterdam Centraal", coordinate: .init(latitude: 52.3791, longitude: 4.9003)),
        RailNode(id: "ams-zuid", name: "Amsterdam Zuid", coordinate: .init(latitude: 52.3639, longitude: 4.8936)),
        RailNode(id: "schiphol", name: "Schiphol", coordinate: .init(latitude: 52.3086, longitude: 4.7639))
    ]

    static let linePolyline: MKPolyline = {
        let coords = lineNodes.map(\.coordinate)
        return MKPolyline(coordinates: coords, count: coords.count)
    }()
}
