import SwiftUI

/// Fast "3D-looking" cloud by rendering a cached sprite from a USDZ model.
///
/// This keeps the app responsive (no per-cloud SCNView) while still using
/// the provided 3D assets.
struct CloudSpriteView: View {
    let asset: CloudAsset
    let variant: Int
    let sizePoints: CGFloat
    let altitudeMeters: Double

    var body: some View {
        // Quantize to a small set of variants to keep sprite generation bounded.
        let v = ((variant % 24) + 24) % 24
        let img = SceneSpriteCache.shared.cloudSprite(asset: asset, variant: v)

        // Altitude -> slight scale + vertical lift, for a subtle "layer" feel.
        let alt = max(0, min(1400, altitudeMeters))
        let altScale = 1.0 - (alt / 1400.0) * 0.18
        let lift = CGFloat(alt / 1400.0) * 10

                Group {
            if img.size.width <= 1 || img.size.height <= 1 || (img.cgImage == nil && img.ciImage == nil) {
                // Fallback: simple procedural cloud if the USDZ sprite is missing.
                ProceduralCloudView()
                    .frame(width: sizePoints, height: sizePoints)
                    .scaleEffect(altScale)
                    .offset(y: -lift)
                    .opacity(0.85)
            } else {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: sizePoints, height: sizePoints)
                    .scaleEffect(altScale)
                    .offset(y: -lift)
                    .opacity(0.92)
            }
        }
        .allowsHitTesting(false)
    }
}
