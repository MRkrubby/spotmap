import Foundation
import MapKit

/// Lightweight procedural wind + pressure field.
///
/// Goals:
/// - Coherent movement (no jitter).
/// - Deterministic wrt map position.
/// - Cheap to sample for dozens/hundreds of cloud objects.
///
/// Notes:
/// - MapKit's `MKMapPoint` uses meters in WebMercator space, which is perfect for this.
struct WindField {
    struct Sample {
        /// Wind vector in meters/second.
        let vx: Double
        let vy: Double
        /// Pressure scalar (roughly -1...1).
        let pressure: Double
    }

    /// Base wind direction (radians), used as the dominant drift.
    /// You can later hook this to real weather if desired.
    var baseDirectionRad: Double

    /// Base wind speed (m/s).
    var baseSpeed: Double

    /// How "swirly" the wind is.
    var turbulence: Double

    init(baseDirectionRad: Double = .pi * 0.18, baseSpeed: Double = 3.2, turbulence: Double = 0.55) {
        self.baseDirectionRad = baseDirectionRad
        self.baseSpeed = baseSpeed
        self.turbulence = turbulence
    }

    /// Sample wind and pressure at world position/time.
    func sample(at mp: MKMapPoint, time: TimeInterval) -> Sample {
        // Scale the world so the noise has large, pleasant blobs.
        let scale = 1.0 / 2200.0
        let x = mp.x * scale
        let y = mp.y * scale

        // Time scale keeps the field evolving slowly.
        let t = time * 0.025

        // Pressure noise (smooth fBm).
        let p = fbm(x: x + t * 0.12, y: y - t * 0.08, octaves: 4)

        // Curl-ish perturbation using gradient of another noise.
        // This gives nice lateral motion without hard discontinuities.
        let n = fbm(x: x - t * 0.10, y: y + t * 0.14, octaves: 3)
        let eps = 0.025
        let nx1 = fbm(x: x + eps - t * 0.10, y: y + t * 0.14, octaves: 3)
        let nx0 = fbm(x: x - eps - t * 0.10, y: y + t * 0.14, octaves: 3)
        let ny1 = fbm(x: x - t * 0.10, y: y + eps + t * 0.14, octaves: 3)
        let ny0 = fbm(x: x - t * 0.10, y: y - eps + t * 0.14, octaves: 3)

        let dndx = (nx1 - nx0) / (2 * eps)
        let dndy = (ny1 - ny0) / (2 * eps)

        // Rotate gradient to get curl-like field.
        let cx = -dndy
        let cy = dndx

        // Base wind.
        let bx = cos(baseDirectionRad)
        let by = sin(baseDirectionRad)

        // Speed modulation using pressure and noise.
        let speed = baseSpeed * (0.80 + 0.25 * clamp01(0.5 + 0.5 * p) + 0.10 * clamp01(0.5 + 0.5 * n))

        // Combine base + curl perturbation.
        let vx = bx * speed + cx * speed * turbulence
        let vy = by * speed + cy * speed * turbulence

        return Sample(vx: vx, vy: vy, pressure: p)
    }

    // MARK: - Noise

    private func fbm(x: Double, y: Double, octaves: Int) -> Double {
        var sum = 0.0
        var amp = 0.55
        var freq = 1.0
        var norm = 0.0

        for _ in 0..<max(1, octaves) {
            sum += amp * noise(x: x * freq, y: y * freq)
            norm += amp
            amp *= 0.5
            freq *= 2.0
        }

        return (norm > 0) ? (sum / norm) : 0
    }

    /// Value noise in -1...1.
    private func noise(x: Double, y: Double) -> Double {
        let xi = Int(floor(x))
        let yi = Int(floor(y))
        let xf = x - Double(xi)
        let yf = y - Double(yi)

        let v00 = hashToUnit(x: xi, y: yi)
        let v10 = hashToUnit(x: xi + 1, y: yi)
        let v01 = hashToUnit(x: xi, y: yi + 1)
        let v11 = hashToUnit(x: xi + 1, y: yi + 1)

        let u = smoothstep(xf)
        let v = smoothstep(yf)

        let x1 = lerp(v00, v10, u)
        let x2 = lerp(v01, v11, u)
        return lerp(x1, x2, v)
    }

    private func hashToUnit(x: Int, y: Int) -> Double {
        // 32-bit mix -> [0,1] -> [-1,1]
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xBF58476D1CE4E5B9
        h ^= (h >> 30)
        h &*= 0x94D049BB133111EB
        h ^= (h >> 31)
        let u = Double(h & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
        return (u * 2.0) - 1.0
    }

    private func smoothstep(_ t: Double) -> Double {
        // 3t^2 - 2t^3
        return t * t * (3.0 - 2.0 * t)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }
}
