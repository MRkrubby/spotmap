import SwiftUI
import MapKit

struct JourneyDetailView: View {
    let record: JourneyRecord
    @State private var mapPosition: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 12) {
            header
            routeMap
            stats
        }
        .padding(12)
        .onAppear {
            mapPosition = .region(record.boundingRegion())
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text("\(JourneyFormat.km(record.distanceMeters)) • \(JourneyFormat.duration(record.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var routeMap: some View {
        let coords = record.decodedPoints().map { $0.coordinate }

        return Map(position: $mapPosition) {
            if coords.count >= 2 {
                let line = MKPolyline(coordinates: coords, count: coords.count)
                MapPolyline(line)
                    .stroke(.blue, lineWidth: 6)
            }

            if let start = coords.first {
                Marker("Start", coordinate: start)
            }
            if let end = coords.last {
                Marker("Einde", coordinate: end)
            }
        }
        .mapStyle(.standard)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var stats: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                stat(title: "Gemiddeld", value: JourneyFormat.speedKmh(record.avgSpeedMps))
                stat(title: "Max", value: JourneyFormat.speedKmh(record.maxSpeedMps))
            }
            HStack(spacing: 10) {
                stat(title: "Afstand", value: JourneyFormat.km(record.distanceMeters))
                stat(title: "Duur", value: JourneyFormat.duration(record.duration))
            }
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
