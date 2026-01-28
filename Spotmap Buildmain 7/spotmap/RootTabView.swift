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
                friends.startAutoRefresh()
                Task { await friends.publish() }
            } else {
                friends.stopAutoRefresh()
            }
        }
        .onChange(of: friendsEnabled) { _, v in
            friends.isEnabled = v
            if !v { friends.stopAutoRefresh() } else { friends.startAutoRefresh() }
            Task { await friends.publish() }
        }
        .onChange(of: friendsDisplayName) { _, v in
            friends.setDisplayName(v)
            if friendsEnabled {
                Task { await friends.publish() }
            }
        }
    }
}
