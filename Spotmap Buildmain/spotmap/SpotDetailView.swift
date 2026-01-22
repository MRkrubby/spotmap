import SwiftUI
import MapKit
import UIKit
import CloudKit

struct SpotDetailView: View {
    let spot: Spot
    let isShareEnabled: Bool

    @EnvironmentObject private var repo: SpotRepository
    @EnvironmentObject private var nav: NavigationManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

if let data = spot.photoData, let ui = UIImage(data: data) {
    Image(uiImage: ui)
        .resizable()
        .scaledToFill()
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text("Foto")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
}

                    VStack(alignment: .leading, spacing: 6) {
                        Text(spot.title)
                            .font(.headline.weight(.bold))

                        if !spot.note.isEmpty {
                            Text(spot.note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            startInAppNavigation()
                        } label: {
                            Label("Navigeer", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            openInAppleMaps()
                        } label: {
                            Label("Maps", systemImage: "map")
                        }
                        .buttonStyle(.bordered)

                        if isShareEnabled, !spot.id.recordName.hasPrefix("local-") {
                            ShareLink(item: deepLinkURL) {
                                Image(systemName: "square.and.arrow.up")
                                    .accessibilityLabel("Deel")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.small)

                    Divider().opacity(0.6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Coördinaten")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(spot.latitude, format: .number.precision(.fractionLength(6))), \(spot.longitude, format: .number.precision(.fractionLength(6)))")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sluit") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Verwijder", systemImage: "trash")
                    }
                }
            }
            .alert("Spot verwijderen?", isPresented: $confirmDelete) {
                Button("Verwijder", role: .destructive) {
                    Task {
                        await repo.deleteSpot(spot)
                        dismiss()
                    }
                }
                Button("Annuleer", role: .cancel) { }
            } message: {
                Text("Dit kan niet ongedaan gemaakt worden.")
            }
        }
    }

    private var deepLinkURL: URL {
        // spotmap://spot/<recordName>
        // recordName is expected to be safe (UUID), but we still avoid force-unwrapping weird cases.
        URL(string: "spotmap://spot/\(spot.id.recordName)") ?? URL(string: "spotmap://")!
    }

    private func openInAppleMaps() {
        let location = CLLocation(latitude: spot.location.coordinate.latitude, longitude: spot.location.coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = spot.title
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func startInAppNavigation() {
        let location = CLLocation(latitude: spot.location.coordinate.latitude, longitude: spot.location.coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = spot.title
        nav.previewNavigation(to: item, name: spot.title)
        // Avoid stacked sheets: close the detail sheet first, then show route preview.
        dismiss()
    }
}
