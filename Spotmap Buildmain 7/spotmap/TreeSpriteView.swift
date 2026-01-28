import SwiftUI

/// Fast sprite-based tree (rendered from USDZ once, then reused).
struct TreeSpriteView: View {
    let asset: TreeAsset
    let variant: Int
    let sizePoints: CGFloat

    var body: some View {
        let v = ((variant % 16) + 16) % 16
        let img = SceneSpriteCache.shared.treeSprite(asset: asset, variant: v)
                Group {
            if img.size.width <= 1 || img.size.height <= 1 || (img.cgImage == nil && img.ciImage == nil) {
                // Fallback: simple dot if the USDZ sprite is missing.
                Circle()
                    .fill(.green.opacity(0.55))
                    .frame(width: sizePoints * 0.55, height: sizePoints * 0.55)
            } else {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: sizePoints, height: sizePoints)
                    .opacity(0.92)
            }
        }
        .allowsHitTesting(false)
    }
}
