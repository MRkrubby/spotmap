import Foundation
import Combine
import SwiftUI
import MapKit
import CoreLocation
import os

/// A decorative tree shown near the edges of the viewport (purely cosmetic).
struct EdgeTree: Identifiable, Hashable {
    let id: UInt64
    let coordinate: CLLocationCoordinate2D
    let sizePoints: CGFloat
    let variant: Int
    let seed: UInt64

    static func == (lhs: EdgeTree, rhs: EdgeTree) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Generates a bounded set of tree objects near the edges of the current map viewport.
///
/// Design goals:
/// - Looks like a subtle "frame" around the map in Explore mode.
/// - Deterministic + throttled updates (no endless creation).
/// - Lightweight: keep tree count small and scale with zoom.
@MainActor
final class EdgeTreeField: ObservableObject {
    
    @Published private(set) var trees: [EdgeTree] = []

    // Tunables
    var maxTrees: Int = 80

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "EdgeTreeField")

    private var visibleRect: MKMapRect = MKMapRect(x: 0, y: 0, width: 1, height: 1)
    private var metersPerPoint: Double = 1.0
    private var canvasSize: CGSize = .zero

    // Stability: only rebuild if camera moved "enough".
    private var lastBuildKey: UInt64 = 0

    func clear() {
        trees.removeAll()
        lastBuildKey = 0
    }

    func updateViewport(proxy: MapProxy, canvasSize: CGSize) {
        self.canvasSize = canvasSize
        self.metersPerPoint = Self.estimateMetersPerPoint(proxy: proxy, canvasSize: canvasSize)
        self.visibleRect = Self.visibleMapRect(proxy: proxy, canvasSize: canvasSize)

        guard visibleRect.size.width > 2, visibleRect.size.height > 2 else { return }

        let key = buildKey(rect: visibleRect, metersPerPoint: metersPerPoint)
        guard key != lastBuildKey else { return } // no work
        lastBuildKey = key

        rebuildTrees()
    }

    private func rebuildTrees() {
        // Scale count with zoom:
        // - zoomed in -> fewer, slightly larger
        // - zoomed out -> a few more, slightly smaller
        let mpp = max(0.15, min(35, metersPerPoint))
        let zoom = sqrt(mpp) // 0.38..5.9
        let target = Int(Double(maxTrees) / max(1.0, zoom * 1.05))
        let targetCount = max(18, min(maxTrees, target))

        // Edge band thickness in world units.
        let bandMeters = max(60.0, min(220.0, mpp * 120.0))
        // Convert meters to MKMapPoints.
        let bandMapPoints = bandMeters / MKMetersPerMapPointAtLatitude(visibleRect.centerCoordinate.latitude)

        let inner = visibleRect.insetBy(dx: bandMapPoints, dy: bandMapPoints)
        let outer = visibleRect

        // Deterministic seed per viewport so it doesn't shimmer.
        let baseSeed = mix64(UInt64(bitPattern: Int64(outer.midX.rounded())) ^ UInt64(bitPattern: Int64(outer.midY.rounded())))

        var rng = SplitMix(seed: baseSeed)
        var newTrees: [EdgeTree] = []
        newTrees.reserveCapacity(targetCount)

        // Generate points in the ring: in outer but not in inner.
        // Try more times than needed to fill robustly.
        let attempts = targetCount * 8
        for _ in 0..<attempts {
            if newTrees.count >= targetCount { break }

            let x = outer.minX + rng.nextDouble() * outer.size.width
            let y = outer.minY + rng.nextDouble() * outer.size.height
            let mp = MKMapPoint(x: x, y: y)

            if inner.contains(mp) { continue }

            // Avoid being too close to corners (often overlaps UI).
            let c = outer.center
            let dx = (mp.x - c.x) / max(1, outer.size.width)
            let dy = (mp.y - c.y) / max(1, outer.size.height)
            if abs(dx) > 0.46 && abs(dy) > 0.46 { continue }

            let seed = mix64(baseSeed ^ UInt64(bitPattern: Int64(x.rounded())) &+ (UInt64(bitPattern: Int64(y.rounded())) << 1))
            let id = seed

            // Size in points: slightly larger when zoomed in.
            let basePx = max(34.0, min(72.0, 62.0 / max(0.55, zoom)))
            let jitter = 0.78 + 0.55 * rng.nextDouble()
            let size = CGFloat(basePx * jitter)

            // Variant selection (if pack contains multiple meshes).
            let variant = Int(seed % 12)

            newTrees.append(EdgeTree(id: id, coordinate: mp.coordinate, sizePoints: size, variant: variant, seed: seed))
        }

        // If we underfilled, keep what we have (better than infinite loops).
        self.trees = newTrees

        log.debug("Edge trees rebuilt: \(self.trees.count) (mpp=\(self.metersPerPoint, format: .fixed(precision: 2)))")
    }

    // MARK: - Keys / hashing

    private func buildKey(rect: MKMapRect, metersPerPoint: Double) -> UInt64 {
        // Quantize to reduce churn: ~5% screen movement triggers rebuild.
        let qx = Int64((rect.midX / max(1, rect.size.width)) * 1000)
        let qy = Int64((rect.midY / max(1, rect.size.height)) * 1000)
        let qz = Int64(max(1, min(9999, metersPerPoint * 100)))
        return mix64(UInt64(bitPattern: qx) ^ (UInt64(bitPattern: qy) << 1) ^ (UInt64(bitPattern: qz) << 2))
    }

    private func mix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    // MARK: - MapProxy helpers (copied from FogCloudField for consistency)

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

    private static func visibleMapRect(proxy: MapProxy, canvasSize: CGSize) -> MKMapRect {
        let pts: [CGPoint] = [
            .init(x: 0, y: 0),
            .init(x: canvasSize.width, y: 0),
            .init(x: 0, y: canvasSize.height),
            .init(x: canvasSize.width, y: canvasSize.height)
        ]

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for p in pts {
            guard let c = proxy.convert(p, from: .local) else { continue }
            let mp = MKMapPoint(c)
            minX = min(minX, mp.x)
            minY = min(minY, mp.y)
            maxX = max(maxX, mp.x)
            maxY = max(maxY, mp.y)
        }

        if minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite {
            return MKMapRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }

        return MKMapRect(x: 0, y: 0, width: 1, height: 1)
    }
}

// MARK: - MKMapRect helpers

private extension MKMapRect {
    var center: MKMapPoint { MKMapPoint(x: midX, y: midY) }
    var centerCoordinate: CLLocationCoordinate2D { center.coordinate }
}

// MARK: - RNG

fileprivate struct SplitMix {
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

