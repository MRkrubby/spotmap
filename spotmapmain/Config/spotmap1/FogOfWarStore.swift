import Foundation
import CoreLocation
import MapKit
import os
import Combine

/// Fog-of-war exploration store ("voxels" with LOD).
///
/// - Stores exploration at a fine, fixed resolution (`baseCellMeters`).
/// - Renders using Level-of-Detail aggregation based on zoom (meters-per-point).
///   When zoomed out we aggregate many fine cells into larger parent cells,
///   reducing draw calls / memory pressure.
@MainActor
final class FogOfWarStore: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    
    static let shared = FogOfWarStore()

    // MARK: - Types

    /// Fine cell coordinate (base grid).
    struct Cell: Hashable, Codable {
        var x: Int
        var y: Int
    }

    /// Chunk id for spatial indexing (base grid).
    private struct ChunkID: Hashable {
        let cx: Int
        let cy: Int
    }

    // MARK: - Config

    /// Finest voxel size in meters (MKMapPoint units). Smaller = more detail.
    /// 10m is a good balance for memory/accuracy.
    let baseCellMeters: Double

    /// Reveal radius around the driven path.
    let revealRadiusMeters: Double

    /// Chunk size in *cells* (power-of-two recommended).
    private let chunkSizeCells: Int
    private let chunkShift: Int

    // MARK: - State

    /// Explored fine cells stored packed for memory efficiency.
    @Published private(set) var exploredFinePacked: Set<Int64> = []

    /// Spatial index: chunk -> packed fine cells.
    private var chunks: [ChunkID: Set<Int64>] = [:]

    private let storageKey = "FogOfWar.voxels.v2"
    private var lastRevealed: CLLocation?

    // Logging
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "spotmap", category: "FogOfWar")

    private init(baseCellMeters: Double = 10, revealRadiusMeters: Double = 20, chunkSizeCells: Int = 128) {
        self.baseCellMeters = baseCellMeters
        self.revealRadiusMeters = revealRadiusMeters
        self.chunkSizeCells = max(32, chunkSizeCells)

        // Compute shift if chunkSizeCells is power-of-two, else fall back to division.
        let shift = Int(log2(Double(self.chunkSizeCells)).rounded())
        self.chunkShift = (1 << shift) == self.chunkSizeCells ? shift : 0

        // Initialize stored properties that have defaults
        self.exploredFinePacked = []
        self.chunks = [:]
        self.lastRevealed = nil

        // Load persisted cells and rebuild chunks now that all stored properties are initialized
        let loaded = Self.load(key: storageKey)
        self.exploredFinePacked = loaded
        self.rebuildChunks(from: loaded)
    }

    // MARK: - Public API

    /// Clear all exploration.
    func reset() {
        exploredFinePacked.removeAll()
        chunks.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        lastRevealed = nil
        log.info("Fog reset")
    }

    /// Reveal voxels around a location.
    ///
    /// - Parameters:
    ///   - location: current GPS location
    ///   - minMoveMeters: minimum movement before we reveal again (throttle)
    func reveal(location: CLLocation, minMoveMeters: Double = 6) {
        if let lastRevealed, location.distance(from: lastRevealed) < minMoveMeters {
            return
        }
        lastRevealed = location

        let mp = MKMapPoint(location.coordinate)
        let cx = Int(floor(mp.x / baseCellMeters))
        let cy = Int(floor(mp.y / baseCellMeters))
        let radiusCells = Int(ceil(revealRadiusMeters / baseCellMeters))

        var inserted = 0

        for dx in -radiusCells...radiusCells {
            for dy in -radiusCells...radiusCells {
                let x = cx + dx
                let y = cy + dy
                let packed = Self.pack(x: x, y: y)
                if exploredFinePacked.insert(packed).inserted {
                    inserted += 1
                    let chunkID = chunkIDForCell(x: x, y: y)
                    chunks[chunkID, default: []].insert(packed)
                }
            }
        }

        if inserted > 0 {
            Self.save(exploredFinePacked, key: storageKey)
            log.debug("Reveal inserted \(inserted, privacy: .public) cells")
        }
    }

    /// Returns the current display level-of-detail and a list of cells
    /// (possibly aggregated) that are relevant for the given visible rect.
    ///
    /// - Parameters:
    ///   - visibleRect: visible map rect in MKMapPoint meters
    ///   - metersPerScreenPoint: current zoom scale
    ///   - targetCellPixels: preferred rendered cell size in screen points
    func displayCells(in visibleRect: MKMapRect,
                      metersPerScreenPoint: Double,
                      targetCellPixels: Double = 22,
                      extraMeters: Double = 250) -> (level: Int, cells: [Cell]) {

        // Choose LOD level: baseCellMeters * 2^level ≈ metersPerPoint * targetCellPixels
        let targetMeters = max(1, metersPerScreenPoint) * targetCellPixels
        let rawLevel = log2(max(1, targetMeters / baseCellMeters))
        let level = max(0, min(12, Int(rawLevel.rounded())))

        // Expand rect a bit so holes don't pop at edges
        let rect = visibleRect.insetBy(dx: -extraMeters, dy: -extraMeters)

        // Convert rect bounds to base-grid cell bounds
        let minX = Int(floor(rect.minX / baseCellMeters))
        let maxX = Int(ceil(rect.maxX / baseCellMeters))
        let minY = Int(floor(rect.minY / baseCellMeters))
        let maxY = Int(ceil(rect.maxY / baseCellMeters))

        // Find overlapping chunks
        let (minChunkX, maxChunkX, minChunkY, maxChunkY) = chunkBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)

        if level == 0 {
            // Fine cells only
            var out: [Cell] = []
            out.reserveCapacity(2048)
            for cx in minChunkX...maxChunkX {
                for cy in minChunkY...maxChunkY {
                    guard let set = chunks[ChunkID(cx: cx, cy: cy)] else { continue }
                    for packed in set {
                        let (x, y) = Self.unpack(packed)
                        if x >= minX && x <= maxX && y >= minY && y <= maxY {
                            out.append(Cell(x: x, y: y))
                        }
                    }
                }
            }
            return (level, out)
        }

        // Aggregated parent cells (voxels become larger as you zoom out)
        let shift = level
        let parentMinX = minX >> shift
        let parentMaxX = maxX >> shift
        let parentMinY = minY >> shift
        let parentMaxY = maxY >> shift

        var parents: Set<Int64> = []
        parents.reserveCapacity(2048)

        for cx in minChunkX...maxChunkX {
            for cy in minChunkY...maxChunkY {
                guard let set = chunks[ChunkID(cx: cx, cy: cy)] else { continue }
                for packed in set {
                    let (x, y) = Self.unpack(packed)
                    if x < minX || x > maxX || y < minY || y > maxY { continue }
                    let px = x >> shift
                    let py = y >> shift
                    if px >= parentMinX && px <= parentMaxX && py >= parentMinY && py <= parentMaxY {
                        parents.insert(Self.pack(x: px, y: py))
                    }
                }
            }
        }

        var out: [Cell] = []
        out.reserveCapacity(parents.count)
        for p in parents {
            let (x, y) = Self.unpack(p)
            out.append(Cell(x: x, y: y))
        }
        return (level, out)
    }

    /// Center coordinate for a displayed cell at a given LOD level.
    func coordinate(for cell: Cell, level: Int) -> CLLocationCoordinate2D {
        let size = baseCellMeters * Double(1 << max(0, level))
        let x = (Double(cell.x) + 0.5) * size
        let y = (Double(cell.y) + 0.5) * size
        return MKMapPoint(x: x, y: y).coordinate
    }

    /// Suggested hole radius for a given LOD level, in meters.
    ///
    /// We keep holes roughly proportional to the rendered cell size.
    func holeRadiusMeters(for level: Int) -> Double {
        let size = baseCellMeters * Double(1 << max(0, level))
        return max(revealRadiusMeters, size * 0.55)
    }

    // MARK: - Internals

    private func rebuildChunks(from set: Set<Int64>) {
        chunks.removeAll(keepingCapacity: true)
        for packed in set {
            let (x, y) = Self.unpack(packed)
            let id = chunkIDForCell(x: x, y: y)
            chunks[id, default: []].insert(packed)
        }
    }

    private func chunkIDForCell(x: Int, y: Int) -> ChunkID {
        if chunkShift > 0 {
            return ChunkID(cx: x >> chunkShift, cy: y >> chunkShift)
        }
        return ChunkID(cx: x / chunkSizeCells, cy: y / chunkSizeCells)
    }

    private func chunkBounds(minX: Int, maxX: Int, minY: Int, maxY: Int) -> (Int, Int, Int, Int) {
        if chunkShift > 0 {
            return (minX >> chunkShift, maxX >> chunkShift, minY >> chunkShift, maxY >> chunkShift)
        }
        return (minX / chunkSizeCells, maxX / chunkSizeCells, minY / chunkSizeCells, maxY / chunkSizeCells)
    }

    private static func pack(x: Int, y: Int) -> Int64 {
        let ux = Int64(Int32(clamping: x))
        let uy = Int64(UInt32(bitPattern: Int32(clamping: y)))
        return (ux << 32) | uy
    }

    private static func unpack(_ packed: Int64) -> (Int, Int) {
        let x = Int(Int32(truncatingIfNeeded: packed >> 32))
        let y = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: packed & 0xFFFF_FFFF)))
        return (x, y)
    }

    /// Fast query: check if a coordinate is explored in the **finest** grid.
    func isExplored(coordinate: CLLocationCoordinate2D) -> Bool {
        let mp = MKMapPoint(coordinate)
        let x = Int(floor(mp.x / baseCellMeters))
        let y = Int(floor(mp.y / baseCellMeters))
        return exploredFinePacked.contains(Self.pack(x: x, y: y))
    }

    // MARK: - Persistence

    private static func load(key: String) -> Set<Int64> {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let decoded = try? JSONDecoder().decode([Int64].self, from: data) {
            return Set(decoded)
        }
        return []
    }

    private static func save(_ set: Set<Int64>, key: String) {
        // Save as array to keep JSON stable.
        let arr = Array(set)
        guard let data = try? JSONEncoder().encode(arr) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
