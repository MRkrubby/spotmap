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
    @StateObject private var vm: SpotMapViewModel
    
    @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false
    @ObservedObject private var explore = ExploreStore.shared
    private let fog = FogOfWarStore.shared
    @State private var publishDebouncer = Debouncer()
    @State private var fogDebouncer = Debouncer()
    @StateObject private var fogCloudField = FogCloudField()
    
    @State private var selection: String? = nil

    // Sheets
    @State private var showingSpotsList = false
    @State private var showingSettings = false
    @State private var showingJourneysSheet = false
    @State private var showingAchievements = false
    
    init() {
        let repo = SpotRepository()
        _vm = StateObject(wrappedValue: SpotMapViewModel(repo: repo))
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                mapLayer
                
                // Minimal header (hide during navigation).
                VStack(spacing: 10) {
                    if !nav.isNavigating {
                        headerBar
                            .padding(.top, 10)
                            .padding(.horizontal, 12)
                        
                        if vm.repo.isLoading {
                            SpotLoadingPill(text: vm.repo.spots.isEmpty ? "Laden…" : "Bijwerken…")
                                .padding(.horizontal, 12)
                        }
                        
                        if journeys.isRecording {
                            SpotLoadingPill(
                                text: "REC • \(JourneyFormat.km(journeys.currentDistanceMeters)) • \(JourneyFormat.speedKmh(journeys.currentSpeedMps))"
                            )
                            .padding(.horizontal, 12)
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
                HomeBottomOverlay(
                    repo: vm.repo,
                    onOpenSpots: { showingSpotsList = true },
                    onAddSpot: { vm.showingAdd = true },
                    onOpenJourneys: { showingJourneysSheet = true },
                    onOpenSettings: { showingSettings = true },
                    onToggleTracking: { journeys.toggle() }
                )
                .environmentObject(nav)
                .environmentObject(journeys)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            
            // Errors
            .alert(
                "Melding",
                isPresented: Binding(
                    get: { vm.repo.lastErrorMessage != nil },
                    set: { newValue in
                        if !newValue { vm.repo.lastErrorMessage = nil }
                    }
                ),
                actions: {
                    Button("OK", role: .cancel) { vm.repo.lastErrorMessage = nil }
                },
                message: {
                    Text(vm.repo.lastErrorMessage ?? "")
                }
            )
            
            // Spot detail
            .sheet(item: $vm.selectedSpot) { spot in
                SpotDetailView(spot: spot, isShareEnabled: vm.repo.backend == .cloudKit)
                    .environmentObject(vm.repo)
                    .environmentObject(nav)
                    .presentationDetents([.medium, .large])
            }
            
            // Add spot
            .onReceive(vm.locationManager.$lastLocation.compactMap { $0 }) { loc in
                // Fog-of-war reveal (20m buffer) while Explore mode is enabled.
                if exploreEnabled {
                    fog.reveal(location: loc)
                }
                
                // Friends publish is handled by RootTabView lifecycle,
                // but we still update the in-memory location here.
                friends.updateMyLocation(loc)
                publishDebouncer.schedule(delay: .seconds(3)) {
                    Task { await friends.publish() }
                }
            }
            .onChange(of: exploreEnabled) { _, newValue in
                // When Explore is on, request higher accuracy so the 20m buffer feels right.
                vm.locationManager.setHighAccuracy(newValue)
            }
            .onChange(of: journeys.journeys) { _, newValue in
                friends.updateMyLastJourney(newValue.first)
                publishDebouncer.schedule(delay: .seconds(2)) {
                    Task { await friends.publish() }
                }
            }
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
                AchievementsView()
                    .environmentObject(journeys)
                    .presentationDetents([.medium, .large])
            }
            
            .onAppear {
                // RootTabView manages friends auto-refresh/publish lifecycle.
                vm.onAppear()
                vm.locationManager.setHighAccuracy(exploreEnabled)
                if exploreEnabled, let loc = vm.locationManager.lastLocation {
                    fog.reveal(location: loc, minMoveMeters: 0)
                }
            }
            .onChange(of: nav.recenterToken) { _, _ in
                vm.focusOnUser()
            }
            .onOpenURL { url in
                self.handleDeepLink(url)
            }
        }
    }
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("SpotMap")
                        .font(.system(size: 16, weight: .bold))
                    Text(vm.repo.backend.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer(minLength: 0)
            
            SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie") {
                vm.focusOnUser()
            }
            
            // Quick toggle: Achievement map layer (Explore)
            SpotCircleButton(
                systemImage: exploreEnabled ? "square.3.layers.3d.down.right" : "square.3.layers.3d",
                accessibilityLabel: "Achievement kaartlaag"
            ) {
                let gen = UIImpactFeedbackGenerator(style: .light)
                gen.impactOccurred()
                withAnimation(.easeInOut(duration: 0.18)) {
                    exploreEnabled.toggle()
                }
            }
            
            Menu {
                Button {
                    showingSpotsList = true
                } label: { Label("Spots", systemImage: "list.bullet") }
                
                Button {
                    vm.showingAdd = true
                } label: { Label("Nieuwe spot", systemImage: "mappin.and.ellipse") }
                
                Button {
                    showingJourneysSheet = true
                } label: { Label("Journeys", systemImage: "car") }
                
                Button {
                    showingAchievements = true
                } label: { Label("Achievements", systemImage: "trophy") }
                
                Button {
                    journeys.toggle()
                } label: {
                    Label(journeys.trackingEnabled ? "Tracking uit" : "Tracking aan",
                          systemImage: journeys.trackingEnabled ? "location.slash" : "location.fill")
                }
                
                Divider()
                
                Button {
                    let c = vm.mapCenter
                    vm.repo.refreshNearby(center: CLLocation(latitude: c.latitude, longitude: c.longitude), force: true)
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                
                Button {
                    showingSettings = true
                } label: { Label("Instellingen", systemImage: "gearshape") }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                        .frame(width: SpotBrand.circleButtonSize, height: SpotBrand.circleButtonSize)
                        .shadow(radius: 6)
                    Image(systemName: "ellipsis")
                        .font(.system(size: SpotBrand.iconSize, weight: .semibold))
                }
            }
            .accessibilityLabel("Menu")
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8)
    }
    
    private var mapLayer: some View {
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
                    
                    // Friends (optional)
                    ForEach(friends.friends) { f in
                        if let c = f.coordinate {
                            Marker(f.displayName, coordinate: c)
                        }
                        if let data = f.lastJourneyZlib,
                           let poly = FriendRouteDecoder.polyline(fromZlib: data) {
                            MapPolyline(poly)
                                .stroke(.blue.opacity(0.35), lineWidth: 4)
                        }
                    }
                    
                    // NOTE: clouds/trees are drawn as a lightweight overlay (NOT Map annotations)
                    // to keep taps and scrolling responsive.
                    
                    if let dest = nav.destination?.placemark.coordinate {
                        Marker(nav.destinationName ?? "Bestemming", coordinate: dest)
                    }
                    
                    ForEach(vm.repo.spots) { spot in
                        Marker(spot.title, coordinate: spot.location.coordinate)
                            .tag(spot.id.recordName)
                    }
                    
                    UserAnnotation()
                    }
                    .mapStyle(exploreEnabled ? .standard(elevation: .flat) : .standard)
                    .mapControls {
                        MapCompass()
                        MapScaleView()
                        MapUserLocationButton()
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        vm.mapCenterChanged(to: context.region.center)
                        if exploreEnabled {
                            scheduleFogCloudUpdate(proxy: proxy, canvasSize: geo.size)
                        }
                    }
                    .onChange(of: selection) { _, newValue in
                        guard let recordName = newValue else { return }
                        if let spot = vm.repo.spot(withRecordName: recordName) {
                            vm.selectedSpot = spot
                        }
                    }
                    .onAppear {
                        if exploreEnabled {
                            fogCloudField.start(store: fog)
                            scheduleFogCloudUpdate(proxy: proxy, canvasSize: geo.size)
                            // Ensure we update after first layout (MapProxy.convert can return nil early).
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                await MainActor.run {
                                    guard exploreEnabled else { return }
                                    scheduleFogCloudUpdate(proxy: proxy, canvasSize: geo.size)
                                }
                            }
                        }
                    }
                    .onChange(of: exploreEnabled) { _, newValue in
                        if newValue {
                            fogCloudField.start(store: fog)
                            scheduleFogCloudUpdate(proxy: proxy, canvasSize: geo.size)
                            // Ensure we update after first layout (MapProxy.convert can return nil early).
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                await MainActor.run {
                                    guard exploreEnabled else { return }
                                    scheduleFogCloudUpdate(proxy: proxy, canvasSize: geo.size)
                                }
                            }
                        } else {
                            fogCloudField.stop()
                        }
                    }
                }

                // TRUE 3D clouds overlay.
                // Only render when Explore is enabled.
                if exploreEnabled {
                    // Convert cloud world coordinates to screen-space points.
                    // We keep clouds pinned to the map content (screen-space) and render them as true 3D
                    // in a transparent SceneKit overlay.
                    //
                    // IMPORTANT:
                    // Keep clouds world-anchored so they stay fixed relative to map content while
                    // the camera moves around them. `MapProxy.convert` already accounts for the
                    // current camera heading/pitch, so we keep the projected points as-is.
                    let items: [CloudVoxelItem] = fogCloudField.clouds.compactMap { c in
                        guard let pt = proxy.convert(c.coordinate, to: .local) else { return nil }
                        return CloudVoxelItem(
                            id: c.id,
                            screenPoint: pt,
                            sizePoints: c.sizePoints,
                            altitudeMeters: c.altitudeMeters,
                            asset: c.asset,
                            seed: c.seed
                        )
                    }

                    CloudVoxelOverlayView(
                        items: items,
                        // Keep cloud assets independent from map rotation/tilt.
                        headingDegrees: 0,
                        pitchDegrees: 0,
                        viewportSize: geo.size
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
            }
        }
    }
    
    
    // MARK: - Fog cloud updates

    private func scheduleFogCloudUpdate(proxy: MapProxy, canvasSize: CGSize) {
        // Throttle to avoid recomputing clouds too often while GPS updates are flowing.
        fogDebouncer.schedule(delay: .milliseconds(120)) {
            fogCloudField.updateViewport(proxy: proxy, canvasSize: canvasSize)
        }
    }

    // MARK: - Deep links
    
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "spotmap" else { return }
        
        // spotmap://spot/<id>
        // spotmap://navigate/spot/<id>
        // spotmap://journeys
        // spotmap://journey/toggle
        let parts = url.pathComponents
        
        guard parts.count >= 2 else { return }
        
        switch parts[1] {
        case "spot":
            vm.handleDeepLink(url)
            
        case "navigate":
            guard parts.count >= 4, parts[2] == "spot" else { return }
            let recordName = parts[3]
            
            Task {
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
                        if ready {
                            await MainActor.run { nav.startNavigation() }
                            break
                        }
                    }
                }
            }
            
        case "journeys":
            showingJourneysSheet = true
            
        case "journey":
            if parts.count >= 3, parts[2] == "toggle" {
                journeys.toggle()
            }
            
        default:
            break
        }
    }
    
    
    // MARK: - Achievements
    
    /// Dedicated achievements/progress screen.
    /// This is intentionally calm + minimal (no clutter), and includes a single
    /// toggle to show/hide the Achievement map layer.
    struct AchievementsView: View {
        @EnvironmentObject private var journeys: JourneyRepository
        @ObservedObject private var explore = ExploreStore.shared
        @AppStorage("Explore.enabled") private var exploreEnabled: Bool = false
        @Environment(\.dismiss) private var dismiss
        
        private var totalKm: Double { explore.totalDistanceKm(from: journeys.journeys) }
        private var level: Int { explore.level(for: totalKm) }
        private var progress: Double { explore.progressToNextLevel(for: totalKm) }
        
        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Level card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Level \(level)")
                                        .font(.title2.bold())
                                    Text("Totaal gereden")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f km", totalKm))
                                    .font(.headline)
                            }
                            
                            ProgressView(value: progress)
                                .tint(.blue)
                            
                            let next = Double(level) * 100.0
                            Text("Nog \(max(0.0, next - totalKm), specifier: "%.0f") km tot level \(level + 1)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        
                        // Map layer toggle
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "square.3.layers.3d")
                                Text("Achievement kaart")
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: $exploreEnabled)
                                    .labelsHidden()
                            }
                            Text("Zet deze laag aan om je vrijgespeelde gebieden op de kaart te zien.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        
                        // Stats
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Voortgang")
                                .font(.headline)
                            
                            HStack {
                                StatPill(title: "Tegels", value: "\(explore.visitedTiles.count)", systemImage: "square.grid.3x3")
                                StatPill(title: "Steden", value: "\(explore.visitedCities.count)", systemImage: "building.2")
                            }
                            
                            Text("Elke journey kleurt nieuwe kaart-tegels in. Steden/dorpen worden bepaald op basis van start- en eindpunt.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        
                        // Countries
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Steden per land")
                                    .font(.headline)
                                Spacer()
                            }
                            
                            let dict = explore.citiesByCountry()
                            if dict.isEmpty {
                                Text("Nog geen steden/dorpen ontdekt. Maak een journey om te beginnen.")
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
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .navigationTitle("Achievements")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
    
    private struct StatPill: View {
        let title: String
        let value: String
        let systemImage: String
        
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
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
