import SwiftUI
import MapKit

/// Legacy overlay implementation (not used by default).
/// Kept to avoid breaking Xcode project file references.
struct FogOfWarOverlay: View {
    let proxy: MapProxy
    let clouds: [FogCloud]

    var body: some View {
        ZStack {
            ForEach(clouds) { cloud in
                if let p = proxy.convert(cloud.coordinate, to: .local) {
                    CloudSpriteView(
                        asset: cloud.asset,
                        variant: Int(cloud.seed & 63),
                        sizePoints: cloud.sizePoints,
                        altitudeMeters: cloud.altitudeMeters
                    )
                    .position(p)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
