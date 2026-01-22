import SwiftUI
import MapKit
import UIKit

/// Bottom overlay on the Home map.
///
/// Switches automatically between:
/// - Idle/Search UI
/// - Route preview UI
/// - Navigation (guidance) UI
///
/// This is intentionally minimal to avoid clutter on the Home screen.
struct HomeBottomOverlay: View {
    @EnvironmentObject private var nav: NavigationManager
    @EnvironmentObject private var journeys: JourneyRepository
    @EnvironmentObject private var friends: FriendsStore

    @ObservedObject var repo: SpotRepository
    @ObservedObject private var explore = ExploreStore.shared
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false

    let onOpenSpots: () -> Void
    let onAddSpot: () -> Void
    let onOpenJourneys: () -> Void
    let onOpenDrive: () -> Void
    let onOpenSettings: () -> Void
    let onToggleJourney: () -> Void

    @StateObject private var places = PlaceSearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 10) {
            if nav.isNavigating {
                guidanceUI
            } else if nav.isPreviewing {
                previewUI
            } else {
                searchUI
            }
        }
        .onChange(of: nav.isNavigating) { _, isNav in
            if isNav { isSearchFocused = false }
        }
        .sheet(isPresented: $showingSteps) {
            NavigationStepsSheet()
                .environmentObject(nav)
                .presentationDetents([.medium, .large])
        }

        .sheet(isPresented: $showingHomeMenu) {
    HomeMenuSheet()
        .environmentObject(friends)
        .environmentObject(journeys)
        .presentationDetents([.large])
}
    }

    // MARK: - Search

    private var searchUI: some View {
        VStack(spacing: 8) {
            searchBar

            if isSearchFocused || !places.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if places.isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Zoeken…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                } else if !places.completions.isEmpty {
                    Text("\(places.completions.count) resultaten")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }

                resultsPanel
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Zoek bestemming of spot…", text: $places.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .focused($isSearchFocused)
                .submitLabel(.search)

            if !places.query.isEmpty {
                Button {
                    places.query = ""
                    places.cancelSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isSearchFocused || !places.query.isEmpty {
                Button {
                    cancelSearch()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        

if !isSearchFocused && places.query.isEmpty {
    Button {
        showingHomeMenu = true
    } label: {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
    .buttonStyle(.plain)
}

.padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            // Destinations
            if !places.completions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(places.completions, id: \.self) { c in
                        Button {
                            selectCompletion(c)
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)

                        Divider().opacity(0.25)
                    }
                }
            }

            // Quick actions (only when not typing / no results)
            if places.completions.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        quickAction(title: "Spots", systemImage: "list.bullet", action: onOpenSpots)
                        quickAction(title: "Nieuwe spot", systemImage: "mappin.and.ellipse", action: onAddSpot)
                    }
                    HStack(spacing: 10) {
                        quickAction(title: "Journeys", systemImage: "car", action: onOpenJourneys)
                        quickAction(title: "Drive", systemImage: "steeringwheel", action: onOpenDrive)
                    }
                    HStack(spacing: 10) {
                        quickAction(
                            title: journeys.isRecording ? "Stop rit" : "Start rit",
                            systemImage: journeys.isRecording ? "stop.fill" : "record.circle",
                            action: onToggleJourney
                        )
                        quickAction(title: "Instellingen", systemImage: "gearshape", action: onOpenSettings)
                    }
                }
                .padding(14)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(radius: 10)
    }

    private func quickAction(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            

if !isSearchFocused && places.query.isEmpty {
    Button {
        showingHomeMenu = true
    } label: {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
    .buttonStyle(.plain)
}

.padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private func cancelSearch() {
        places.cancelSearch()
        places.query = ""
        isSearchFocused = false
    }

    private func selectCompletion(_ completion: MKLocalSearchCompletion) {
        Task {
            if let item = await places.resolve(completion) {
                await MainActor.run {
                    isSearchFocused = false
                    nav.previewNavigation(to: item, name: item.name ?? completion.title)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewUI: some View {
        HStack(spacing: 12) {
            SpotCircleButton(systemImage: "chevron.left", accessibilityLabel: "Terug") {
                // Back to search; keep query if you want to refine.
                nav.clearAll()
                isSearchFocused = true
            }

            Button {
                nav.startNavigation()
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Text(primaryPreviewTime)
                            .font(.headline.monospacedDigit().weight(.bold))
                        Text(primaryPreviewDistance)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text(nav.destinationName ?? "Bestemming")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                

if !isSearchFocused && places.query.isEmpty {
    Button {
        showingHomeMenu = true
    } label: {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
    .buttonStyle(.plain)
}

.padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.blue)
                )
            }
            .buttonStyle(.plain)
            .disabled(nav.route == nil || nav.isCalculating)

            SpotCircleButton(systemImage: "xmark", accessibilityLabel: "Annuleer") {
                nav.clearAll()
                cancelSearch()
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(radius: 12)
    }

    private var primaryPreviewDistance: String {
        if let r = nav.route {
            return formatDistance(r.distance)
        }
        return formatDistance(nav.remainingDistanceMeters)
    }

    private var primaryPreviewTime: String {
        if let r = nav.route {
            return formatDuration(r.expectedTravelTime)
        }
        return formatDuration(nav.remainingTimeSeconds)
    }

    // MARK: - Guidance

    private var guidanceUI: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(nav.instruction.isEmpty ? (nav.destinationName ?? "Route") : nav.instruction)
                    .font(.system(size: 16, weight: .bold))
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
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10)))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryGuidanceDistance)
                        .font(.headline.monospacedDigit().weight(.bold))
                    Text(primaryGuidanceTime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if nav.offRouteMeters > 0 {
                    Text("\(Int(nav.offRouteMeters)) m off-route")
                        .font(.caption.weight(.semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.thinMaterial, in: Capsule())
                }

                SpotCircleButton(systemImage: "list.bullet", accessibilityLabel: "Stappen") {
                    showingSteps = true
                }

                SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "Recenter") {
                    nav.requestRecenter()
                }

                Button(role: .destructive) {
                    nav.clearAll()
                } label: {
                    Text("Stop")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 54, height: 36)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.10)))
            .shadow(radius: 12)
        }
    }

    private var primaryGuidanceDistance: String {
        if nav.remainingDistanceMeters > 0 { return formatDistance(nav.remainingDistanceMeters) }
        if let r = nav.route { return formatDistance(r.distance) }
        return "—"
    }

    private var primaryGuidanceTime: String {
        if nav.remainingTimeSeconds > 0 { return formatDuration(nav.remainingTimeSeconds) }
        if let r = nav.route { return formatDuration(r.expectedTravelTime) }
        return "—"
    }
}


// MARK: - Home menu sheet

struct HomeMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var journeys: JourneyRepository
    @ObservedObject private var explore = ExploreStore.shared
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false

    @State private var addFriendCode: String = ""
    @State private var showingAddFriend = false

    var body: some View {
        NavigationStack {
            List {
                Section("Vrienden") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Jouw code")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(friends.myCode())
                                .font(.title3.weight(.semibold))
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = friends.myCode()
                        } label: {
                            Label("Kopieer", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        showingAddFriend = true
                    } label: {
                        Label("Vriend toevoegen", systemImage: "person.badge.plus")
                    }

                    if let err = friends.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if friends.friends.isEmpty {
                        Text("Nog geen vrienden. Voeg een code toe.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(friends.friends) { f in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.displayName)
                                    Text(f.code)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let date = f.updatedAt {
                                    Text(date, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    friends.unfollow(code: f.code)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("Progress") {
                    let totalKm = explore.totalDistanceKm(from: journeys.journeys)
                    let lvl = explore.level(for: totalKm)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Level \(lvl)")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%.1f km", totalKm))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: explore.progressToNextLevel(for: totalKm))
                        Text("\(explore.visitedTiles.count) kaart-tegels vrijgespeeld • \(explore.visitedCities.count) steden/dorpen ontdekt")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)

                    Toggle("Explore-modus op kaart", isOn: $exploreEnabled)
                }

                Section("Steden per land") {
                    let dict = explore.citiesByCountry()
                    if dict.isEmpty {
                        Text("Nog geen steden/dorpen gelogd. Maak een journey om te beginnen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dict.keys.sorted(), id: \.self) { k in
                            HStack {
                                Text(k)
                                Spacer()
                                Text("\(dict[k] ?? 0)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Menu")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await friends.refreshFriends()
                            await friends.publish()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .alert("Vriend toevoegen", isPresented: $showingAddFriend) {
                TextField("Friend code", text: $addFriendCode)
                Button("Toevoegen") {
                    friends.follow(code: addFriendCode)
                    addFriendCode = ""
                }
                Button("Cancel", role: .cancel) { addFriendCode = "" }
            } message: {
                Text("Vraag je vriend om zijn/haar code en plak hem hier.")
            }
        }
    }
}
