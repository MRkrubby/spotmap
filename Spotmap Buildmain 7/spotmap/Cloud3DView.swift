import SwiftUI

/// Legacy wrapper kept to avoid Xcode project reference breakage.
///
/// The app now uses `CloudSpriteView` for performance.
struct Cloud3DView: View {
    let asset: CloudAsset
    let seed: UInt64
    let altitudeMeters: Double

    var body: some View {
        CloudSpriteView(
            asset: asset,
            variant: Int(seed & 63),
            sizePoints: 140,
            altitudeMeters: altitudeMeters
        )
    }
}
