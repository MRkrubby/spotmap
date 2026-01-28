import SwiftUI

/// Main tab layout.
///
/// Home tab is the "control center" so users can do everything from one place
/// without a cluttered UI.
struct RootTabView: View {
    // Default OFF: CloudKit/entitlements might not be configured on fresh installs.
    // The user can enable this in Settings once iCloud/CloudKit is set up.
    @AppStorage("Friends.enabled") private var friendsEnabled: Bool = false
    @AppStorage("Friends.displayName") private var friendsDisplayName: String = "Ik"

    @StateObject private var journeys = JourneyRepository()
    @StateObject private var nav = NavigationManager()
    @StateObject private var friends = FriendsStore()
    @State private var isAutoRefreshRunning = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            SpotMapView()
                .tabItem { Label("Home", systemImage: "house") }

            JourneysView()
                .tabItem { Label("Journeys", systemImage: "car") }
        }
        .environmentObject(journeys)
        .environmentObject(nav)
        .environmentObject(friends)
        .onAppear {
            friends.isEnabled = friendsEnabled
            // Don't auto-publish unless enabled (avoids CloudKit calls on setups without entitlements).
            friends.setDisplayName(friendsDisplayName)
            if friendsEnabled {
                startAutoRefreshIfNeeded()
                Task { await friends.publish() }
            } else {
                stopAutoRefreshIfNeeded()
            }
        }
        .onChange(of: friendsEnabled) { _, v in
            friends.isEnabled = v
            if !v {
                stopAutoRefreshIfNeeded()
            } else if scenePhase == .active {
                startAutoRefreshIfNeeded()
            }
            Task { await friends.publish() }
        }
        .onChange(of: friendsDisplayName) { _, v in
            friends.setDisplayName(v)
            if friendsEnabled {
                Task { await friends.publish() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if friendsEnabled {
                    startAutoRefreshIfNeeded()
                }
            case .inactive, .background:
                stopAutoRefreshIfNeeded()
            @unknown default:
                stopAutoRefreshIfNeeded()
            }
        }
    }

    private func startAutoRefreshIfNeeded() {
        guard !isAutoRefreshRunning else { return }
        friends.startAutoRefresh()
        isAutoRefreshRunning = true
    }

    private func stopAutoRefreshIfNeeded() {
        guard isAutoRefreshRunning else { return }
        friends.stopAutoRefresh()
        isAutoRefreshRunning = false
    }
}
