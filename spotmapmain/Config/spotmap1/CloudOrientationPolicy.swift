import SceneKit

enum CloudOrientationPolicy {
    case fixed
    case yawOnly
    case billboard

    static let current: CloudOrientationPolicy = .fixed
    static let facingYawOffset: Float = .pi / 18

    func yawRadians(seed: UInt64) -> Float? {
        switch self {
        case .fixed:
            return Self.facingYawOffset
        case .yawOnly:
            let baseYaw = Self.baseYaw(seed: seed)
            return Self.wrapRadians(baseYaw + Self.facingYawOffset)
        case .billboard:
            return nil
        }
    }

    func apply(to node: SCNNode, seed: UInt64) {
        switch self {
        case .billboard:
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = [.Y]
            let remaining = node.constraints?.filter { !($0 is SCNBillboardConstraint) } ?? []
            node.constraints = remaining + [billboard]
            node.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        case .fixed, .yawOnly:
            if let yaw = yawRadians(seed: seed) {
                node.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            }
            node.constraints = node.constraints?.filter { !($0 is SCNBillboardConstraint) }
        }
    }

    private static func baseYaw(seed: UInt64) -> Float {
        Float((Double(seed & 0xFFFF) / 65535.0) * 2.0 * .pi)
    }

    private static func wrapRadians(_ a: Float) -> Float {
        var x = a
        let twoPi: Float = 2 * .pi
        x = fmodf(x + .pi, twoPi)
        if x < 0 { x += twoPi }
        return x - .pi
    }
}
