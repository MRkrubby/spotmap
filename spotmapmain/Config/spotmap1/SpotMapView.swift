import SwiftUI
import MapKit
import UIKit
import Combine
import CloudKit

/// Home map screen (clean, state-driven).
///
/// UX rules:
/// - Home = kaart + rustige zoekbalk
/// - Zoeken = search + resultaten
/// - Preview = route-overzicht met 1 primaire actie (Start)
/// - Navigeren = minimale HUD
struct SpotMapView: View {
    @EnvironmentObject private var journeys: JourneyRepository
    @EnvironmentObject private var nav: NavigationManager
    @EnvironmentObject private var friends: FriendsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var vm: SpotMapViewModel
    @StateObject private var mapCoordinator = SpotMapCoordinator(fog: FogOfWarStore.shared)
    
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false
    @State private var locationPublishDebouncer = Debouncer()
    @State private var liveJourneyPublishDebouncer = Debouncer()
    
    @State private var selection: String? = nil
    @State private var autoStartNavigationTask: Task<Void, Never>? = nil

    // Sheets
    @State private var showingSpotsList = false
    @State private var showingSettings = false
    @State private var showingJourneysSheet = false
    @State private var showingAchievements = false
    
    init() {
        let repo = SpotRepository()
        _vm = StateObject(wrappedValue: SpotMapViewModel(repo: repo))
    }

    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var headerHorizontalPadding: CGFloat {
        if isCompactHeight { return 8 }
        return isRegularWidth ? 20 : 12
    }

    private var headerTopPadding: CGFloat {
        isCompactHeight ? 4 : 10
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                SpotMapMapLayer(
                    vm: vm,
                    exploreEnabled: $exploreEnabled,
                    selection: $selection,
                    coordinator: mapCoordinator,
                    fogCloudField: mapCoordinator.fogCloudField
                )
                
                // Minimal header (hide during navigation).
                VStack(spacing: 10) {
                    if !nav.isNavigating {
                        SpotMapHeader(
                            vm: vm,
                            exploreEnabled: $exploreEnabled,
                            onOpenSpots: { showingSpotsList = true },
                            onAddSpot: { vm.showingAdd = true },
                            onOpenJourneys: { showingJourneysSheet = true },
                            onOpenAchievements: { showingAchievements = true },
                            onToggleTracking: { journeys.toggle() },
                            onRefresh: {
                                let c = vm.mapCenter
                                vm.repo.refreshNearby(center: CLLocation(latitude: c.latitude, longitude: c.longitude), force: true)
                            },
                            onOpenSettings: { showingSettings = true },
                            onFocusUser: { vm.focusOnUser() }
                        )
                            .padding(.top, headerTopPadding)
                            .padding(.horizontal, headerHorizontalPadding)
                        
                        if vm.repo.isLoading {
                            SpotLoadingPill(text: vm.repo.spots.isEmpty ? "Laden…" : "Bijwerken…")
                                .padding(.horizontal, headerHorizontalPadding)
                        }
                        
                        if journeys.isRecording {
                            SpotLoadingPill(
                                text: "spotmap.recording_status \(JourneyFormat.km(journeys.currentDistanceMeters)) \(JourneyFormat.speedKmh(journeys.currentSpeedMps))"
                            )
                            .padding(.horizontal, headerHorizontalPadding)
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            
            // Bottom overlay that switches between:
            // - search
            // - route preview
            // - navigation HUD
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if isCompactHeight { Spacer() }
                    SpotMapOverlays(
                        vm: vm,
                        onOpenSpots: { showingSpotsList = true },
                        onAddSpot: { vm.showingAdd = true },
                        onOpenJourneys: { showingJourneysSheet = true },
                        onOpenSettings: { showingSettings = true },
                        onToggleTracking: { journeys.toggle() }
                    )
                    .frame(maxWidth: isCompactHeight && !isRegularWidth ? 420 : .infinity, alignment: .trailing)
                }
                .padding(.horizontal, isCompactHeight ? 12 : 0)
            }
            
            // Errors
            .alert(
                "spotmap.alert_title",
                isPresented: Binding(
                    get: { vm.repo.lastErrorMessage != nil },
                    set: { newValue in
                        if !newValue { vm.repo.lastErrorMessage = nil }
                    }
                ),
                actions: {
                    Button("spotmap.ok", role: .cancel) { vm.repo.lastErrorMessage = nil }
                },
                message: {
                    Text(vm.repo.lastErrorMessage ?? "")
                }
            )
            .spotMapSheetPresenter(
                vm: vm,
                showingSpotsList: $showingSpotsList,
                showingSettings: $showingSettings,
                showingJourneysSheet: $showingJourneysSheet,
                showingAchievements: $showingAchievements,
                selection: $selection
            )

            .onReceive(vm.locationManager.$lastLocation.compactMap { $0 }) { loc in
                // Fog-of-war reveal (20m buffer) while Explore mode is enabled.
                if exploreEnabled {
                    FogOfWarStore.shared.reveal(location: loc)
                }
                
                // Friends publish is handled by RootTabView lifecycle,
                // but we still update the in-memory location here.
                friends.updateMyLocation(loc)
                locationPublishDebouncer.schedule(delay: .seconds(3)) {
                    Task { await friends.publish() }
                }
            }
            .onChange(of: exploreEnabled) { _, newValue in
                // When Explore is on, request higher accuracy so the 20m buffer feels right.
                vm.locationManager.setHighAccuracy(newValue)
            }
            .onChange(of: journeys.journeys) { _, newValue in
                friends.updateMyLastJourney(newValue.first)
                let totalKm = ExploreStore.shared.totalDistanceKm(from: newValue)
                let level = ExploreStore.shared.level(for: totalKm)
                friends.updateMyStats(
                    totalDistanceKm: totalKm,
                    level: level,
                    visitedCitiesCount: ExploreStore.shared.visitedCities.count,
                    visitedTilesCount: ExploreStore.shared.visitedTiles.count
                )
                locationPublishDebouncer.schedule(delay: .seconds(2)) {
                    Task { await friends.publish() }
                }
            }
            .onChange(of: journeys.currentSpeedMps) { _, _ in
                guard journeys.isRecording else { return }
                let points = journeys.liveShareJourneyPoints()
                friends.updateMyLiveJourney(points: points, speedMps: journeys.currentSpeedMps)
                liveJourneyPublishDebouncer.schedule(delay: .seconds(3)) {
                    Task { await friends.publish() }
                }
            }
            .onChange(of: journeys.isRecording) { _, isRecording in
                if !isRecording {
                    friends.clearLiveJourney()
                    liveJourneyPublishDebouncer.schedule(delay: .seconds(2)) {
                        Task { await friends.publish() }
                    }
                }
            }
            .onAppear {
                // RootTabView manages friends auto-refresh/publish lifecycle.
                vm.onAppear()
                vm.locationManager.setHighAccuracy(exploreEnabled)
                if exploreEnabled, let loc = vm.locationManager.lastLocation {
                    FogOfWarStore.shared.reveal(location: loc, minMoveMeters: 0)
                }
            }
            .onDisappear {
                cancelAutoStartNavigationTask()
            }
            .onChange(of: nav.isPreviewing) { _, _ in
                cancelAutoStartNavigationTaskIfNavigationCleared()
            }
            .onChange(of: nav.isNavigating) { _, _ in
                cancelAutoStartNavigationTaskIfNavigationCleared()
            }
            .onChange(of: nav.recenterToken) { _, _ in
                vm.focusOnUser()
            }
            .onOpenURL { url in
                self.handleDeepLink(url)
            }
        }
    }

    // MARK: - Deep links
    
    private func handleDeepLink(_ url: URL) {
        guard let deepLink = DeepLink(url: url) else { return }

        switch deepLink {
        case .home:
            break
        case .spot:
            vm.handleDeepLink(url)
        case .navigateSpot(let recordName):
            cancelAutoStartNavigationTask()
            autoStartNavigationTask = Task {
                if let spot = await vm.repo.fetchSpotIfNeeded(recordName: recordName) {
                    let coord = spot.location.coordinate
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
                    item.name = spot.title

                    await MainActor.run {
                        nav.previewNavigation(to: item, name: spot.title)
                    }

                    // Auto-start once the route is ready (CarPlay use-case)
                    for _ in 0..<30 {
                        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                        let ready = await MainActor.run { !nav.isCalculating && nav.route != nil }
                        let stillPreviewing = await MainActor.run { nav.isPreviewing }
                        guard stillPreviewing else { break }
                        if ready {
                            await MainActor.run { nav.startNavigation() }
                            break
                        }
                    }
                }
            }
        case .journeys:
            showingJourneysSheet = true
        case .journeyToggle:
            journeys.toggle()
        }
    }

    private func cancelAutoStartNavigationTask() {
        autoStartNavigationTask?.cancel()
        autoStartNavigationTask = nil
    }

    private func cancelAutoStartNavigationTaskIfNavigationCleared() {
        if !nav.isPreviewing && !nav.isNavigating {
            cancelAutoStartNavigationTask()
        }
    }
    
    
    // MARK: - Achievements
    
    /// Dedicated achievements/progress screen.
    /// This is intentionally calm + minimal (no clutter), and includes a single
    /// toggle to show/hide the Achievement map layer.
    struct AchievementsView: View {
        @EnvironmentObject private var journeys: JourneyRepository
        @EnvironmentObject private var friends: FriendsStore
        @ObservedObject private var explore = ExploreStore.shared
        @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false
        @Environment(\.dismiss) private var dismiss
        
        private var totalKm: Double { explore.totalDistanceKm(from: journeys.journeys) }
        private var level: Int { explore.level(for: totalKm) }
        private var progress: Double { explore.progressToNextLevel(for: totalKm) }
        private var badges: [AchievementBadge] {
            AchievementsCatalog.badges(
                totalKm: totalKm,
                visitedCities: explore.visitedCities.count,
                visitedTiles: explore.visitedTiles.count,
                journeys: journeys.journeys
            )
        }
        private var facts: [ExploreFact] {
            AchievementsCatalog.facts(
                totalKm: totalKm,
                visitedCities: explore.visitedCities.count,
                visitedTiles: explore.visitedTiles.count,
                journeys: journeys.journeys
            )
        }
        
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Level card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("spotmap.achievements.level \(level)")
                                        .font(.title2.bold())
                                    Text("spotmap.achievements.total_driven")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("spotmap.achievements.distance_km \(totalKm)")
                                    .font(.headline)
                            }
                            
                            ProgressView(value: progress)
                                .tint(.blue)
                            
                            let next = Double(level) * 100.0
                            Text("spotmap.achievements.next_level_distance \(max(0.0, next - totalKm)) \(level + 1)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        // Badges
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Badges")
                                .font(.headline)

                            ForEach(badges) { badge in
                                HStack(spacing: 12) {
                                    Image(systemName: badge.systemImage)
                                        .font(.system(size: 18, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .background(badge.isUnlocked ? Color.green.opacity(0.18) : Color.gray.opacity(0.15))
                                        .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(badge.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(badge.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if badge.isUnlocked {
                                        Text("Unlocked")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("\(Int(badge.progress * 100))%")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                ProgressView(value: badge.progress)
                                    .tint(badge.isUnlocked ? .green : .blue)
                            }
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        
                        // Map layer toggle
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "square.3.layers.3d")
                                Text("spotmap.achievements.map_layer")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: $exploreEnabled)
                                    .labelsHidden()
                            }
                            Text("spotmap.achievements.map_layer_help")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        // Friends leaderboard
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Vrienden competitie")
                                .font(.headline)
                            if friends.friends.isEmpty {
                                Text("Voeg vrienden toe om te vergelijken.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                let ranked = friends.friends.sorted { ($0.totalDistanceKm ?? 0) > ($1.totalDistanceKm ?? 0) }
                                ForEach(ranked.prefix(5)) { friend in
                                    HStack {
                                        Text(friend.displayName)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(String(format: "%.0f km", friend.totalDistanceKm ?? 0))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Divider().opacity(0.25)
                                }
                            }
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        
                        // Stats
                        VStack(alignment: .leading, spacing: 10) {
                            Text("spotmap.achievements.progress")
                                .font(.headline)
                            
                            HStack {
                                StatPill(title: "spotmap.achievements.tiles", value: "\(explore.visitedTiles.count)", systemImage: "square.grid.3x3")
                                StatPill(title: "spotmap.achievements.cities", value: "\(explore.visitedCities.count)", systemImage: "building.2")
                            }
                            
                            Text("spotmap.achievements.progress_help")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        
                        // Countries
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("spotmap.achievements.cities_by_country")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            let dict = explore.citiesByCountry()
                            if dict.isEmpty {
                                Text("spotmap.achievements.empty_cities")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(dict.keys.sorted(), id: \.self) { k in
                                        HStack {
                                            Text(k)
                                            Spacer()
                                            Text("\(dict[k] ?? 0)")
                                                .foregroundStyle(.secondary)
                                        }
                                        .font(.subheadline)
                                        Divider().opacity(0.25)
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        // Facts
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Stats & feiten")
                                .font(.headline)
                            ForEach(facts) { fact in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(fact.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(fact.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(fact.value)
                                        .font(.subheadline.weight(.semibold))
                                }
                                Divider().opacity(0.25)
                            }
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .navigationTitle("spotmap.achievements.title")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("spotmap.done") { dismiss() }
                    }
                }
            }
        }
    }
    
private struct StatPill: View {
        let title: LocalizedStringKey
        let value: String
        let systemImage: String
        @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 16
        
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

}

// MARK: - Subviews

private struct SpotMapHeader: View {
    @EnvironmentObject private var journeys: JourneyRepository
    @ObservedObject var vm: SpotMapViewModel
    @Binding var exploreEnabled: Bool
    let onOpenSpots: () -> Void
    let onAddSpot: () -> Void
    let onOpenJourneys: () -> Void
    let onOpenAchievements: () -> Void
    let onToggleTracking: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onFocusUser: () -> Void
    @ScaledMetric(relativeTo: .body) private var menuIconSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("SpotMap")
                        .font(.headline.weight(.bold))
                    Text(vm.repo.backend.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "spotmap.location_accessibility") {
                onFocusUser()
            }

            // Quick toggle: Achievement map layer (Explore)
            SpotCircleButton(
                systemImage: exploreEnabled ? "square.3.layers.3d.down.right" : "square.3.layers.3d",
                accessibilityLabel: "spotmap.achievements.map_layer_accessibility"
            ) {
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
                withAnimation(.easeInOut(duration: 0.18)) {
                    exploreEnabled.toggle()
                }
            }

            Menu {
                Button(action: onOpenSpots) {
                    Label("spotmap.action_spots", systemImage: "list.bullet")
                }

                Button(action: onAddSpot) {
                    Label("spotmap.action_new_spot", systemImage: "mappin.and.ellipse")
                }

                Button(action: onOpenJourneys) {
                    Label("spotmap.action_journeys", systemImage: "car")
                }

                Button(action: onOpenAchievements) {
                    Label("spotmap.action_achievements", systemImage: "trophy")
                }

                Button(action: onToggleTracking) {
                    Label(
                        journeys.trackingEnabled ? "spotmap.tracking_off" : "spotmap.tracking_on",
                        systemImage: journeys.trackingEnabled ? "location.slash" : "location.fill"
                    )
                }

                Divider()

                Button(action: onRefresh) {
                    Label("spotmap.refresh", systemImage: "arrow.clockwise")
                }

                Button(action: onOpenSettings) {
                    Label("spotmap.settings", systemImage: "gearshape")
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                        .frame(width: SpotBrand.circleButtonSize, height: SpotBrand.circleButtonSize)
                        .shadow(radius: 6)
                    Image(systemName: "ellipsis")
                        .font(.system(size: menuIconSize, weight: .semibold))
                }
            }
            .accessibilityLabel(Text("spotmap.menu_accessibility"))
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8)
    }
}

private struct SpotMapOverlays: View {
    @EnvironmentObject private var nav: NavigationManager
    @EnvironmentObject private var journeys: JourneyRepository
    @ObservedObject var vm: SpotMapViewModel
    let onOpenSpots: () -> Void
    let onAddSpot: () -> Void
    let onOpenJourneys: () -> Void
    let onOpenSettings: () -> Void
    let onToggleTracking: () -> Void

    var body: some View {
        HomeBottomOverlay(
            repo: vm.repo,
            onOpenSpots: onOpenSpots,
            onAddSpot: onAddSpot,
            onOpenJourneys: onOpenJourneys,
            onOpenSettings: onOpenSettings,
            onToggleTracking: onToggleTracking
        )
        .environmentObject(nav)
        .environmentObject(journeys)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private struct SpotMapMapLayer: View {
    @EnvironmentObject private var nav: NavigationManager
    @EnvironmentObject private var friends: FriendsStore
    @EnvironmentObject private var journeys: JourneyRepository
    @ObservedObject var vm: SpotMapViewModel
    @Binding var exploreEnabled: Bool
    @Binding var selection: String?
    @ObservedObject var coordinator: SpotMapCoordinator
    @ObservedObject var fogCloudField: FogCloudField
    @AppStorage("UserLocation.style") private var userLocationStyleRaw: String = UserLocationStyle.system.rawValue
    @AppStorage("UserLocation.assetId") private var userLocationAssetId: String = "suv"

    var body: some View {
        let style = UserLocationStyle.from(rawValue: userLocationStyleRaw)
        let asset = VehicleAssetsCatalog.shared.asset(for: userLocationAssetId)
        MapReader { proxy in
            GeometryReader { geo in
                ZStack {
                    Map(position: $vm.mapPosition, selection: $selection) {
                        // Your tracked path since app start.
                        let session = journeys.sessionPolyline()
                        if session.count >= 2 {
                            MapPolyline(MKPolyline(coordinates: session, count: session.count))
                                .stroke(.blue.opacity(0.25), lineWidth: 7)
                        }

                        if let r = nav.route {
                            MapPolyline(r.polyline)
                                .stroke(.blue, lineWidth: 8)
                        }

                        MapPolyline(RailNetwork.linePolyline)
                            .stroke(.red.opacity(0.7), lineWidth: 4)

                        ForEach(RailNetwork.nodes) { node in
                            Marker(node.name, coordinate: node.coordinate)
                        }

                        // Friends (optional)
                        ForEach(friends.friends) { f in
                            if let c = f.coordinate {
                                Marker(f.mapLabel, coordinate: c)
                            }
                            if let data = friends.liveJourneyZlib(for: f),
                               let poly = FriendRouteDecoder.polyline(fromZlib: data) {
                                MapPolyline(poly)
                                    .stroke(.green.opacity(0.6), lineWidth: 4)
                            } else if let data = f.lastJourneyZlib,
                                      let poly = FriendRouteDecoder.polyline(fromZlib: data) {
                                MapPolyline(poly)
                                    .stroke(.blue.opacity(0.35), lineWidth: 4)
                            }
                        }

                        // NOTE: clouds/trees are drawn as a lightweight overlay (NOT Map annotations)
                        // to keep taps and scrolling responsive.

                        if let dest = nav.destination?.placemark.coordinate {
                            Marker(nav.destinationName ?? String(localized: "spotmap.destination_fallback"), coordinate: dest)
                        }

                        ForEach(vm.repo.spots) { spot in
                            Marker(spot.title, coordinate: spot.location.coordinate)
                                .tag(spot.id.recordName)
                        }

                        UserAnnotation {
                            UserLocationMarkerView(style: style, asset: asset)
                        }
                    }
                    .mapStyle(exploreEnabled ? .standard(elevation: .flat) : .standard)
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                        MapUserLocationButton()
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        coordinator.handleCameraChange(
                            context: context,
                            exploreEnabled: exploreEnabled,
                            proxy: proxy,
                            canvasSize: geo.size
                        ) { center in
                            vm.mapCenterChanged(to: center)
                        }
                    }
                    .onChange(of: selection) { _, newValue in
                        coordinator.handleSelectionChange(recordName: newValue) { recordName in
                            if let spot = vm.repo.spot(withRecordName: recordName) {
                                vm.selectedSpot = spot
                            }
                        }
                    }
                    .onAppear {
                        coordinator.handleMapAppear(
                            exploreEnabled: exploreEnabled,
                            proxy: proxy,
                            canvasSize: geo.size,
                            centerCoordinate: vm.mapCenter
                        )
                    }
                    .onChange(of: exploreEnabled) { _, newValue in
                        coordinator.handleExploreChange(
                            exploreEnabled: newValue,
                            proxy: proxy,
                            canvasSize: geo.size,
                            centerCoordinate: vm.mapCenter
                        )
                    }
                }

                // TRUE 3D clouds overlay.
                // Only render when Explore is enabled.
                if exploreEnabled {
                    // Convert cloud world coordinates into deterministic map points.
                    // The SceneKit overlay projects those world positions into view space using
                    // the current center + meters-per-point so camera motion doesn't re-seed
                    // or re-place clouds (only LOD/visibility changes with viewport).
                    let items: [CloudVoxelItem] = fogCloudField.clouds.map { cloud in
                        CloudVoxelItem(
                            id: cloud.id,
                            coordinate: cloud.coordinate,
                            sizeMeters: cloud.sizeMeters,
                            altitudeMeters: cloud.altitudeMeters,
                            asset: cloud.asset,
                            seed: cloud.seed
                        )
                    }

                    CloudVoxelOverlayView(
                        items: items,
                        viewportSize: geo.size,
                        centerCoordinate: fogCloudField.centerCoordinateNow,
                        metersPerPoint: fogCloudField.metersPerPointNow
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct SpotMapSheetPresenter: ViewModifier {
    @EnvironmentObject private var journeys: JourneyRepository
    @EnvironmentObject private var nav: NavigationManager
    @ObservedObject var vm: SpotMapViewModel
    @Binding var showingSpotsList: Bool
    @Binding var showingSettings: Bool
    @Binding var showingJourneysSheet: Bool
    @Binding var showingAchievements: Bool
    @Binding var selection: String?

    func body(content: Content) -> some View {
        content
            // Spot detail
            .sheet(item: $vm.selectedSpot, onDismiss: { selection = nil }) { spot in
                SpotDetailView(spot: spot, isShareEnabled: vm.repo.backend == .cloudKit)
                    .environmentObject(vm.repo)
                    .environmentObject(nav)
                    .presentationDetents([.medium, .large])
            }

            // Add spot
            .sheet(isPresented: $vm.showingAdd) {
                AddSpotView(
                    initialCoordinate: vm.mapCenter,
                    onAdd: { title, note, coord, photoData in
                        Task { await vm.repo.addSpot(title: title, note: note, coordinate: coord, photoData: photoData) }
                    }
                )
                .presentationDetents([.medium, .large])
            }

            // Spots list
            .sheet(isPresented: $showingSpotsList) {
                SpotsListView(repo: vm.repo, referenceLocation: vm.locationManager.lastLocation) { spot in
                    vm.selectedSpot = spot
                    vm.focus(on: spot.location.coordinate)
                }
                .presentationDetents([.medium, .large])
            }

            // Settings
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    repo: vm.repo,
                    currentCenter: { vm.mapCenter }
                )
                .presentationDetents([.medium])
            }

            // Journeys
            .sheet(isPresented: $showingJourneysSheet) {
                JourneysView()
                    .environmentObject(journeys)
                    .presentationDetents([.medium, .large])
            }

            // Achievements
            .sheet(isPresented: $showingAchievements) {
                SpotMapView.AchievementsView()
                    .environmentObject(journeys)
                    .environmentObject(friends)
                    .presentationDetents([.medium, .large])
            }
    }
}

private extension View {
    func spotMapSheetPresenter(
        vm: SpotMapViewModel,
        showingSpotsList: Binding<Bool>,
        showingSettings: Binding<Bool>,
        showingJourneysSheet: Binding<Bool>,
        showingAchievements: Binding<Bool>,
        selection: Binding<String?>
    ) -> some View {
        modifier(
            SpotMapSheetPresenter(
                vm: vm,
                showingSpotsList: showingSpotsList,
                showingSettings: showingSettings,
                showingJourneysSheet: showingJourneysSheet,
                showingAchievements: showingAchievements,
                selection: selection
            )
        )
    }
}

@MainActor
final class SpotMapCoordinator: ObservableObject {
    private let fog: FogOfWarStore
    private let fogDebouncer = Debouncer()
    let fogCloudField: FogCloudField

    @MainActor
    convenience init(fog: FogOfWarStore) {
        self.init(fog: fog, fogCloudField: FogCloudField())
    }

    @MainActor
    init(fog: FogOfWarStore, fogCloudField: FogCloudField) {
        self.fog = fog
        self.fogCloudField = fogCloudField
    }

    @MainActor
    func handleCameraChange(
        context: MapCameraUpdateContext,
        exploreEnabled: Bool,
        proxy: MapProxy,
        canvasSize: CGSize,
        onCenterChange: (CLLocationCoordinate2D) -> Void
    ) {
        let center = context.region.center
        onCenterChange(center)
        guard exploreEnabled else { return }
        scheduleFogCloudUpdate(proxy: proxy, canvasSize: canvasSize, centerCoordinate: center)
    }

    @MainActor
    func handleSelectionChange(recordName: String?, onSelect: (String) -> Void) {
        guard let recordName else { return }
        onSelect(recordName)
    }

    @MainActor
    func handleMapAppear(
        exploreEnabled: Bool,
        proxy: MapProxy,
        canvasSize: CGSize,
        centerCoordinate: CLLocationCoordinate2D
    ) {
        guard exploreEnabled else { return }
        fogCloudField.start(store: fog)
        scheduleFogCloudUpdate(proxy: proxy, canvasSize: canvasSize, centerCoordinate: centerCoordinate)
        // Ensure we update after first layout (MapProxy.convert can return nil early).
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                scheduleFogCloudUpdate(proxy: proxy, canvasSize: canvasSize, centerCoordinate: centerCoordinate)
            }
        }
    }

    @MainActor
    func handleExploreChange(
        exploreEnabled: Bool,
        proxy: MapProxy,
        canvasSize: CGSize,
        centerCoordinate: CLLocationCoordinate2D
    ) {
        if exploreEnabled {
            fogCloudField.start(store: fog)
            scheduleFogCloudUpdate(proxy: proxy, canvasSize: canvasSize, centerCoordinate: centerCoordinate)
            // Ensure we update after first layout (MapProxy.convert can return nil early).
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                await MainActor.run {
                    scheduleFogCloudUpdate(proxy: proxy, canvasSize: canvasSize, centerCoordinate: centerCoordinate)
                }
            }
        } else {
            fogCloudField.stop()
        }
    }

    @MainActor
    private func scheduleFogCloudUpdate(proxy: MapProxy, canvasSize: CGSize, centerCoordinate: CLLocationCoordinate2D) {
        // Throttle to avoid recomputing clouds too often while GPS updates are flowing.
        fogDebouncer.schedule(delay: .milliseconds(120)) {
            self.fogCloudField.updateViewport(proxy: proxy, canvasSize: canvasSize, centerCoordinate: centerCoordinate)
        }
    }
}
