import SwiftUI
import MapKit
import CoreLocation

/// A "drive" dashboard inspired by CarPlay-style layouts.
///
/// It's intentionally app-local (no CarPlay entitlement required) but gives the same
/// quick-glance UX: speed, distance, and a big start/stop.
struct DriveDashboardView: View {
    @EnvironmentObject private var journeys: JourneyRepository
    @EnvironmentObject private var nav: NavigationManager
    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var showingJourneys = false
    @AppStorage("UserLocation.style") private var userLocationStyleRaw: String = UserLocationStyle.system.rawValue
    @AppStorage("UserLocation.assetId") private var userLocationAssetId: String = "suv"

    var body: some View {
        ZStack {
            mapLayer
            overlay
            if nav.isNavigating {
                NavigationHUDOverlay()
                    .environmentObject(nav)
            }
        }
        .ignoresSafeArea(edges: .all)
        .onAppear {
            journeys.requestPermissionsIfNeeded()
        }
        .sheet(isPresented: $showingJourneys) {
            JourneysView()
                .environmentObject(journeys)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private var mapLayer: some View {
        let style = UserLocationStyle.from(rawValue: userLocationStyleRaw)
        let asset = VehicleAssetsCatalog.shared.asset(for: userLocationAssetId)
        Map(position: $mapPosition) {
            let coords = journeys.currentPolyline()
            if coords.count >= 2 {
                let line = MKPolyline(coordinates: coords, count: coords.count)
                MapPolyline(line)
                    .stroke(.blue, lineWidth: 8)
            }

            if let r = nav.route {
                MapPolyline(r.polyline)
                    .stroke(.orange, lineWidth: 6)
            }
            UserAnnotation {
                UserLocationMarkerView(style: style, asset: asset)
            }
        }
        .mapStyle(.standard)
        .onChange(of: journeys.currentPolyline().count) { _, _ in
            let coords = journeys.currentPolyline()
            if let last = coords.last {
                mapPosition = .region(MKCoordinateRegion(
                    center: last,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
        .onChange(of: nav.recenterToken) { _, _ in
            mapPosition = .userLocation(fallback: .automatic)
        }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                speedWidget
                Spacer()
                topRightWidgets
            }
            .padding(12)

            Spacer()

            HStack(alignment: .bottom) {
                bottomLeft
                Spacer()
                rightButtons
            }
            .padding(12)
        }
    }

    private var speedWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snelheid")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(JourneyFormat.speedKmh(journeys.currentSpeedMps))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8)
    }

    private var topRightWidgets: some View {
        VStack(alignment: .trailing, spacing: 10) {
            widget(title: "Afstand", value: JourneyFormat.km(journeys.currentDistanceMeters))
            widget(title: "Max", value: JourneyFormat.speedKmh(journeys.currentMaxSpeedMps))
        }
    }

    private func widget(title: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var bottomLeft: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(journeys.isRecording ? "Rit loopt" : "Drive mode")
                .font(.subheadline.weight(.semibold))
            if let start = journeys.startedAt {
                Text("Sinds \(start.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Start een rit om je journey te loggen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                journeys.toggle()
            } label: {
                Label(journeys.isRecording ? "Stop" : "Start", systemImage: journeys.isRecording ? "stop.fill" : "record.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private var rightButtons: some View {
        VStack(spacing: 12) {
            circleButton(systemImage: "xmark") {
                dismiss()
            }
            circleButton(systemImage: "location.fill") {
                nav.requestRecenter()
            }
            circleButton(systemImage: "list.bullet") {
                showingJourneys = true
            }
            circleButton(systemImage: journeys.isRecording ? "stop.fill" : "record.circle") {
                journeys.toggle()
            }
        }
    }

    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 6)
    }
}
