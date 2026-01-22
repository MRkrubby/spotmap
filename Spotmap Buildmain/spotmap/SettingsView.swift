import SwiftUI
import MapKit

struct SettingsView: View {
    @ObservedObject var repo: SpotRepository
    let currentCenter: () -> CLLocationCoordinate2D

    @Environment(\.dismiss) private var dismiss
    @State private var showingCloudKitHelp = false
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false
    @AppStorage("Friends.enabled") private var friendsEnabled: Bool = true
    @AppStorage("Friends.displayName") private var friendsDisplayName: String = "Ik"

    var body: some View {
        NavigationStack {
            Form {
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
    Toggle("Explore-modus (kaart vrijspelen)", isOn: $exploreEnabled)
    Text("In Explore-modus is de kaart rustiger (muted) en kleurt je route de bezochte gebieden in.")
        .font(.footnote)
        .foregroundStyle(.secondary)
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
