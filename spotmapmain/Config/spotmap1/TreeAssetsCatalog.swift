import Foundation

/// Asset catalog for tree models bundled with the app.
///
/// Expected location in the app bundle:
/// - "TreeAssets/LowPolyTrees.usdz" (keeps folder structure)
/// If Xcode flattens resources, loaders also try the root as a fallback.
enum TreeAsset: String {
    case lowPolyPack = "TreeAssets/LowPolyTrees.usdz"
}
