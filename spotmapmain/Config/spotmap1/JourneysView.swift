import SwiftUI
import MapKit
import CoreLocation

struct JourneysView: View {
    @EnvironmentObject private var journeys: JourneyRepository
    @State private var selected: JourneyRecord?
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    recordingCard
                    journeysList
                }
                .padding(12)
            }
            .navigationTitle("Journeys")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $selected) { record in
                JourneyDetailView(record: record)
                    .presentationDetents([.medium, .large])
            }
            .alert(
                "Melding",
                isPresented: Binding(
                    get: { journeys.lastErrorMessage != nil },
                    set: { if !$0 { journeys.lastErrorMessage = nil } }
                ),
                actions: { Button("OK", role: .cancel) { journeys.lastErrorMessage = nil } },
                message: { Text(journeys.lastErrorMessage ?? "") }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trip logging")
                    .font(.headline)
                Text("Routes worden automatisch bijgehouden vanaf het moment dat je SpotMap opent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Spacer()
            Button {
                journeys.requestPermissionsIfNeeded()
            } label: {
                Image(systemName: "location")
            }
            .buttonStyle(.plain)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(journeys.trackingEnabled ? "Tracking aan" : "Tracking uit")
                        .font(.headline)
                    Text(journeys.trackingEnabled ? "Je route en stats worden gelogd (ook in achtergrond als toegestaan)." : "Zet tracking aan om routes te loggen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                Spacer()

                Button {
                    journeys.toggle()
                } label: {
                    Label(journeys.trackingEnabled ? "Uitzetten" : "Aanzetten",
                          systemImage: journeys.trackingEnabled ? "location.slash" : "location.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }

            // Mini map preview
            ZStack {
                Map(position: $mapPosition) {
                    let coords = journeys.currentPolyline()
                    if coords.count >= 2 {
                        let line = MKPolyline(coordinates: coords, count: coords.count)
                        MapPolyline(line)
                            .stroke(.blue, lineWidth: 6)
                    } else if let center = coords.last {
                        Marker("", coordinate: center)
                    }
                }
                .mapStyle(.standard)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !journeys.isRecording && journeys.journeys.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "car")
                            .font(.title2)
                        Text("Geen journeys nog")
                            .font(.headline)
                        Text("Maak je eerste rit en je ziet 'm hier terug.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .onChange(of: journeys.currentPolyline().count) { _, _ in
                // Keep preview framed on the latest point.
                let coords = journeys.currentPolyline()
                if let last = coords.last {
                    mapPosition = .region(MKCoordinateRegion(
                        center: last,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))
                }
            }

            // Stats row
            HStack(spacing: 10) {
                statPill(title: "Snelheid", value: JourneyFormat.speedKmh(journeys.currentSpeedMps))
                statPill(title: "Afstand", value: JourneyFormat.km(journeys.currentDistanceMeters))
                statPill(title: "Max", value: JourneyFormat.speedKmh(journeys.currentMaxSpeedMps))
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var journeysList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Jouw journeys")
                    .font(.headline)
                Spacer()
                Text("\(journeys.journeys.count)")
                    .foregroundStyle(.secondary)
            }

            ForEach(journeys.journeys) { record in
                Button {
                    selected = record
                } label: {
                    JourneyRow(record: record)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        journeys.delete(record)
                    } label: {
                        Label("Verwijderen", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct JourneyRow: View {
    let record: JourneyRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .minimumScaleFactor(0.85)
                Text("\(JourneyFormat.km(record.distanceMeters)) • \(JourneyFormat.duration(record.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.85)
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(JourneyFormat.speedKmh(record.avgSpeedMps))
                    .font(.headline)
                    .minimumScaleFactor(0.85)
                Text("avg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
