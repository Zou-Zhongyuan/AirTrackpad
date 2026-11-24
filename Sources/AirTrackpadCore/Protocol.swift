import Foundation

public enum SwipeDirection: String, Codable, Sendable, Equatable {
    case left
    case right
    case up
    case down
}

public enum PinchEngine: String, Codable, CaseIterable, Sendable, Equatable, Identifiable {
    case nativeType29
    case iohidScale
    case shortcutFallback

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nativeType29:
            return "原生手势"
        case .iohidScale:
            return "IOHID 缩放"
        case .shortcutFallback:
            return "⌘+/⌘-"
        }
    }
}

public enum ProtocolError: Error, Equatable, Sendable {
    case invalidJSON
    case unknownMessageType(String)
    case missingField(String)
    case nonFiniteNumber(String)
    case invalidValue(String)
}

public enum IncomingMessage: Equatable, Sendable {
    case move(dx: Double, dy: Double, accelerate: Bool)
    case click(count: Int)
    case rightClick
    case scrollBegin
    case scroll(dx: Double, dy: Double, natural: Bool)
    case scrollEnd(vx: Double, vy: Double, natural: Bool)
    case scrollCancel
    case dragStart
    case dragMove(dx: Double, dy: Double, accelerate: Bool)
    case dragEnd
    case pinchBegin
    case pinch(delta: Double)
    case pinchEnd
    case swipe4(dir: SwipeDirection, naturalSpaces: Bool)
    case spread4
    case pinch4
    case lookup
    case ping(ts: Double?)

    private struct RawEnvelope: Decodable {
        let t: String
        let dx: Double?
        let dy: Double?
        let vx: Double?
        let vy: Double?
        let delta: Double?
        let count: Int?
        let accelerate: Bool?
        let accel: Bool?
        let natural: Bool?
        let naturalSpaces: Bool?
        let dir: String?
        let ts: Double?
    }

    public static func decode(from data: Data) throws -> IncomingMessage {
        let envelope: RawEnvelope
        do {
            envelope = try JSONDecoder().decode(RawEnvelope.self, from: data)
        } catch {
            throw ProtocolError.invalidJSON
        }

        func finite(_ value: Double?, field: String) throws -> Double {
            guard let value else { throw ProtocolError.missingField(field) }
            guard value.isFinite else { throw ProtocolError.nonFiniteNumber(field) }
            return value
        }

        switch envelope.t {
        case "move":
            let dx = try finite(envelope.dx, field: "dx")
            let dy = try finite(envelope.dy, field: "dy")
            let accel = envelope.accelerate ?? envelope.accel ?? true
            return .move(dx: dx, dy: dy, accelerate: accel)

        case "click":
            let rawCount = envelope.count ?? 1
            let count = min(3, max(1, rawCount))
            return .click(count: count)

        case "rightClick":
            return .rightClick

        case "scrollBegin":
            return .scrollBegin

        case "scroll":
            let dx = try finite(envelope.dx, field: "dx")
            let dy = try finite(envelope.dy, field: "dy")
            let natural = envelope.natural ?? true
            return .scroll(dx: dx, dy: dy, natural: natural)

        case "scrollEnd":
            let vx = try finite(envelope.vx ?? 0, field: "vx")
            let vy = try finite(envelope.vy ?? 0, field: "vy")
            let natural = envelope.natural ?? true
            return .scrollEnd(vx: vx, vy: vy, natural: natural)

        case "scrollCancel":
            return .scrollCancel

        case "dragStart":
            return .dragStart

        case "dragMove":
            let dx = try finite(envelope.dx, field: "dx")
            let dy = try finite(envelope.dy, field: "dy")
            let accel = envelope.accelerate ?? envelope.accel ?? true
            return .dragMove(dx: dx, dy: dy, accelerate: accel)

        case "dragEnd":
            return .dragEnd

        case "pinchBegin":
            return .pinchBegin

        case "pinch":
            let delta = try finite(envelope.delta, field: "delta")
            return .pinch(delta: delta)

        case "pinchEnd":
            return .pinchEnd

        case "swipe4":
            guard let dirRaw = envelope.dir else {
                throw ProtocolError.missingField("dir")
            }
            guard let dir = SwipeDirection(rawValue: dirRaw) else {
                throw ProtocolError.invalidValue("dir")
            }
            let naturalSpaces = envelope.naturalSpaces ?? envelope.natural ?? true
            return .swipe4(dir: dir, naturalSpaces: naturalSpaces)

        case "spread4":
            return .spread4

        case "pinch4":
            return .pinch4

        case "lookup":
            return .lookup

        case "ping":
            if let ts = envelope.ts, !ts.isFinite {
                throw ProtocolError.nonFiniteNumber("ts")
            }
            return .ping(ts: envelope.ts)

        default:
            throw ProtocolError.unknownMessageType(envelope.t)
        }
    }

    public var summaryLabel: String {
        switch self {
        case .move: return "光标移动"
        case .click(let count):
            switch count {
            case 2: return "双击"
            case 3: return "三击"
            default: return "左键轻点"
            }
        case .rightClick: return "双指右键"
        case .scrollBegin: return "开始滚动"
        case .scroll: return "双指滚动"
        case .scrollEnd: return "惯性滚动"
        case .scrollCancel: return "停止滚动"
        case .dragStart: return "三指拖动开始"
        case .dragMove: return "三指拖动"
        case .dragEnd: return "三指拖动释放"
        case .pinchBegin: return "双指缩放开始"
        case .pinch: return "双指缩放"
        case .pinchEnd: return "双指缩放结束"
        case .swipe4(let dir, _):
            switch dir {
            case .left: return "四指左滑"
            case .right: return "四指右滑"
            case .up: return "四指上滑（调度中心）"
            case .down: return "四指下滑（App Exposé）"
            }
        case .spread4: return "四指张开（显示桌面）"
        case .pinch4: return "四指捏合（启动台）"
        case .lookup: return "三指查词"
        case .ping: return "心跳"
        }
    }
}

public enum OutgoingMessage: Equatable, Sendable {
    case pong(ts: Double?)
    case hello(hostName: String, version: String)
    case error(message: String)

    public func encodeJSON() -> String {
        var dict: [String: Any] = [:]
        switch self {
        case .pong(let ts):
            dict["t"] = "pong"
            if let ts, ts.isFinite {
                dict["ts"] = ts
            }
        case .hello(let hostName, let version):
            dict["t"] = "hello"
            dict["host"] = hostName
            dict["version"] = version
        case .error(let message):
            dict["t"] = "error"
            dict["message"] = message
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"t":"error","message":"encode failure"}"#
        }
        return str
    }
}
