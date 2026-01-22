import SwiftUI

/// Spots list with search + delete.
///
/// - Swipe left to delete.
/// - Also includes an explicit trash button per row (as requested).
struct SpotsListView: View {
    @ObservedObject var repo: SpotRepository
    let onSelect: (Spot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var pendingDelete: Spot? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSpots) { spot in
                    Button {
                        onSelect(spot)
                        dismiss()
                    } label: {
                        SpotRow(spot: spot) {
                            pendingDelete = spot
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            pendingDelete = spot
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

    private var filteredSpots: [Spot] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return repo.spots }
        return repo.spots.filter { spot in
            spot.title.localizedCaseInsensitiveContains(q) || spot.note.localizedCaseInsensitiveContains(q)
        }
    }
}

private struct SpotRow: View {
    let spot: Spot
    let onTapDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.body.weight(.semibold))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(spot.title)
                    .font(.headline)
                    .lineLimit(1)

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
