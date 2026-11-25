import Foundation

/// Specification for a macOS Type-29 (`NSEventTypeGesture`) CoreGraphics event
/// validated against SkyLight `WSGestureEventProcessor.mm` invariants.
public struct Type29GestureEvent: Equatable, Sendable {
    public let f110: Int64
    public let f113: Double?
    public let f132: Int64
    public let iohidScale: Double?
    public let iohidPhase: UInt32?

    public init(
        f110: Int64,
        f113: Double? = nil,
        f132: Int64,
        iohidScale: Double? = nil,
        iohidPhase: UInt32? = nil
    ) {
        self.f110 = f110
        self.f113 = f113
        self.f132 = f132
        self.iohidScale = iohidScale
        self.iohidPhase = iohidPhase
    }

    /// Returns `true` only when the subtype (`f110`) and phase (`f132`) satisfy all
    /// `consistent_focus_change`, `single_increase`, and `single_decrease` invariants
    /// enforced by `WSGestureEventProcessor` inside `WindowServer`.
    public var isSafeForWindowServer: Bool {
        if let f113, !f113.isFinite {
            return false
        }
        if let iohidScale, !(iohidScale.isFinite && iohidScale > 0) {
            return false
        }

        let phaseByte = UInt8(truncatingIfNeeded: f132)
        let isSubtypeBegin = (f110 == PinchGestureSequence.beginGestureSubtype)
        let isSubtypeEnd = (f110 == 60 || f110 == PinchGestureSequence.endGestureSubtype)
        let hasMayBegin = (phaseByte & 0x80) != 0
        let hasBegan = (phaseByte & 0x01) != 0
        let hasEnded = (phaseByte & 0x04) != 0
        let hasCancelled = (phaseByte & 0x08) != 0

        let isIncrease = isSubtypeBegin || hasMayBegin || hasBegan
        let isDecrease = isSubtypeEnd || hasEnded || hasCancelled

        if isIncrease && isDecrease {
            return false
        }
        if hasMayBegin && hasBegan {
            return false
        }
        if isSubtypeBegin && (hasMayBegin || hasBegan) {
            return false
        }
        if hasEnded && hasCancelled {
            return false
        }
        if isSubtypeEnd && (hasEnded || hasCancelled) {
            return false
        }
        return true
    }

    /// Net change to `WindowServer`'s active gesture depth counter for this event.
    public var gestureDepthDelta: Int {
        guard isSafeForWindowServer else { return 0 }
        let phaseByte = UInt8(truncatingIfNeeded: f132)
        if f110 == PinchGestureSequence.beginGestureSubtype || (phaseByte & 0x01) != 0 {
            return 1
        }
        if f110 == 60 || f110 == PinchGestureSequence.endGestureSubtype || (phaseByte & 0x0c) != 0 {
            return -1
        }
        return 0
    }
}

/// Generates balanced, WindowServer-safe Type-29 pinch gesture event sequences.
public enum PinchGestureSequence {
    public static let beginGestureSubtype: Int64 = 61
    public static let endGestureSubtype: Int64 = 62
    public static let magnifySubtype: Int64 = 8

    public static func beginEvents(
        engine: PinchEngine,
        hasIOHIDScaleSupport: Bool
    ) -> [Type29GestureEvent] {
        switch engine {
        case .nativeType29:
            return [
                Type29GestureEvent(f110: beginGestureSubtype, f113: nil, f132: 0),
                Type29GestureEvent(f110: magnifySubtype, f113: 0.0, f132: 1)
            ]
        case .iohidScale:
            if hasIOHIDScaleSupport {
                return [
                    Type29GestureEvent(f110: beginGestureSubtype, f113: nil, f132: 0),
                    Type29GestureEvent(
                        f110: magnifySubtype,
                        f113: 0.0,
                        f132: 1,
                        iohidScale: 1.0,
                        iohidPhase: 1
                    )
                ]
            }
            return beginEvents(engine: .nativeType29, hasIOHIDScaleSupport: false)
        case .shortcutFallback:
            return []
        }
    }

    public static func changeEvents(
        delta: Double,
        engine: PinchEngine,
        hasIOHIDScaleSupport: Bool
    ) -> [Type29GestureEvent] {
        guard delta.isFinite else { return [] }
        switch engine {
        case .nativeType29:
            return [
                Type29GestureEvent(f110: magnifySubtype, f113: delta, f132: 2)
            ]
        case .iohidScale:
            if hasIOHIDScaleSupport {
                let scale = max(0.2, 1.0 + delta)
                return [
                    Type29GestureEvent(
                        f110: magnifySubtype,
                        f113: delta,
                        f132: 2,
                        iohidScale: scale,
                        iohidPhase: 2
                    )
                ]
            }
            return changeEvents(delta: delta, engine: .nativeType29, hasIOHIDScaleSupport: false)
        case .shortcutFallback:
            return []
        }
    }

    public static func endEvents(
        engine: PinchEngine,
        hasIOHIDScaleSupport: Bool
    ) -> [Type29GestureEvent] {
        switch engine {
        case .nativeType29:
            return [
                Type29GestureEvent(f110: magnifySubtype, f113: 0.0, f132: 4),
                Type29GestureEvent(f110: endGestureSubtype, f113: nil, f132: 0)
            ]
        case .iohidScale:
            if hasIOHIDScaleSupport {
                return [
                    Type29GestureEvent(
                        f110: magnifySubtype,
                        f113: 0.0,
                        f132: 4,
                        iohidScale: 1.0,
                        iohidPhase: 4
                    ),
                    Type29GestureEvent(f110: endGestureSubtype, f113: nil, f132: 0)
                ]
            }
            return endEvents(engine: .nativeType29, hasIOHIDScaleSupport: false)
        case .shortcutFallback:
            return []
        }
    }
}
