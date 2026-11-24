import CoreGraphics
import Foundation

public struct ScreenRect: Sendable, Equatable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public init(_ cgRect: CGRect) {
        self.init(
            minX: Double(cgRect.origin.x),
            minY: Double(cgRect.origin.y),
            width: Double(cgRect.size.width),
            height: Double(cgRect.size.height)
        )
    }

    public func contains(_ point: CGPoint) -> Bool {
        guard width > 0, height > 0 else { return false }
        let x = Double(point.x)
        let y = Double(point.y)
        return x >= minX && x < maxX && y >= minY && y < maxY
    }

    public func clampedPoint(_ point: CGPoint) -> CGPoint {
        let upperX = width >= 1 ? maxX - 1 : minX
        let upperY = height >= 1 ? maxY - 1 : minY
        let cx = min(max(Double(point.x), minX), max(minX, upperX))
        let cy = min(max(Double(point.y), minY), max(minY, upperY))
        return CGPoint(x: cx, y: cy)
    }
}

public enum PointerMath {
    public static func accelerationGain(forSpeed speed: Double) -> Double {
        guard speed.isFinite, speed > 0 else { return 0 }
        if speed < 1.5 {
            // Precision band: smoothly scales from 0.85 to 1.0
            return 0.85 + 0.15 * (speed / 1.5)
        }
        // Trackpad curve: continuous at 1.5 (1.0), capped at 3.5x for fast flicks
        return min(3.5, 1.0 + 0.16 * pow(speed - 1.5, 0.78))
    }

    public static func applyAcceleration(
        dx: Double,
        dy: Double,
        accelerate: Bool
    ) -> (dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else {
            return (0, 0)
        }
        if !accelerate {
            return (dx, dy)
        }
        let speed = hypot(dx, dy)
        guard speed > 1e-6 else {
            return (0, 0)
        }
        let gain = accelerationGain(forSpeed: speed)
        return (dx * gain, dy * gain)
    }

    public static func clampPoint(_ point: CGPoint, within screens: [ScreenRect]) -> CGPoint {
        let validScreens = screens.filter { $0.width > 0 && $0.height > 0 }
        guard let first = validScreens.first else {
            return point
        }

        let px = Double(point.x)
        let py = Double(point.y)
        guard px.isFinite, py.isFinite else {
            return CGPoint(
                x: first.minX + first.width * 0.5,
                y: first.minY + first.height * 0.5
            )
        }

        if validScreens.contains(where: { $0.contains(point) }) {
            return point
        }

        var bestPoint = first.clampedPoint(point)
        var bestDistSq = Double.infinity

        for screen in validScreens {
            let candidate = screen.clampedPoint(point)
            let dx = Double(candidate.x) - px
            let dy = Double(candidate.y) - py
            let distSq = dx * dx + dy * dy
            if distSq < bestDistSq {
                bestDistSq = distSq
                bestPoint = candidate
            }
        }
        return bestPoint
    }
}
