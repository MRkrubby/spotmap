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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @ObservedObject var repo: SpotRepository
    @ObservedObject private var explore = ExploreStore.shared
    @ObservedObject private var fog = FogOfWarStore.shared
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false

    let onOpenSpots: () -> Void
    let onAddSpot: () -> Void
    let onOpenJourneys: () -> Void
    let onOpenSettings: () -> Void
    let onToggleTracking: () -> Void

    @StateObject private var places = PlaceSearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @State private var showingSteps = false
    @State private var showingHomeMenu = false

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var overlaySpacing: CGFloat {
        isCompactHeight ? 6 : 10
    }

    private var cardPadding: CGFloat {
        isCompactHeight ? 10 : 12
    }

    private var horizontalInset: CGFloat {
        if isCompactHeight { return 10 }
        return isRegularWidth ? 18 : 14
    }

    var body: some View {
        VStack(spacing: overlaySpacing) {
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
        VStack(spacing: SpotDesign.Spacing.md) {
            searchBar

            if isSearchFocused || !places.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if places.isSearching {
                    HStack(spacing: SpotDesign.Spacing.lg) {
                        ProgressView()
                        Text("home.searching")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, SpotDesign.Spacing.sm)
                } else if !places.completions.isEmpty {
                    Text("home.search_results_count \(places.completions.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SpotDesign.Spacing.sm)
                }

                resultsPanel
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: SpotDesign.Spacing.lg) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("home.search_placeholder", text: $places.query)
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
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
                .accessibilityLabel("Wis zoekopdracht")
                .accessibilityAddTraits(.isButton)
            }

            if isSearchFocused || !places.query.isEmpty {
                Button {
                    cancelSearch()
                } label: {
                    Text("home.cancel")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            if !isSearchFocused && places.query.isEmpty {
                Button {
                    showingHomeMenu = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
                .accessibilityLabel("Open menu")
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.vertical, isCompactHeight ? 8 : 12)
        .padding(.horizontal, horizontalInset)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }

    private var resultsPanel: some View {
        VStack(spacing: SpotDesign.Spacing.none) {
            // Destinations
            if !places.completions.isEmpty {
                VStack(alignment: .leading, spacing: SpotDesign.Spacing.md) {
                    ForEach(places.completions, id: \.self) { c in
                        Button {
                            selectCompletion(c)
                        } label: {
                            VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxs) {
                                Text(c.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                if !c.subtitle.isEmpty {
                                    Text(c.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, SpotDesign.Spacing.lg)
                            .padding(.horizontal, SpotDesign.Spacing.xxl)
                        }
                        .buttonStyle(.plain)

                        Divider().opacity(0.25)
                    }
                }
            }

            // Quick actions (only when not typing / no results)
            if places.completions.isEmpty {
                VStack(spacing: SpotDesign.Spacing.lg) {
                    HStack(spacing: SpotDesign.Spacing.lg) {
                        quickAction(title: "Spots", systemImage: "list.bullet", action: onOpenSpots)
                        quickAction(title: "Nieuwe spot", systemImage: "mappin.and.ellipse", action: onAddSpot)
                    }
                    HStack(spacing: SpotDesign.Spacing.lg) {
                        quickAction(title: "Journeys", systemImage: "car", action: onOpenJourneys)
                        quickAction(title: "Instellingen", systemImage: "gearshape", action: onOpenSettings)
                    }
                    HStack(spacing: SpotDesign.Spacing.lg) {
                        quickAction(
                            title: journeys.trackingEnabled ? "home.tracking_on" : "home.tracking_off",
                            systemImage: journeys.trackingEnabled ? "location.fill" : "location.slash",
                            action: onToggleTracking
                        )
                        quickAction(title: exploreEnabled ? "home.explore_on" : "home.explore_off", systemImage: "cloud.fill", action: {
                            exploreEnabled.toggle()
                        })
                    }
                }
                .padding(isCompactHeight ? 10 : 14)
            }
        }
        .background(SpotDesign.Elevation.controlMaterial, in: RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.panel, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowPanel)
    }

    private func quickAction(title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SpotDesign.Spacing.lg) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.vertical, isCompactHeight ? 8 : 12)
            .padding(.horizontal, horizontalInset)
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
        HStack(spacing: SpotDesign.Spacing.xl) {
            SpotCircleButton(systemImage: "chevron.left", accessibilityLabel: "Terug") {
                // Back to search; keep query if you want to refine.
                nav.clearAll()
                isSearchFocused = true
            }

            Button {
                nav.startNavigation()
            } label: {
                VStack(spacing: SpotDesign.Spacing.xxs) {
                    HStack(spacing: SpotDesign.Spacing.md) {
                        Text(primaryPreviewTime)
                            .font(.headline.monospacedDigit().weight(.bold))
                        Text(primaryPreviewDistance)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text(nav.destinationName ?? String(localized: "home.destination_fallback"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SpotDesign.Spacing.xl)
                .padding(.horizontal, SpotDesign.Spacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.panel, style: .continuous)
                        .fill(Color.blue)
                )
            }
            .buttonStyle(.plain)
            .disabled(nav.route == nil || nav.isCalculating)

            SpotCircleButton(systemImage: "xmark", accessibilityLabel: "home.cancel") {
                nav.clearAll()
                cancelSearch()
            }
        }
        .padding(cardPadding)
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
        VStack(spacing: overlaySpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(nav.instruction.isEmpty ? (nav.destinationName ?? "Route") : nav.instruction)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                if nav.distanceToNextManeuverMeters > 0 {
                    Text("home.over_distance \(formatDistance(nav.distanceToNextManeuverMeters))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(cardPadding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10)))

            HStack(spacing: SpotDesign.Spacing.lg) {
                VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxs) {
                    Text(primaryGuidanceDistance)
                        .font(.headline.monospacedDigit().weight(.bold))
                    Text(primaryGuidanceTime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if nav.offRouteMeters > 0 {
                    Text("home.off_route_distance \(Int(nav.offRouteMeters))")
                        .font(.caption.weight(.semibold))
                        .padding(.vertical, SpotDesign.Spacing.sm)
                        .padding(.horizontal, SpotDesign.Spacing.lg)
                        .background(SpotDesign.Elevation.controlMaterial, in: Capsule())
                }

                SpotCircleButton(systemImage: "list.bullet", accessibilityLabel: "home.steps") {
                    showingSteps = true
                }

                SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "home.recenter") {
                    nav.requestRecenter()
                }

                Button(role: .destructive) {
                    nav.clearAll()
                } label: {
                    Text("home.stop")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 54, height: 36)
                        .background(SpotDesign.Elevation.surfaceMaterial, in: RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.pill, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.pill, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
                }
                .buttonStyle(.plain)
            }
            .padding(cardPadding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.10)))
            .shadow(radius: 12)
        }
    }

    private var primaryGuidanceDistance: String {
        if nav.remainingDistanceMeters > 0 { return formatDistance(nav.remainingDistanceMeters) }
        if let r = nav.route { return formatDistance(r.distance) }
        return String(localized: "home.placeholder_dash")
    }

    private var primaryGuidanceTime: String {
        if nav.remainingTimeSeconds > 0 { return formatDuration(nav.remainingTimeSeconds) }
        if let r = nav.route { return formatDuration(r.expectedTravelTime) }
        return String(localized: "home.placeholder_dash")
    }
}


// MARK: - Home menu sheet

struct HomeMenuSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var journeys: JourneyRepository
    @ObservedObject private var explore = ExploreStore.shared
    @ObservedObject private var fog = FogOfWarStore.shared
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false

    @State private var addFriendCode: String = ""
    @State private var showingAddFriend = false

    private var trimmedAddFriendCode: String {
        addFriendCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAddFriendCodeValid: Bool {
        FriendsStore.isValidFriendCode(trimmedAddFriendCode)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("home.menu.friends") {
                    HStack {
                        VStack(alignment: .leading, spacing: SpotDesign.Spacing.xs) {
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
                            Label("home.menu.copy", systemImage: "doc.on.doc")
                        }
                    }
                    Text("Tip: je kunt maximaal 2x per dag een nieuwe code genereren. Oude codes werken dan niet meer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        showingAddFriend = true
                    } label: {
                        Label("home.menu.add_friend", systemImage: "person.badge.plus")
                    }

                    if let err = friends.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = friends.lastFriendAddWarning {
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if friends.friends.isEmpty {
                        Text("home.menu.empty_friends")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(friends.friends) { f in
                            HStack {
                                VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxs) {
                                    Text(f.displayName)
                                    Text(f.statusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(f.code)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let totalKm = f.totalDistanceKm {
                                        Text(String(format: "%.0f km", totalKm))
                                            .font(.caption.weight(.semibold))
                                    }
                                    if let level = f.level {
                                        Text("Level \(level)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if let date = f.updatedAt {
                                        Text(date, style: .time)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    friends.unfollow(code: f.code)
                                } label: {
                                    Label("home.menu.delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section("home.menu.progress") {
                    let totalKm = explore.totalDistanceKm(from: journeys.journeys)
                    let lvl = explore.level(for: totalKm)

                    VStack(alignment: .leading, spacing: SpotDesign.Spacing.lg) {
                        HStack {
                            Text("home.menu.level \(lvl)")
                                .font(.headline)
                            Spacer()
                            Text("home.menu.distance_km \(totalKm)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: explore.progressToNextLevel(for: totalKm))
                        Text("home.menu.progress_next_level")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, SpotDesign.Spacing.sm)

                    Toggle("home.menu.explore_on_map", isOn: $exploreEnabled)
                }

                Section("home.menu.cities_by_country") {
                    let dict = explore.citiesByCountry()
                    if dict.isEmpty {
                        Text("home.menu.empty_cities")
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
            .navigationTitle("home.menu.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("home.done") { dismiss() }
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
                    .padding(6)
                    .contentShape(Rectangle())
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Vernieuwen")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .alert("home.menu.add_friend", isPresented: $showingAddFriend) {
                TextField("home.menu.friend_code", text: $addFriendCode)
                Button("home.menu.add") {
                    friends.follow(code: trimmedAddFriendCode)
                    addFriendCode = ""
                }
                .disabled(!isAddFriendCodeValid)
                Button("home.cancel", role: .cancel) { addFriendCode = "" }
            } message: {
                VStack(alignment: .leading, spacing: SpotDesign.Spacing.sm) {
                    Text("Vraag je vriend om zijn/haar code en plak hem hier.")
                    if !trimmedAddFriendCode.isEmpty && !isAddFriendCodeValid {
                        Text("home.menu.friend_code_minimum")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
