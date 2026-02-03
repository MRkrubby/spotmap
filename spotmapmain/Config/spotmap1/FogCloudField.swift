import Foundation
import SwiftUI
import Combine
import MapKit
import CoreLocation
import os

struct FogCloud: Identifiable, Hashable {
    let id: UInt64
    let coordinate: CLLocationCoordinate2D
    let sizeMeters: Double
    let altitudeMeters: Double
    let asset: CloudAsset
    let seed: UInt64

    static func == (lhs: FogCloud, rhs: FogCloud) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class FogCloudField: ObservableObject {
    @Published private(set) var clouds: [FogCloud] = []
    @Published private(set) var metersPerPointNow: Double = 1.0
    @Published private(set) var centerCoordinateNow: CLLocationCoordinate2D = .init(latitude: 0, longitude: 0)

    // User request
    var maxClouds: Int = 125

    // Spacing + density (tune)
    var tileSizeMeters: Double = 2600          // bigger => farther apart
    var tileFillProbability: Double = 0.68     // higher => more clouds visible

    // Map-bound size range (meters)
    var cloudSizeMetersMin: Double = 260
    var cloudSizeMetersMax: Double = 780

    // Height range (meters)
    var cloudAltitudeMin: Double = 18
    var cloudAltitudeMax: Double = 85

    var exploredResidualChance: Double = 0.18

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "CloudField")

    private var store: FogOfWarStore?
    private var lastCanvasSize: CGSize = .zero
    private var globalSeed: UInt64 = 0xBADC0FFEE0DDF00D

    func clear() {
        clouds.removeAll()
    }

    func start(store: FogOfWarStore) {
        self.store = store
        log.info("CloudField started (deterministic)")
    }

    func stop() {
        self.store = nil
        clear()
        log.info("CloudField stopped")
    }

    func updateViewport(proxy: MapProxy, canvasSize: CGSize, centerCoordinate: CLLocationCoordinate2D) {
        self.lastCanvasSize = canvasSize
        self.centerCoordinateNow = centerCoordinate
        self.metersPerPointNow = Self.estimateMetersPerPoint(proxy: proxy, canvasSize: canvasSize)
        rebuild()
    }

    func exploredChanged() {
        rebuild()
    }

    private func rebuild() {
        guard let store else { return }
        let canvasSize = lastCanvasSize
        guard canvasSize.width > 10, canvasSize.height > 10 else { return }

        let centerMP = MKMapPoint(centerCoordinateNow)
        let lat = centerCoordinateNow.latitude
        let metersPerMapPoint = max(0.0001, MKMetersPerMapPointAtLatitude(lat))

        // north-up rect, ignoring heading/pitch
        let halfWidthMeters = Double(canvasSize.width) * metersPerPointNow * 0.5
        let halfHeightMeters = Double(canvasSize.height) * metersPerPointNow * 0.5
        let halfWidthMP = halfWidthMeters / metersPerMapPoint
        let halfHeightMP = halfHeightMeters / metersPerMapPoint

        var rect = MKMapRect(
            x: centerMP.x - halfWidthMP,
            y: centerMP.y - halfHeightMP,
            width: max(1.0, halfWidthMP * 2),
            height: max(1.0, halfHeightMP * 2)
        )

        // pad so edges don't pop
        let padMeters = max(tileSizeMeters * 0.75, 1200)
        let padMP = padMeters / metersPerMapPoint
        rect = rect.insetBy(dx: -padMP, dy: -padMP)

        let tileMP = tileSizeMeters / metersPerMapPoint
        guard tileMP > 0.01 else { return }

        let minTileX = Int(floor(rect.minX / tileMP))
        let maxTileX = Int(ceil(rect.maxX / tileMP))
        let minTileY = Int(floor(rect.minY / tileMP))
        let maxTileY = Int(ceil(rect.maxY / tileMP))

        var out: [FogCloud] = []
        out.reserveCapacity(min(maxClouds, max(1, (maxTileX - minTileX + 1) * (maxTileY - minTileY + 1))))

        for ty in minTileY...maxTileY {
            for tx in minTileX...maxTileX {
                let seed = tileSeed(tx: tx, ty: ty)
                var rng = SplitMix(seed: seed)

                if rng.nextDouble() > tileFillProbability { continue }

                let jx = (rng.nextDouble() - 0.5) * 0.52
                let jy = (rng.nextDouble() - 0.5) * 0.52

                let x = (Double(tx) + 0.5 + jx) * tileMP
                let y = (Double(ty) + 0.5 + jy) * tileMP
                let mp = MKMapPoint(x: x, y: y)
                if !rect.contains(mp) { continue }

                if store.isExplored(coordinate: mp.coordinate), rng.nextDouble() > exploredResidualChance {
                    continue
                }

                let sizeMeters = cloudSizeMetersMin + (cloudSizeMetersMax - cloudSizeMetersMin) * rng.nextDouble()

                let altitude = cloudAltitudeMin + (cloudAltitudeMax - cloudAltitudeMin) * rng.nextDouble()
                let asset = chooseAsset(seed: seed)

                out.append(FogCloud(
                    id: seed,
                    coordinate: mp.coordinate,
                    sizeMeters: sizeMeters,
                    altitudeMeters: altitude,
                    asset: asset,
                    seed: seed
                ))
            }
        }

        out.sort {
            let a = MKMapPoint($0.coordinate)
            let b = MKMapPoint($1.coordinate)
            let da = hypot(a.x - centerMP.x, a.y - centerMP.y)
            let db = hypot(b.x - centerMP.x, b.y - centerMP.y)
            if da != db { return da < db }
            return $0.id < $1.id
        }

        if out.count > maxClouds {
            out.removeLast(out.count - maxClouds)
        }

        self.clouds = out
    }

    private func tileSeed(tx: Int, ty: Int) -> UInt64 {
        let a = UInt64(bitPattern: Int64(tx))
        let b = UInt64(bitPattern: Int64(ty))
        return mix64(globalSeed ^ (a &* 0x9E3779B97F4A7C15) ^ (b &* 0xBF58476D1CE4E5B9))
    }

    private func chooseAsset(seed: UInt64) -> CloudAsset {
        let r = Double((seed >> 16) & 0xFFFF) / Double(0xFFFF)
        if r < 0.68 { return .stylized }
        if r < 0.92 { return .cartoon }
        return .tiny
    }

    private static func estimateMetersPerPoint(proxy: MapProxy, canvasSize: CGSize) -> Double {
        let sample: CGFloat = 120
        let p1 = CGPoint(x: canvasSize.width * 0.5, y: canvasSize.height * 0.5)
        let p2 = CGPoint(x: min(canvasSize.width - 1, p1.x + sample), y: p1.y)
        guard let c1 = proxy.convert(p1, from: .local),
              let c2 = proxy.convert(p2, from: .local) else {
            return 1.0
        }
        let d = CLLocation(latitude: c1.latitude, longitude: c1.longitude)
            .distance(from: CLLocation(latitude: c2.latitude, longitude: c2.longitude))
        return max(0.001, Double(d) / Double(sample))
    }

    private func mix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private struct SplitMix {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func nextDouble() -> Double {
            Double(nextUInt64() >> 11) / Double(1 << 53)
        }
    }
}
