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
    @AppStorage("UserLocation.assetId") private var userLocationAssetId: String = "personal-sedan"

    var body: some View {
        let vehicleAssets = VehicleAssetsCatalog.shared.assets
        NavigationStack {
            Form {
                Section("Tracking") {
                    Toggle(
                        "Automatisch routes bijhouden (ook scherm uit)",
                        isOn: Binding(
                            get: { journeys.trackingEnabled },
                            set: { journeys.setTrackingEnabled($0) }
                        )
                    )
                    Text("Voor tracking met scherm uit heeft iOS meestal 'Altijd' locatie-toestemming nodig. SpotMap vraagt dit automatisch zodra je tracking aanzet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Vraag locatie-toestemming opnieuw") {
                        journeys.requestPermissionsIfNeeded()
                    }
                }

                Section("Locatie-stijl") {
                    Picker("Jouw icoon", selection: $userLocationStyleRaw) {
                        ForEach(UserLocationStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    Text("Kies een persoonlijke auto of een voertuig uit het asset pack om je locatie te personaliseren tijdens het rijden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if UserLocationStyle.from(rawValue: userLocationStyleRaw) == .assetPack {
                        if vehicleAssets.isEmpty {
                            Text("Geen vehicle assets gevonden in VehicleAssets/vehicle_assets.json.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Voertuig", selection: $userLocationAssetId) {
                                ForEach(vehicleAssets) { asset in
                                    Text(asset.displayName).tag(asset.id)
                                }
                            }
                        }
                    }
                }

                Section("Backend") {
                    Picker("Opslaan & laden", selection: Binding(
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
                        Text("CloudKit vereist iCloud login én CloudKit-capability in Xcode. Als dit niet is ingesteld, werkt de app alsnog, maar valt terug op cache/lokaal.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Hoe zet ik CloudKit aan?") {
                            showingCloudKitHelp = true
                        }
                    }
                }

                

Section("Explore") {
    Toggle("Explore-modus (fog-of-war)", isOn: $exploreEnabled)
    Text("In Explore-modus is de kaart bedekt met wolken. Door te rijden speel je de omgeving vrij (±20m rondom je route).")
        .font(.footnote)
        .foregroundStyle(.secondary)

    Button("Reset Explore kaart") {
        FogOfWarStore.shared.reset()
    }
}

Section("Vrienden") {
    Toggle("Vrienden delen (prototype)", isOn: $friendsEnabled)
    TextField("Jouw naam", text: $friendsDisplayName)
        .textInputAutocapitalization(.words)

    Text("Deel je code via WhatsApp/DM. Let op: dit is een CloudKit-prototype (werkt alleen als iCloud/CloudKit beschikbaar is).")
        .font(.footnote)
        .foregroundStyle(.secondary)
}
Section("Tips") {
                    Text("• Pannen/zoomen refreshen we alleen op het einde om de app snel te houden.\n• Bij trage iCloud of geen internet wordt na ~10s automatisch gestopt met laden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Instellingen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sluit") { dismiss() }
                }
            }
            .alert("CloudKit inschakelen", isPresented: $showingCloudKitHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    "In Xcode: klik je target → Signing & Capabilities → + Capability → iCloud.\nVink 'CloudKit' aan en selecteer/maak een container.\nZorg ook dat je bent ingelogd in iCloud op je iPhone."
                )
            }
        }
    }
}
