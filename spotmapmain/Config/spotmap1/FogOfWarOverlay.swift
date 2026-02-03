import SwiftUI
import MapKit
import CoreLocation

/// Legacy overlay implementation (not used by default).
/// Kept to avoid breaking Xcode project file references.
struct FogOfWarOverlay: View {
    let proxy: MapProxy
    let clouds: [FogCloud]

    var body: some View {
        ZStack {
            ForEach(clouds) { cloud in
                if let p = proxy.convert(cloud.coordinate, to: .local) {
                    let metersPerPoint = Self.estimateMetersPerPoint(proxy: proxy)
                    let sizePoints = cloud.sizeMeters / max(0.0001, metersPerPoint)
                    CloudSpriteView(
                        asset: cloud.asset,
                        variant: Int(cloud.seed & 63),
                        sizePoints: CGFloat(sizePoints),
                        altitudeMeters: cloud.altitudeMeters
                    )
                    .position(p)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func estimateMetersPerPoint(proxy: MapProxy) -> Double {
        let sample: CGFloat = 120
        let p1 = CGPoint(x: 100, y: 100)
        let p2 = CGPoint(x: p1.x + sample, y: p1.y)
        guard let c1 = proxy.convert(p1, from: .local),
              let c2 = proxy.convert(p2, from: .local) else {
            return 1.0
        }
        let d = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
            .distance(from: CLLocation(latitude: c2.latitude, longitude: c2.longitude))
        return max(0.001, Double(d) / Double(sample))
    }
}
