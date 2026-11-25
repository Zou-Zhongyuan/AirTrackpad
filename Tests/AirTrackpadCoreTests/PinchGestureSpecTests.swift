import Foundation
import Testing
@testable import AirTrackpadCore

@Suite("Pinch Gesture WindowServer Safety")
struct PinchGestureSpecTests {
    @Test func rejectsSkyLightAssertionCrashCombinations() {
        let unsafeEvents: [Type29GestureEvent] = [
            Type29GestureEvent(f110: 61, f113: nil, f132: 1),
            Type29GestureEvent(f110: 61, f113: nil, f132: 0x80),
            Type29GestureEvent(f110: 8, f113: 0.0, f132: 0x81),
            Type29GestureEvent(f110: 62, f113: nil, f132: 4),
            Type29GestureEvent(f110: 62, f113: nil, f132: 8),
            Type29GestureEvent(f110: 60, f113: nil, f132: 4),
            Type29GestureEvent(f110: 8, f113: 0.0, f132: 0x0c),
            Type29GestureEvent(f110: 61, f113: nil, f132: 4),
            Type29GestureEvent(f110: 62, f113: nil, f132: 1),
            Type29GestureEvent(f110: 8, f113: .nan, f132: 2),
            Type29GestureEvent(f110: 8, f113: 0.1, f132: 2, iohidScale: 0, iohidPhase: 2)
        ]

        for event in unsafeEvents {
            #expect(!event.isSafeForWindowServer)
            #expect(event.gestureDepthDelta == 0)
        }
    }

    @Test func allPinchSequencesAreSafeAndBalanced() {
        for engine in PinchEngine.allCases {
            for hasIOHID in [false, true] {
                let begin = PinchGestureSequence.beginEvents(
                    engine: engine,
                    hasIOHIDScaleSupport: hasIOHID
                )
                let changeUp = PinchGestureSequence.changeEvents(
                    delta: 0.05,
                    engine: engine,
                    hasIOHIDScaleSupport: hasIOHID
                )
                let changeDown = PinchGestureSequence.changeEvents(
                    delta: -0.03,
                    engine: engine,
                    hasIOHIDScaleSupport: hasIOHID
                )
                let end = PinchGestureSequence.endEvents(
                    engine: engine,
                    hasIOHIDScaleSupport: hasIOHID
                )

                if engine == .shortcutFallback {
                    #expect(begin.isEmpty)
                    #expect(changeUp.isEmpty)
                    #expect(changeDown.isEmpty)
                    #expect(end.isEmpty)
                    continue
                }

                let sequence = begin + changeUp + changeDown + end
                #expect(sequence.count == 6)

                var depth = 0
                var maxDepth = 0
                for event in sequence {
                    #expect(event.isSafeForWindowServer)
                    if event.f110 == 61 || event.f110 == 62 {
                        #expect(event.f132 == 0)
                    }
                    depth += event.gestureDepthDelta
                    #expect(depth >= 0)
                    maxDepth = max(maxDepth, depth)
                }

                #expect(maxDepth == 2)
                #expect(depth == 0)

                for invalidDelta in [Double.nan, .infinity, -.infinity] {
                    let invalid = PinchGestureSequence.changeEvents(
                        delta: invalidDelta,
                        engine: engine,
                        hasIOHIDScaleSupport: hasIOHID
                    )
                    #expect(invalid.isEmpty)
                }
            }
        }
    }
}
