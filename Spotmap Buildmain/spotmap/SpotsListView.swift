import SwiftUI
import CoreLocation
import CloudKit

/// Spots list with search + delete.
///
/// - Swipe left to delete.
/// - Also includes an explicit trash button per row (as requested).
struct SpotsListView: View {
    @ObservedObject var repo: SpotRepository
    let referenceLocation: CLLocation?
    let onSelect: (Spot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var pendingDelete: Spot? = nil
    @AppStorage("Spots.sortMode") private var sortModeRaw: String = SpotSortMode.recent.rawValue
    @AppStorage("Spots.sortAscending") private var sortAscending: Bool = false
    @AppStorage("Spots.showDistance") private var showDistance: Bool = true

    var body: some View {
        NavigationStack {
            List {
                if filteredSpots.isEmpty {
                    ContentUnavailableView(
                        "Geen spots gevonden",
                        systemImage: "mappin.slash",
                        description: Text(query.isEmpty ? "Maak een nieuwe spot om te beginnen." : "Pas je zoekterm of filters aan.")
                    )
                }

                ForEach(filteredSpots) { item in
                    Button {
                        onSelect(item.spot)
                        dismiss()
                    } label: {
                        SpotRow(
                            spot: item.spot,
                            distanceText: distanceText(for: item)
                        ) {
                            pendingDelete = item.spot
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingDelete = item.spot
                        } label: {
                            Label("Verwijder", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Spots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sluit") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(repo.backend == .cloudKit ? "Cloud" : "Lokaal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sorteren op", selection: $sortModeRaw) {
                            ForEach(SpotSortMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        Toggle("Oplopend", isOn: $sortAscending)
                        Toggle("Afstand tonen", isOn: $showDistance)
                    } label: {
                        Label("Sorteren", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .searchable(text: $query, prompt: "Zoek spot")
            .alert("Spot verwijderen?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("Verwijder", role: .destructive) {
                    guard let spot = pendingDelete else { return }
                    Task {
                        await repo.deleteSpot(spot)
                        pendingDelete = nil
                    }
                }
                Button("Annuleer", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("Dit kan niet ongedaan gemaakt worden.")
            }
        }
    }

    private var filteredSpots: [SpotListItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSpots = repo.spots.filter { spot in
            guard !q.isEmpty else { return true }
            return spot.title.localizedCaseInsensitiveContains(q) || spot.note.localizedCaseInsensitiveContains(q)
        }

        let config = SpotSortConfiguration(mode: sortMode, isAscending: sortAscending)
        let sorted = config.sorted(spots: baseSpots, referenceLocation: referenceLocation)
        return sorted.map { SpotListItem(spot: $0, referenceLocation: referenceLocation) }
    }

    private var sortMode: SpotSortMode {
        SpotSortMode(rawValue: sortModeRaw) ?? .recent
    }

    private func distanceText(for item: SpotListItem) -> String? {
        guard showDistance, let distance = item.distance else { return nil }
        return SpotDistanceFormatter.string(for: distance)
    }
}

private struct SpotRow: View {
    let spot: Spot
    let distanceText: String?
    let onTapDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.body.weight(.semibold))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(spot.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let distanceText {
                        Text(distanceText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if !spot.note.isEmpty {
                    Text(spot.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("\(spot.latitude, format: .number.precision(.fractionLength(5))), \(spot.longitude, format: .number.precision(.fractionLength(5)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                onTapDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct SpotListItem: Identifiable {
    let spot: Spot
    let distance: CLLocationDistance?

    var id: CKRecord.ID { spot.id }

    init(spot: Spot, referenceLocation: CLLocation?) {
        self.spot = spot
        if let referenceLocation {
            self.distance = spot.location.distance(from: referenceLocation)
        } else {
            self.distance = nil
        }
    }
}
