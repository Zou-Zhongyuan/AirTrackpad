import Foundation

public struct ScrollAccumulator: Sendable, Equatable {
    public private(set) var remainderX: Double = 0
    public private(set) var remainderY: Double = 0

    public init() {}

    public mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    public mutating func accumulate(dx: Double, dy: Double) -> (dx: Int32, dy: Int32) {
        let ix = Self.extractIntegerDelta(input: dx, remainder: &remainderX)
        let iy = Self.extractIntegerDelta(input: dy, remainder: &remainderY)
        return (ix, iy)
    }

    private static func extractIntegerDelta(input: Double, remainder: inout Double) -> Int32 {
        guard input.isFinite else { return 0 }
        let total = remainder + input
        guard total.isFinite else {
            remainder = 0
            return 0
        }
        let snapped = abs(total - total.rounded()) < 1e-9 ? total.rounded() : total
        let truncated = snapped.rounded(.towardZero)
        let clamped = min(Double(Int32.max), max(Double(Int32.min), truncated))
        let intValue = Int32(clamped)
        remainder = total - Double(intValue)
        return intValue
    }

    public static func applyDirection(dx: Double, dy: Double, natural: Bool) -> (dx: Double, dy: Double) {
        let sx = dx.isFinite ? (natural ? dx : -dx) : 0
        let sy = dy.isFinite ? (natural ? dy : -dy) : 0
        return (sx, sy)
    }
}

public struct MomentumScrollerState: Sendable, Equatable {
    public private(set) var vx: Double
    public private(set) var vy: Double
    public private(set) var elapsed: Double = 0
    public let natural: Bool
    public let tickInterval: Double
    public let decayPerSecond: Double
    public let stopSpeedThreshold: Double
    public let maxDuration: Double

    public init(
        vx: Double,
        vy: Double,
        natural: Bool,
        tickInterval: Double = 1.0 / 120.0,
        decayPerSecond: Double = 3.6,
        stopSpeedThreshold: Double = 18.0,
        maxDuration: Double = 2.8
    ) {
        let signed = ScrollAccumulator.applyDirection(dx: vx, dy: vy, natural: natural)
        // Clamp extreme velocities (e.g. > 12000 px/s) to keep coasting comfortable
        let speed = hypot(signed.dx, signed.dy)
        let maxSpeed = 12000.0
        if speed > maxSpeed, speed > 0 {
            let scale = maxSpeed / speed
            self.vx = signed.dx * scale
            self.vy = signed.dy * scale
        } else {
            self.vx = signed.dx
            self.vy = signed.dy
        }
        self.natural = natural
        self.tickInterval = tickInterval
        self.decayPerSecond = decayPerSecond
        self.stopSpeedThreshold = stopSpeedThreshold
        self.maxDuration = maxDuration
    }

    public var isActive: Bool {
        hypot(vx, vy) >= stopSpeedThreshold && elapsed < maxDuration
    }

    public mutating func step() -> (dx: Double, dy: Double)? {
        guard isActive else { return nil }
        let dx = vx * tickInterval
        let dy = vy * tickInterval
        let decay = exp(-decayPerSecond * tickInterval)
        vx *= decay
        vy *= decay
        elapsed += tickInterval
        return (dx, dy)
    }
}
