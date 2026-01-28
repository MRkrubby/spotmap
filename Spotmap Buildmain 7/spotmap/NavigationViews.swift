import SwiftUI
import MapKit
import Combine

// MARK: - Formatting helpers

func formatDistance(_ meters: Double) -> String {
    if meters >= 1000 {
        return String(format: "%.1f km", meters / 1000)
    } else {
        return String(format: "%.0f m", meters)
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    let h = s / 3600
    let m = (s % 3600) / 60
    if h > 0 {
        return "\(h)u \(m)m"
    }
    return "\(m)m"
}

// MARK: - Preview sheet

struct NavigationPreviewSheet: View {
    @EnvironmentObject var nav: NavigationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(.secondary)
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(nav.destinationName ?? "Bestemming")
                    .font(.headline.bold())

                if nav.remainingDistanceMeters > 0 {
                    Text("Afstand: \(formatDistance(nav.remainingDistanceMeters))")
                        .foregroundStyle(.secondary)
                }

                if nav.remainingTimeSeconds > 0 {
                    Text("Geschatte tijd: \(formatDuration(nav.remainingTimeSeconds))")
                        .foregroundStyle(.secondary)
                }

                if nav.route == nil && !nav.isCalculating {
                    Text("Geen route beschikbaar. Controleer je locatie-permissie.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            Group {
                if nav.isCalculating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Route berekenen…")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    nav.cancelPreview()
                    dismiss()
                } label: {
                    Text("Sluit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    nav.startNavigation()
                    dismiss()
                } label: {
                    Text("Start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(nav.route == nil || nav.isCalculating)
            }
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - In-map banner

struct NavigationBannerView: View {
    @EnvironmentObject var nav: NavigationManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: nav.isNavigating ? "location.north.line.fill" : "map")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(nav.instruction.isEmpty ? (nav.destinationName ?? "Route") : nav.instruction)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if nav.remainingDistanceMeters > 0 {
                        Text(formatDistance(nav.remainingDistanceMeters))
                    }
                    if nav.remainingTimeSeconds > 0 {
                        Text("•")
                        Text(formatDuration(nav.remainingTimeSeconds))
                    }
                    if nav.offRouteMeters > 0 {
                        Text("•")
                        Text("\(Int(nav.offRouteMeters)) m van route")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                nav.requestRecenter()
            } label: {
                Image(systemName: "location.fill")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if nav.isNavigating {
                Button(role: .destructive) {
                    nav.stopNavigation()
                } label: {
                    Text("Stop")
                        .frame(width: 54)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 8)
    }
}


// MARK: - Destination search (in-app)

@MainActor
final class PlaceSearchViewModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = ""
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var isSearching: Bool = false

    private let completer = MKLocalSearchCompleter()
    private var activeSearch: MKLocalSearch? = nil
    private var cancellables = Set<AnyCancellable>()
    private let debouncer = Debouncer()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]

        // Debounce query updates so we don't spam MapKit.
        $query
            .removeDuplicates()
            .sink { [weak self] q in
                guard let self else { return }
                self.debouncer.schedule(delay: .milliseconds(250)) {
                    await self.updateCompleter(query: q)
                }
            }
            .store(in: &cancellables)
    }

    func cancelSearch() {
        activeSearch?.cancel()
        activeSearch = nil
        isSearching = false
        completions = []
    }

    private func updateCompleter(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            isSearching = false
            completions = []
            return
        }
        isSearching = true
        completer.queryFragment = q
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        activeSearch?.cancel()
        isSearching = true

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        activeSearch = search

        do {
            let response = try await search.start()
            isSearching = false
            activeSearch = nil
            return response.mapItems.first
        } catch {
            isSearching = false
            activeSearch = nil
            return nil
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Keep it snappy: show top 12 results.
        let res = Array(completer.results.prefix(12))
        Task { @MainActor in
            self.isSearching = false
            self.completions = res
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.isSearching = false
            self.completions = []
        }
    }
}

struct DestinationSearchSheet: View {
    @EnvironmentObject var nav: NavigationManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = PlaceSearchViewModel()
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Zoek bestemming…", text: $vm.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .focused($isFocused)

                    if !vm.query.isEmpty {
                        Button {
                            vm.query = ""
                            vm.cancelSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10)))

                if vm.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Zoeken…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }

                List {
                    ForEach(vm.completions, id: \.self) { c in
                        Button {
                            Task {
                                if let item = await vm.resolve(c) {
                                    nav.previewNavigation(to: item, name: item.name ?? c.title)
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                if !c.subtitle.isEmpty {
                                    Text(c.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .navigationTitle("Navigatie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sluit") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Annuleer zoeken") {
                        vm.cancelSearch()
                        vm.query = ""
                        isFocused = false
                    }
                    .disabled(vm.query.isEmpty && vm.completions.isEmpty)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }
}

// MARK: - HUD + step-by-step

struct NavigationHUDOverlay: View {
    @EnvironmentObject var nav: NavigationManager
    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 12) {
            // Top instruction card
            VStack(alignment: .leading, spacing: 6) {
                Text(nav.instruction.isEmpty ? (nav.destinationName ?? "Route") : nav.instruction)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(2)

                if nav.distanceToNextManeuverMeters > 0 {
                    Text("Over \(formatDistance(nav.distanceToNextManeuverMeters))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))

            Spacer(minLength: 0)

            // Bottom bar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if nav.remainingDistanceMeters > 0 {
                        Text(formatDistance(nav.remainingDistanceMeters))
                            .font(.headline.monospacedDigit())
                    }
                    if nav.remainingTimeSeconds > 0 {
                        Text(formatDuration(nav.remainingTimeSeconds))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if nav.offRouteMeters > 0, nav.isNavigating {
                    Text("\(Int(nav.offRouteMeters)) m van route")
                        .font(.caption.weight(.semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.thinMaterial, in: Capsule())
                }

                Button {
                    nav.requestRecenter()
                } label: {
                    Image(systemName: "location.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showingSteps = true
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    nav.stopNavigation()
                } label: {
                    Text("Stop")
                        .frame(width: 58, height: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
        .padding(12)
        .sheet(isPresented: $showingSteps) {
            NavigationStepsSheet()
                .environmentObject(nav)
                .presentationDetents([.medium, .large])
        }
    }
}

struct NavigationStepsSheet: View {
    @EnvironmentObject var nav: NavigationManager
    @Environment(\.dismiss) private var dismiss

    var steps: [MKRoute.Step] {
        (nav.route?.steps ?? []).filter { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if steps.isEmpty {
                    Text("Geen stappen beschikbaar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.instructions)
                                .font(.headline)
                            if step.distance > 0 {
                                Text(formatDistance(step.distance))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Stappen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sluit") { dismiss() }
                }
            }
        }
    }
}
