import Foundation

/// Asset catalog for cloud models bundled with the app.
///
/// Keeping this separate from rendering makes it easy to switch between
/// true 3D rendering and fast sprite-based rendering.
enum CloudAsset: String, CaseIterable {
    case stylized = "CloudAssets/StylizedCloud.usdz"
    case cartoon  = "CloudAssets/CartoonCloud.usdz"
    case tiny     = "CloudAssets/TinyCloud.usdz"
}
