import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import AirTrackpadCore

public final class InputSynthesizer: @unchecked Sendable {
    private final class DynamicSymbols: @unchecked Sendable {
        typealias CoreDockSendNotificationFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
        typealias CGSGetSymbolicHotKeyValueFn = @convention(c) (
            Int32,
            UnsafeMutablePointer<UInt16>,
            UnsafeMutablePointer<UInt16>,
            UnsafeMutablePointer<UInt32>
        ) -> Int32
        typealias CGSIsSymbolicHotKeyEnabledFn = @convention(c) (Int32) -> Bool
        typealias IOHIDEventCreateScaleEventFn = @convention(c) (
            CFAllocator?,
            UInt64,
            Double,
            Double,
            Double,
            UInt32
        ) -> Unmanaged<CFTypeRef>?
        typealias IOHIDEventSetPhaseFn = @convention(c) (CFTypeRef, UInt32) -> Void
        typealias SLEventSetIOHIDEventFn = @convention(c) (CGEvent, CFTypeRef) -> Void

        let coreDockSendNotification: CoreDockSendNotificationFn?
        let getSymbolicHotKeyValue: CGSGetSymbolicHotKeyValueFn?
        let isSymbolicHotKeyEnabled: CGSIsSymbolicHotKeyEnabledFn?
        let createScaleEvent: IOHIDEventCreateScaleEventFn?
        let setIOHIDPhase: IOHIDEventSetPhaseFn?
        let setSLEventIOHIDEvent: SLEventSetIOHIDEventFn?

        var hasIOHIDScaleSupport: Bool {
            createScaleEvent != nil && setIOHIDPhase != nil && setSLEventIOHIDEvent != nil
        }

        init() {
            let appServices = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                RTLD_LAZY
            )
            let ioKit = dlopen(
                "/System/Library/Frameworks/IOKit.framework/IOKit",
                RTLD_LAZY
            )
            let skyLight = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                RTLD_LAZY
            )

            if let sym = appServices.flatMap({ dlsym($0, "CoreDockSendNotification") }) {
                self.coreDockSendNotification = unsafeBitCast(sym, to: CoreDockSendNotificationFn.self)
            } else {
                self.coreDockSendNotification = nil
            }

            if let sym = appServices.flatMap({ dlsym($0, "CGSGetSymbolicHotKeyValue") }) {
                self.getSymbolicHotKeyValue = unsafeBitCast(sym, to: CGSGetSymbolicHotKeyValueFn.self)
            } else {
                self.getSymbolicHotKeyValue = nil
            }

            if let sym = appServices.flatMap({ dlsym($0, "CGSIsSymbolicHotKeyEnabled") }) {
                self.isSymbolicHotKeyEnabled = unsafeBitCast(sym, to: CGSIsSymbolicHotKeyEnabledFn.self)
            } else {
                self.isSymbolicHotKeyEnabled = nil
            }

            if let sym = ioKit.flatMap({ dlsym($0, "IOHIDEventCreateScaleEvent") }) {
                self.createScaleEvent = unsafeBitCast(sym, to: IOHIDEventCreateScaleEventFn.self)
            } else {
                self.createScaleEvent = nil
            }

            if let sym = ioKit.flatMap({ dlsym($0, "IOHIDEventSetPhase") }) {
                self.setIOHIDPhase = unsafeBitCast(sym, to: IOHIDEventSetPhaseFn.self)
            } else {
                self.setIOHIDPhase = nil
            }

            if let sym = skyLight.flatMap({ dlsym($0, "SLEventSetIOHIDEvent") }) {
                self.setSLEventIOHIDEvent = unsafeBitCast(sym, to: SLEventSetIOHIDEventFn.self)
            } else {
                self.setSLEventIOHIDEvent = nil
            }
        }
    }

    private static let localClientID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private let queue = DispatchQueue(label: "com.airtrackpad.input-synthesizer", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .privateState)
    private let symbols = DynamicSymbols()

    private var currentPinchEngine: PinchEngine = .nativeType29
    private var eventNumber: Int64 = 100
    private var isDragging = false
    private var dragEventNumber: Int64 = 0
    private var dragOwner: UUID?

    private var trackedCursor: CGPoint?
    private var lastObservedSystemCursor: CGPoint?
    private var lastCursorPostUptimeNs: UInt64 = 0
    private var pointerDeltaAccumulator = ScrollAccumulator()

    private var scrollAccumulator = ScrollAccumulator()
    private var scrollPhaseActive = false
    private var scrollOwner: UUID?
    private var lastNaturalScroll = true
    private var momentumTimer: DispatchSourceTimer?
    private var momentumState: MomentumScrollerState?
    private var momentumBegan = false

    private var isPinching = false
    private var pinchOwner: UUID?
    private var shortcutAccumulatedDelta: Double = 0

    public init(pinchEngine: PinchEngine = .nativeType29) {
        self.currentPinchEngine = pinchEngine
    }

    public func setPinchEngine(_ engine: PinchEngine) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isPinching && self.currentPinchEngine != engine {
                self.pinchEndLocked()
            }
            self.currentPinchEngine = engine
        }
    }

    public func handle(_ message: IncomingMessage, from clientID: UUID? = nil) {
        let resolvedClientID = clientID ?? Self.localClientID
        queue.async { [weak self] in
            self?.processLocked(message, clientID: resolvedClientID)
        }
    }

    public func clientDisconnected(_ clientID: UUID) {
        queue.async { [weak self] in
            self?.releaseClientHeldStateLocked(clientID)
        }
    }

    public func releaseAllHeldState() {
        queue.sync {
            releaseAllHeldStateLocked()
        }
    }

    public func runSelfTest(_ action: SelfTestAction) {
        queue.async { [weak self] in
            guard let self else { return }
            switch action {
            case .missionControl:
                self.triggerMissionControlLocked()
            case .appExpose:
                self.triggerAppExposeLocked()
            case .showDesktop:
                self.triggerShowDesktopLocked()
            case .launchpad:
                self.triggerLaunchpadLocked()
            case .spaceLeft:
                self.triggerSpaceLeftLocked()
            case .spaceRight:
                self.triggerSpaceRightLocked()
            case .lookup:
                self.triggerLookUpLocked()
            case .zoomIn:
                self.performSelfTestZoomLocked(deltaPerStep: 0.08)
            case .zoomOut:
                self.performSelfTestZoomLocked(deltaPerStep: -0.08)
            }
        }
    }

    public enum SelfTestAction: Sendable {
        case missionControl
        case appExpose
        case showDesktop
        case launchpad
        case spaceLeft
        case spaceRight
        case lookup
        case zoomIn
        case zoomOut
    }

    private func processLocked(_ message: IncomingMessage, clientID: UUID) {
        switch message {
        case .move(let dx, let dy, let accelerate):
            cancelMomentumLocked()
            movePointerLocked(dx: dx, dy: dy, accelerate: accelerate)

        case .click(let count):
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            clickLocked(count: count)

        case .rightClick:
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            rightClickLocked()

        case .scrollBegin:
            if isDragging {
                dragEndLocked()
            }
            scrollBeginLocked(clientID: clientID)

        case .scroll(let dx, let dy, let natural):
            scrollLocked(dx: dx, dy: dy, natural: natural, clientID: clientID)

        case .scrollEnd(let vx, let vy, let natural):
            scrollEndLocked(vx: vx, vy: vy, natural: natural, clientID: clientID)

        case .scrollCancel:
            scrollCancelLocked()

        case .dragStart:
            cancelMomentumLocked()
            dragStartLocked(clientID: clientID)

        case .dragMove(let dx, let dy, let accelerate):
            dragMoveLocked(dx: dx, dy: dy, accelerate: accelerate)

        case .dragEnd:
            dragEndLocked()

        case .pinchBegin:
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            pinchBeginLocked(clientID: clientID)

        case .pinch(let delta):
            pinchLocked(delta: delta, clientID: clientID)

        case .pinchEnd:
            pinchEndLocked()

        case .swipe4(let dir, let naturalSpaces):
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            switch dir {
            case .left:
                if naturalSpaces {
                    triggerSpaceRightLocked()
                } else {
                    triggerSpaceLeftLocked()
                }
            case .right:
                if naturalSpaces {
                    triggerSpaceLeftLocked()
                } else {
                    triggerSpaceRightLocked()
                }
            case .up:
                triggerMissionControlLocked()
            case .down:
                triggerAppExposeLocked()
            }

        case .spread4:
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            triggerShowDesktopLocked()

        case .pinch4:
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            triggerLaunchpadLocked()

        case .lookup:
            cancelMomentumLocked()
            if isDragging {
                dragEndLocked()
            }
            triggerLookUpLocked()

        case .ping:
            break
        }
    }

    private func releaseClientHeldStateLocked(_ clientID: UUID) {
        if dragOwner == clientID {
            dragEndLocked()
        }
        if scrollOwner == clientID {
            scrollCancelLocked()
        }
        if pinchOwner == clientID {
            pinchEndLocked()
        }
    }

    private func releaseAllHeldStateLocked() {
        dragEndLocked()
        scrollCancelLocked()
        pinchEndLocked()
    }

    private func nextEventNumber() -> Int64 {
        eventNumber += 1
        return eventNumber
    }

    private func resolveCursorLocked(maxStaleNs: UInt64 = 30_000_000) -> CGPoint {
        let sys = CGEvent(source: nil)?.location ?? .zero
        let nowNs = DispatchTime.now().uptimeNanoseconds

        guard let tracked = trackedCursor,
              let lastSys = lastObservedSystemCursor,
              nowNs >= lastCursorPostUptimeNs,
              (nowNs - lastCursorPostUptimeNs) <= maxStaleNs else {
            trackedCursor = sys
            lastObservedSystemCursor = sys
            return sys
        }

        let movedFromTracked = hypot(Double(sys.x - tracked.x), Double(sys.y - tracked.y))
        let movedFromLastSys = hypot(Double(sys.x - lastSys.x), Double(sys.y - lastSys.y))
        if movedFromTracked > 3.0 && movedFromLastSys > 1.0 {
            trackedCursor = sys
            lastObservedSystemCursor = sys
            return sys
        }

        lastObservedSystemCursor = sys
        return tracked
    }

    private func activeScreenRects() -> [ScreenRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }
        return displayIDs.prefix(Int(count)).map { id in
            ScreenRect(CGDisplayBounds(id))
        }
    }

    // MARK: - Pointer & Click

    private func movePointerLocked(dx: Double, dy: Double, accelerate: Bool) {
        let (adx, ady) = PointerMath.applyAcceleration(dx: dx, dy: dy, accelerate: accelerate)
        let current = resolveCursorLocked(maxStaleNs: 120_000_000)
        let next = PointerMath.clampPoint(
            CGPoint(x: Double(current.x) + adx, y: Double(current.y) + ady),
            within: activeScreenRects()
        )
        trackedCursor = next
        lastCursorPostUptimeNs = DispatchTime.now().uptimeNanoseconds

        let (deltaX, deltaY) = pointerDeltaAccumulator.accumulate(
            dx: Double(next.x - current.x),
            dy: Double(next.y - current.y)
        )

        guard let ev = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: next,
            mouseButton: .left
        ) else { return }

        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
        ev.post(tap: .cghidEventTap)
    }

    private func clickLocked(count: Int) {
        let clampedCount = Int64(min(3, max(1, count)))
        let pos = resolveCursorLocked()
        let num = nextEventNumber()

        if let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: pos,
            mouseButton: .left
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: clampedCount)
            down.setIntegerValueField(.mouseEventNumber, value: num)
            down.post(tap: .cghidEventTap)
        }

        if let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: pos,
            mouseButton: .left
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: clampedCount)
            up.setIntegerValueField(.mouseEventNumber, value: num)
            up.post(tap: .cghidEventTap)
        }
    }

    private func rightClickLocked() {
        let pos = resolveCursorLocked()
        let num = nextEventNumber()

        if let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .rightMouseDown,
            mouseCursorPosition: pos,
            mouseButton: .right
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.setIntegerValueField(.mouseEventNumber, value: num)
            down.post(tap: .cghidEventTap)
        }

        if let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .rightMouseUp,
            mouseCursorPosition: pos,
            mouseButton: .right
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventNumber, value: num)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 3-Finger Drag

    private func dragStartLocked(clientID: UUID) {
        guard !isDragging else { return }
        isDragging = true
        dragOwner = clientID
        dragEventNumber = nextEventNumber()
        let pos = resolveCursorLocked()

        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: pos,
            mouseButton: .left
        ) else { return }

        // Explicit clickState = 1 prevents unintended double-click selection after a prior tap
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.mouseEventNumber, value: dragEventNumber)
        down.post(tap: .cghidEventTap)
    }

    private func dragMoveLocked(dx: Double, dy: Double, accelerate: Bool) {
        guard isDragging else { return }
        let (adx, ady) = PointerMath.applyAcceleration(dx: dx, dy: dy, accelerate: accelerate)
        let current = resolveCursorLocked(maxStaleNs: 120_000_000)
        let next = PointerMath.clampPoint(
            CGPoint(x: Double(current.x) + adx, y: Double(current.y) + ady),
            within: activeScreenRects()
        )
        trackedCursor = next
        lastCursorPostUptimeNs = DispatchTime.now().uptimeNanoseconds

        let (deltaX, deltaY) = pointerDeltaAccumulator.accumulate(
            dx: Double(next.x - current.x),
            dy: Double(next.y - current.y)
        )

        guard let drag = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: next,
            mouseButton: .left
        ) else { return }

        drag.setIntegerValueField(.mouseEventClickState, value: 1)
        drag.setIntegerValueField(.mouseEventNumber, value: dragEventNumber)
        drag.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
        drag.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
        drag.post(tap: .cghidEventTap)
    }

    private func dragEndLocked() {
        guard isDragging else { return }
        isDragging = false
        dragOwner = nil
        let pos = resolveCursorLocked()

        guard let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: pos,
            mouseButton: .left
        ) else { return }

        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventNumber, value: dragEventNumber)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 2-Finger Scroll & 120Hz Inertia

    private func postScrollEvent(
        dx: Int32,
        dy: Int32,
        scrollPhase: Int64,
        momentumPhase: Int64,
        natural: Bool
    ) {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else { return }

        ev.location = resolveCursorLocked()
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        if let invertedField = CGEventField(rawValue: 137) {
            ev.setIntegerValueField(invertedField, value: natural ? 1 : 0)
        }
        ev.post(tap: .cgSessionEventTap)
    }

    private func scrollBeginLocked(clientID: UUID) {
        cancelMomentumLocked()
        scrollAccumulator.reset()
        scrollPhaseActive = true
        scrollOwner = clientID
        postScrollEvent(
            dx: 0,
            dy: 0,
            scrollPhase: Int64(CGScrollPhase.began.rawValue),
            momentumPhase: Int64(CGMomentumScrollPhase.none.rawValue),
            natural: lastNaturalScroll
        )
    }

    private func scrollLocked(dx: Double, dy: Double, natural: Bool, clientID: UUID) {
        cancelMomentumLocked()
        lastNaturalScroll = natural
        scrollOwner = clientID

        if !scrollPhaseActive {
            scrollPhaseActive = true
            scrollAccumulator.reset()
            postScrollEvent(
                dx: 0,
                dy: 0,
                scrollPhase: Int64(CGScrollPhase.began.rawValue),
                momentumPhase: Int64(CGMomentumScrollPhase.none.rawValue),
                natural: natural
            )
        }

        let signed = ScrollAccumulator.applyDirection(dx: dx, dy: dy, natural: natural)
        let (ix, iy) = scrollAccumulator.accumulate(dx: signed.dx, dy: signed.dy)
        guard ix != 0 || iy != 0 else { return }

        postScrollEvent(
            dx: ix,
            dy: iy,
            scrollPhase: Int64(CGScrollPhase.changed.rawValue),
            momentumPhase: Int64(CGMomentumScrollPhase.none.rawValue),
            natural: natural
        )
    }

    private func scrollEndLocked(vx: Double, vy: Double, natural: Bool, clientID: UUID) {
        lastNaturalScroll = natural
        if scrollPhaseActive {
            postScrollEvent(
                dx: 0,
                dy: 0,
                scrollPhase: Int64(CGScrollPhase.ended.rawValue),
                momentumPhase: Int64(CGMomentumScrollPhase.none.rawValue),
                natural: natural
            )
            scrollPhaseActive = false
        }

        let state = MomentumScrollerState(vx: vx, vy: vy, natural: natural)
        guard state.isActive else {
            scrollAccumulator.reset()
            scrollOwner = nil
            return
        }

        scrollAccumulator.reset()
        scrollOwner = clientID
        momentumState = state
        momentumBegan = false

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .nanoseconds(8_333_333), repeating: .nanoseconds(8_333_333))
        timer.setEventHandler { [weak self] in
            self?.momentumTickLocked()
        }
        momentumTimer = timer
        timer.resume()
    }

    private func momentumTickLocked() {
        guard var state = momentumState else {
            stopMomentumTimerLocked(emitEndIfBegan: false)
            return
        }

        guard let step = state.step() else {
            stopMomentumTimerLocked(emitEndIfBegan: true)
            return
        }
        momentumState = state

        let (ix, iy) = scrollAccumulator.accumulate(dx: step.dx, dy: step.dy)
        let phase: CGMomentumScrollPhase
        if !momentumBegan {
            momentumBegan = true
            phase = .begin
        } else {
            phase = .continuous
        }

        if ix != 0 || iy != 0 || phase == .begin {
            postScrollEvent(
                dx: ix,
                dy: iy,
                scrollPhase: 0,
                momentumPhase: Int64(phase.rawValue),
                natural: state.natural
            )
        }
    }

    private func cancelMomentumLocked() {
        stopMomentumTimerLocked(emitEndIfBegan: true)
    }

    private func stopMomentumTimerLocked(emitEndIfBegan: Bool) {
        momentumTimer?.cancel()
        momentumTimer = nil
        let natural = momentumState?.natural ?? lastNaturalScroll
        let hadBegun = momentumBegan
        momentumState = nil
        momentumBegan = false
        if !scrollPhaseActive {
            scrollOwner = nil
        }

        if emitEndIfBegan && hadBegun {
            postScrollEvent(
                dx: 0,
                dy: 0,
                scrollPhase: 0,
                momentumPhase: Int64(CGMomentumScrollPhase.end.rawValue),
                natural: natural
            )
        }
    }

    private func scrollCancelLocked() {
        if scrollPhaseActive {
            postScrollEvent(
                dx: 0,
                dy: 0,
                scrollPhase: Int64(CGScrollPhase.cancelled.rawValue),
                momentumPhase: Int64(CGMomentumScrollPhase.none.rawValue),
                natural: lastNaturalScroll
            )
            scrollPhaseActive = false
        }
        cancelMomentumLocked()
        scrollAccumulator.reset()
        scrollOwner = nil
    }

    // MARK: - Pinch-to-Zoom

    private func pinchBeginLocked(clientID: UUID) {
        guard !isPinching else { return }
        isPinching = true
        pinchOwner = clientID
        shortcutAccumulatedDelta = 0

        for spec in PinchGestureSequence.beginEvents(
            engine: currentPinchEngine,
            hasIOHIDScaleSupport: symbols.hasIOHIDScaleSupport
        ) {
            postType29PinchEvent(spec)
        }
    }

    private func pinchLocked(delta: Double, clientID: UUID) {
        guard delta.isFinite else { return }
        if !isPinching {
            pinchBeginLocked(clientID: clientID)
        }

        switch currentPinchEngine {
        case .nativeType29, .iohidScale:
            for spec in PinchGestureSequence.changeEvents(
                delta: delta,
                engine: currentPinchEngine,
                hasIOHIDScaleSupport: symbols.hasIOHIDScaleSupport
            ) {
                postType29PinchEvent(spec)
            }

        case .shortcutFallback:
            shortcutAccumulatedDelta += delta
            let stepThreshold = 0.08
            while shortcutAccumulatedDelta >= stepThreshold {
                shortcutAccumulatedDelta -= stepThreshold
                postKeyChordLocked(virtualKey: CGKeyCode(kVK_ANSI_Equal), flags: .maskCommand)
            }
            while shortcutAccumulatedDelta <= -stepThreshold {
                shortcutAccumulatedDelta += stepThreshold
                postKeyChordLocked(virtualKey: CGKeyCode(kVK_ANSI_Minus), flags: .maskCommand)
            }
        }
    }

    private func pinchEndLocked() {
        guard isPinching else { return }
        isPinching = false
        pinchOwner = nil
        shortcutAccumulatedDelta = 0

        for spec in PinchGestureSequence.endEvents(
            engine: currentPinchEngine,
            hasIOHIDScaleSupport: symbols.hasIOHIDScaleSupport
        ) {
            postType29PinchEvent(spec)
        }
    }

    private func postType29PinchEvent(_ spec: Type29GestureEvent) {
        guard spec.isSafeForWindowServer else { return }
        guard let ev = CGEvent(source: eventSource),
              let type29 = CGEventType(rawValue: 29) else { return }

        ev.type = type29
        ev.location = resolveCursorLocked()
        if let f55 = CGEventField(rawValue: 55) {
            ev.setIntegerValueField(f55, value: 29)
        }
        if let field110 = CGEventField(rawValue: 110) {
            ev.setIntegerValueField(field110, value: spec.f110)
        }
        if let f113 = spec.f113, let field113 = CGEventField(rawValue: 113) {
            ev.setDoubleValueField(field113, value: f113)
        }
        if let field132 = CGEventField(rawValue: 132) {
            ev.setIntegerValueField(field132, value: spec.f132)
        }

        if let iohidScale = spec.iohidScale,
           let iohidPhase = spec.iohidPhase,
           let createScale = symbols.createScaleEvent,
           let setPhase = symbols.setIOHIDPhase,
           let setSLEvent = symbols.setSLEventIOHIDEvent,
           let hidRef = createScale(kCFAllocatorDefault, mach_absolute_time(), iohidScale, 1.0, 1.0, 0)?.takeRetainedValue() {
            setPhase(hidRef, iohidPhase)
            setSLEvent(ev, hidRef)
        }

        ev.post(tap: .cgSessionEventTap)
    }

    private func performSelfTestZoomLocked(deltaPerStep: Double) {
        pinchBeginLocked(clientID: Self.localClientID)
        for step in 1...3 {
            queue.asyncAfter(deadline: .now() + .milliseconds(step * 25)) { [weak self] in
                self?.pinchLocked(delta: deltaPerStep, clientID: Self.localClientID)
            }
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(105)) { [weak self] in
            self?.pinchEndLocked()
        }
    }

    // MARK: - 4-Finger & Look Up System Gestures

    private func triggerMissionControlLocked() {
        if sendCoreDockNotification("com.apple.expose.awake") {
            return
        }
        if !openSystemApp(at: "/System/Applications/Mission Control.app") {
            triggerSymbolicHotKeyOrFallback(id: 32, fallbackKey: CGKeyCode(kVK_UpArrow), fallbackFlags: .maskControl)
        }
    }

    private func triggerAppExposeLocked() {
        if sendCoreDockNotification("com.apple.expose.front.awake") {
            return
        }
        triggerSymbolicHotKeyOrFallback(id: 33, fallbackKey: CGKeyCode(kVK_DownArrow), fallbackFlags: .maskControl)
    }

    private func triggerShowDesktopLocked() {
        if sendCoreDockNotification("com.apple.showdesktop.awake") {
            return
        }
        triggerSymbolicHotKeyOrFallback(id: 36, fallbackKey: CGKeyCode(kVK_F11), fallbackFlags: [])
    }

    private func triggerLaunchpadLocked() {
        if sendCoreDockNotification("com.apple.launchpad.toggle") {
            return
        }
        if openSystemApp(at: "/System/Applications/Apps.app") ||
            openSystemApp(at: "/System/Applications/Launchpad.app") {
            return
        }
        triggerSymbolicHotKeyOrFallback(id: 214, fallbackKey: CGKeyCode(kVK_F4), fallbackFlags: [])
    }

    private func triggerSpaceLeftLocked() {
        triggerSymbolicHotKeyOrFallback(id: 79, fallbackKey: CGKeyCode(kVK_LeftArrow), fallbackFlags: .maskControl)
    }

    private func triggerSpaceRightLocked() {
        triggerSymbolicHotKeyOrFallback(id: 81, fallbackKey: CGKeyCode(kVK_RightArrow), fallbackFlags: .maskControl)
    }

    private func triggerLookUpLocked() {
        triggerSymbolicHotKeyOrFallback(
            id: 70,
            fallbackKey: CGKeyCode(kVK_ANSI_D),
            fallbackFlags: [.maskControl, .maskCommand]
        )
    }

    private func sendCoreDockNotification(_ name: String) -> Bool {
        guard let fn = symbols.coreDockSendNotification else { return false }
        fn(name as CFString, nil)
        return true
    }

    private func openSystemApp(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        return true
    }

    private func triggerSymbolicHotKeyOrFallback(
        id: Int32,
        fallbackKey: CGKeyCode,
        fallbackFlags: CGEventFlags
    ) {
        if let getSHK = symbols.getSymbolicHotKeyValue {
            var keyChar: UInt16 = 0
            var keyCode: UInt16 = 0
            var rawModifiers: UInt32 = 0
            let err = getSHK(id, &keyChar, &keyCode, &rawModifiers)
            let enabled = symbols.isSymbolicHotKeyEnabled?(id) ?? true
            if err == 0 && enabled && keyCode != 0xFFFF {
                let flags = CGEventFlags(rawValue: UInt64(rawModifiers))
                postKeyChordLocked(virtualKey: CGKeyCode(keyCode), flags: flags)
                return
            }
        }
        postKeyChordLocked(virtualKey: fallbackKey, flags: fallbackFlags)
    }

    private func postKeyChordLocked(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
            (.maskControl, CGKeyCode(kVK_Control)),
            (.maskAlternate, CGKeyCode(kVK_Option)),
            (.maskShift, CGKeyCode(kVK_Shift)),
            (.maskCommand, CGKeyCode(kVK_Command))
        ]

        let activeModifiers = modifierKeys.filter { flags.contains($0.flag) }
        var runningFlags = CGEventFlags()
        if flags.contains(.maskSecondaryFn) {
            runningFlags.insert(.maskSecondaryFn)
        }
        if flags.contains(.maskNumericPad) {
            runningFlags.insert(.maskNumericPad)
        }

        // Explicit modifier keyDowns ensure WindowServer/Dock register shortcuts under .privateState
        for item in activeModifiers {
            runningFlags.insert(item.flag)
            if let modDown = CGEvent(keyboardEventSource: eventSource, virtualKey: item.keyCode, keyDown: true) {
                modDown.flags = runningFlags
                modDown.post(tap: .cghidEventTap)
            }
            usleep(4000)
        }

        if let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: true) {
            keyDown.flags = runningFlags
            keyDown.post(tap: .cghidEventTap)
        }
        usleep(6000)

        if let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: false) {
            keyUp.flags = runningFlags
            keyUp.post(tap: .cghidEventTap)
        }
        usleep(4000)

        for item in activeModifiers.reversed() {
            runningFlags.remove(item.flag)
            if let modUp = CGEvent(keyboardEventSource: eventSource, virtualKey: item.keyCode, keyDown: false) {
                modUp.flags = runningFlags
                modUp.post(tap: .cghidEventTap)
            }
            usleep(3000)
        }
    }
}
