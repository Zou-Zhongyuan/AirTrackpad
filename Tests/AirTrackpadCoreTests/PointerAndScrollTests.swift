import CoreGraphics
import Foundation
import Testing
@testable import AirTrackpadCore

@Suite("Pointer and Scroll")
struct PointerAndScrollTests {
    @Test func pointerAccelerationLinearAndCurve() {
        let linear = PointerMath.applyAcceleration(dx: 12.5, dy: -4.0, accelerate: false)
        #expect(abs(linear.dx - 12.5) < 1e-9)
        #expect(abs(linear.dy - (-4.0)) < 1e-9)

        let slow = PointerMath.applyAcceleration(dx: 0.4, dy: 0.0, accelerate: true)
        #expect(slow.dx > 0)
        #expect(slow.dx <= 0.4)

        let fast = PointerMath.applyAcceleration(dx: 30.0, dy: 0.0, accelerate: true)
        #expect(fast.dx > 30.0)
        #expect(fast.dx <= 30.0 * 3.5 + 1e-6)

        // Preserves vector direction
        let diag = PointerMath.applyAcceleration(dx: 6.0, dy: -8.0, accelerate: true)
        #expect(abs((diag.dx / diag.dy) - (6.0 / -8.0)) < 1e-9)

        // Non-finite inputs become zero
        let invalid = PointerMath.applyAcceleration(dx: .nan, dy: .infinity, accelerate: true)
        #expect(invalid.dx == 0)
        #expect(invalid.dy == 0)
    }

    @Test func multiDisplayClampingWithNegativeCoordinates() {
        let main = ScreenRect(minX: 0, minY: 0, width: 1920, height: 1080)
        let leftNegative = ScreenRect(minX: -1440, minY: 0, width: 1440, height: 900)
        let screens = [main, leftNegative]

        #expect(PointerMath.clampPoint(CGPoint(x: 500, y: 500), within: screens) == CGPoint(x: 500, y: 500))
        #expect(PointerMath.clampPoint(CGPoint(x: -200, y: 400), within: screens) == CGPoint(x: -200, y: 400))
        #expect(PointerMath.clampPoint(CGPoint(x: -1500, y: 400), within: screens) == CGPoint(x: -1440, y: 400))
        #expect(PointerMath.clampPoint(CGPoint(x: 2000, y: 1200), within: screens) == CGPoint(x: 1919, y: 1079))

        // L-shaped dead zone snaps to closest valid display
        #expect(PointerMath.clampPoint(CGPoint(x: -5, y: 1000), within: screens) == CGPoint(x: 0, y: 1000))
        #expect(PointerMath.clampPoint(CGPoint(x: -500, y: 950), within: screens) == CGPoint(x: -500, y: 899))

        // Non-finite point falls back to primary center
        #expect(PointerMath.clampPoint(CGPoint(x: Double.nan, y: 100), within: screens) == CGPoint(x: 960, y: 540))
    }

    @Test func scrollAccumulatorPreservesSubpixelDeltas() {
        var acc = ScrollAccumulator()
        var totalX: Int32 = 0
        var totalY: Int32 = 0

        for _ in 0..<10 {
            let (dx, dy) = acc.accumulate(dx: 0.3, dy: -0.45)
            totalX += dx
            totalY += dy
        }

        #expect(totalX == 3)
        #expect(totalY == -4)
        #expect(abs(acc.remainderX) < 1e-9)
        #expect(abs(acc.remainderY - (-0.5)) < 1e-9)

        let nonFinite = acc.accumulate(dx: .nan, dy: .infinity)
        #expect(nonFinite.dx == 0)
        #expect(nonFinite.dy == 0)

        acc.reset()
        #expect(acc.remainderX == 0)
        #expect(acc.remainderY == 0)
    }

    @Test func scrollDirectionAndMomentumDecay() {
        let natural = ScrollAccumulator.applyDirection(dx: -10, dy: -20, natural: true)
        #expect(natural.dx == -10)
        #expect(natural.dy == -20)

        let traditional = ScrollAccumulator.applyDirection(dx: -10, dy: -20, natural: false)
        #expect(traditional.dx == 10)
        #expect(traditional.dy == 20)

        var momentum = MomentumScrollerState(vx: 0, vy: -1200, natural: true)
        var acc = ScrollAccumulator()
        var steps = 0
        var totalDy: Int32 = 0

        while let delta = momentum.step() {
            steps += 1
            let (_, iy) = acc.accumulate(dx: delta.dx, dy: delta.dy)
            totalDy += iy
        }

        #expect(steps > 20)
        #expect(steps < 400)
        #expect(totalDy < -200)
        #expect(!momentum.isActive)
    }

    @Test func protocolDecodingAndValidation() throws {
        let validCases: [(String, IncomingMessage)] = [
            (#"{"t":"move","dx":2.5,"dy":-1.5,"accelerate":false}"#, .move(dx: 2.5, dy: -1.5, accelerate: false)),
            (#"{"t":"click","count":2}"#, .click(count: 2)),
            (#"{"t":"click","count":99}"#, .click(count: 3)),
            (#"{"t":"rightClick"}"#, .rightClick),
            (#"{"t":"scrollBegin"}"#, .scrollBegin),
            (#"{"t":"scroll","dx":1,"dy":-3,"natural":true}"#, .scroll(dx: 1, dy: -3, natural: true)),
            (#"{"t":"scrollEnd","vx":0,"vy":500,"natural":false}"#, .scrollEnd(vx: 0, vy: 500, natural: false)),
            (#"{"t":"scrollCancel"}"#, .scrollCancel),
            (#"{"t":"dragStart"}"#, .dragStart),
            (#"{"t":"dragMove","dx":4,"dy":5}"#, .dragMove(dx: 4, dy: 5, accelerate: true)),
            (#"{"t":"dragEnd"}"#, .dragEnd),
            (#"{"t":"pinchBegin"}"#, .pinchBegin),
            (#"{"t":"pinch","delta":0.12}"#, .pinch(delta: 0.12)),
            (#"{"t":"pinchEnd"}"#, .pinchEnd),
            (#"{"t":"swipe4","dir":"left","naturalSpaces":true}"#, .swipe4(dir: .left, naturalSpaces: true)),
            (#"{"t":"spread4"}"#, .spread4),
            (#"{"t":"pinch4"}"#, .pinch4),
            (#"{"t":"lookup"}"#, .lookup),
            (#"{"t":"ping","ts":123.5}"#, .ping(ts: 123.5))
        ]

        for (json, expected) in validCases {
            let decoded = try IncomingMessage.decode(from: Data(json.utf8))
            #expect(decoded == expected)
        }

        #expect(throws: ProtocolError.unknownMessageType("unknown")) {
            try IncomingMessage.decode(from: Data(#"{"t":"unknown"}"#.utf8))
        }
        #expect(throws: ProtocolError.missingField("dy")) {
            try IncomingMessage.decode(from: Data(#"{"t":"move","dx":1}"#.utf8))
        }
        #expect(throws: ProtocolError.invalidValue("dir")) {
            try IncomingMessage.decode(from: Data(#"{"t":"swipe4","dir":"diag"}"#.utf8))
        }
        #expect(throws: ProtocolError.invalidJSON) {
            try IncomingMessage.decode(from: Data("not json".utf8))
        }
    }
}
