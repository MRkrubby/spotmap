import SwiftUI

/// Legacy procedural cloud kept for experimentation and to avoid
/// project reference breakage. Not used by default.
struct ProceduralCloudView: View {
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.35)).blur(radius: 6).offset(x: -10)
            Circle().fill(.white.opacity(0.42)).blur(radius: 8)
            Circle().fill(.white.opacity(0.3)).blur(radius: 6).offset(x: 12, y: 4)
        }
        .compositingGroup()
    }
}
