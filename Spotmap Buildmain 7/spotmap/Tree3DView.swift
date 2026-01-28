import SwiftUI

/// Legacy wrapper kept to avoid Xcode project reference breakage.
///
/// The app now uses `TreeSpriteView` for performance.
struct Tree3DView: View {
    let asset: TreeAsset
    let seed: UInt64
    let variant: Int
    let scale: Double

    var body: some View {
        TreeSpriteView(asset: asset, variant: variant, sizePoints: CGFloat(72 * scale))
    }
}
