import SwiftUI

@main
struct SpotMapApp: App {
    init() {
        AppDiagnostics.setup()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
