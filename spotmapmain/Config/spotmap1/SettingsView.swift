import SwiftUI
import MapKit

struct SettingsView: View {
    @ObservedObject var repo: SpotRepository
    let currentCenter: () -> CLLocationCoordinate2D

    @EnvironmentObject private var journeys: JourneyRepository

    @Environment(\.dismiss) private var dismiss
    @State private var showingCloudKitHelp = false
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false
    @AppStorage("Friends.enabled") private var friendsEnabled: Bool = true
    @AppStorage("Friends.displayName") private var friendsDisplayName: String = "Ik"
    @AppStorage("UserLocation.style") private var userLocationStyleRaw: String = UserLocationStyle.system.rawValue
    @AppStorage("UserLocation.assetId") private var userLocationAssetId: String = "suv"

    var body: some View {
        let vehicleAssets = VehicleAssetsCatalog.shared.assets
        NavigationStack {
            Form {
                Section("settings.tracking") {
                    Toggle(
                        "settings.tracking_toggle",
                        isOn: Binding(
                            get: { journeys.trackingEnabled },
                            set: { journeys.setTrackingEnabled($0) }
                        )
                    )
                    Text("settings.tracking_help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("settings.request_location_permission") {
                        journeys.requestPermissionsIfNeeded()
                    }
                }

                Section("settings.location_style") {
                    Picker("settings.location_icon", selection: $userLocationStyleRaw) {
                        ForEach(UserLocationStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    Text("settings.location_style_help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if UserLocationStyle.from(rawValue: userLocationStyleRaw) == .assetPack {
                        if vehicleAssets.isEmpty {
                            Text("settings.no_vehicle_assets")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("settings.vehicle_picker", selection: $userLocationAssetId) {
                                ForEach(vehicleAssets) { asset in
                                    Text(asset.displayName).tag(asset.id)
                                }
                            }
                        }
                    }
                }

                Section("settings.backend") {
                    Picker("settings.backend_storage", selection: Binding(
                        get: { repo.backend },
                        set: { newValue in
                            let c = currentCenter()
                            repo.setBackend(newValue, currentCenter: CLLocation(latitude: c.latitude, longitude: c.longitude))
                        }
                    )) {
                        ForEach(SpotRepository.Backend.allCases, id: \.self) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }

                    if repo.backend == .cloudKit {
                        Text("settings.cloudkit_help")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("settings.cloudkit_button") {
                            showingCloudKitHelp = true
                        }
                    }
                }

                Section("settings.explore") {
                    Toggle("settings.explore_toggle", isOn: $exploreEnabled)
                    Text("settings.explore_help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("settings.explore_reset") {
                        FogOfWarStore.shared.reset()
                    }
                }

                Section("settings.friends") {
                    Toggle("settings.friends_toggle", isOn: $friendsEnabled)
                    TextField("settings.friends_name", text: $friendsDisplayName)
                        .textInputAutocapitalization(.words)

                    Text("settings.friends_help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("settings.tips") {
                    Text("settings.tips_text")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("settings.close") { dismiss() }
                }
            }
            .alert("settings.cloudkit_alert_title", isPresented: $showingCloudKitHelp) {
                Button("settings.ok", role: .cancel) {}
            } message: {
                Text("settings.cloudkit_alert_message")
            }
        }
    }
}
