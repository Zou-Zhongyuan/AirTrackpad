import CryptoKit
import Foundation

public enum WebSocketOpcode: UInt8, Sendable, Equatable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA

    public var isControl: Bool {
        rawValue >= 0x8
    }
}

public enum WebSocketFrameError: Error, Equatable, Sendable {
    case reservedBitsSet
    case unmaskedClientFrame
    case unknownOpcode(UInt8)
    case controlFrameFragmented
    case controlFrameTooLarge
    case payloadTooLarge
    case unexpectedContinuation
    case fragmentationInProgress
    case invalidUTF8
}

public enum WebSocketMessageEvent: Equatable, Sendable {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(code: UInt16?, reason: String)
}

public enum WebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func acceptKey(for clientKey: String) -> String {
        let trimmed = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = Data((trimmed + guid).utf8)
        let digest = Insecure.SHA1.hash(data: combined)
        return Data(digest).base64EncodedString()
    }
}

public enum WebSocketFrameEncoder {
    public static func encode(
        opcode: WebSocketOpcode,
        payload: Data = Data(),
        fin: Bool = true
    ) -> Data {
        encodeRaw(opcode: opcode, payload: payload, fin: fin, maskingKey: nil)
    }

    public static func encodeMasked(
        opcode: WebSocketOpcode,
        payload: Data = Data(),
        fin: Bool = true,
        maskingKey: [UInt8]? = nil
    ) -> Data {
        let key: [UInt8]
        if let maskingKey, maskingKey.count == 4 {
            key = maskingKey
        } else {
            key = [
                UInt8.random(in: 0...255),
                UInt8.random(in: 0...255),
                UInt8.random(in: 0...255),
                UInt8.random(in: 0...255)
            ]
        }
        return encodeRaw(opcode: opcode, payload: payload, fin: fin, maskingKey: key)
    }

    public static func encodeText(_ text: String, fin: Bool = true) -> Data {
        encode(opcode: .text, payload: Data(text.utf8), fin: fin)
    }

    public static func encodePing(payload: Data = Data()) -> Data {
        encode(opcode: .ping, payload: Data(payload.prefix(125)), fin: true)
    }

    public static func encodePong(payload: Data = Data()) -> Data {
        encode(opcode: .pong, payload: Data(payload.prefix(125)), fin: true)
    }

    public static func encodeClose(code: UInt16 = 1000, reason: String = "") -> Data {
        var payload = Data(capacity: 2 + reason.utf8.count)
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        let reasonBytes = Array(reason.utf8).prefix(123)
        payload.append(contentsOf: reasonBytes)
        return encode(opcode: .close, payload: payload, fin: true)
    }

    private static func encodeRaw(
        opcode: WebSocketOpcode,
        payload: Data,
        fin: Bool,
        maskingKey: [UInt8]?
    ) -> Data {
        var out = Data()
        let firstByte: UInt8 = (fin ? 0x80 : 0x00) | (opcode.rawValue & 0x0F)
        out.append(firstByte)

        let maskBit: UInt8 = maskingKey != nil ? 0x80 : 0x00
        let count = payload.count

        if count < 126 {
            out.append(maskBit | UInt8(count))
        } else if count <= Int(UInt16.max) {
            out.append(maskBit | 126)
            let len16 = UInt16(count)
            out.append(UInt8((len16 >> 8) & 0xFF))
            out.append(UInt8(len16 & 0xFF))
        } else {
            out.append(maskBit | 127)
            let len64 = UInt64(count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((len64 >> shift) & 0xFF))
            }
        }

        if let key = maskingKey {
            out.append(contentsOf: key)
            var masked = Data(count: count)
            masked.withUnsafeMutableBytes { dstRaw in
                payload.withUnsafeBytes { srcRaw in
                    guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                          let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<count {
                        dst[i] = src[i] ^ key[i & 3]
                    }
                }
            }
            out.append(masked)
        } else {
            out.append(payload)
        }

        return out
    }
}

public final class WebSocketFrameDecoder: @unchecked Sendable {
    public let requireMask: Bool
    public let maxPayloadSize: Int

    private var buffer = Data()
    private var readOffset = 0
    private var fragmentOpcode: WebSocketOpcode?
    private var fragmentBuffer = Data()

    public init(requireMask: Bool = true, maxPayloadSize: Int = 1_048_576) {
        self.requireMask = requireMask
        self.maxPayloadSize = maxPayloadSize
    }

    public var bufferedByteCount: Int {
        buffer.count - readOffset
    }

    public func append(_ data: Data) {
        if !data.isEmpty {
            buffer.append(data)
        }
    }

    public func drainEvents() throws -> [WebSocketMessageEvent] {
        var events: [WebSocketMessageEvent] = []
        while let event = try nextEvent() {
            events.append(event)
        }
        compactBufferIfNeeded()
        return events
    }

    private func nextEvent() throws -> WebSocketMessageEvent? {
        while true {
            let available = buffer.count - readOffset
            guard available >= 2 else {
                return nil
            }

            let b0 = buffer[readOffset]
            let b1 = buffer[readOffset + 1]

            let fin = (b0 & 0x80) != 0
            let rsv = (b0 & 0x70)
            guard rsv == 0 else {
                throw WebSocketFrameError.reservedBitsSet
            }

            let rawOpcode = b0 & 0x0F
            guard let opcode = WebSocketOpcode(rawValue: rawOpcode) else {
                throw WebSocketFrameError.unknownOpcode(rawOpcode)
            }

            let masked = (b1 & 0x80) != 0
            if requireMask && !masked {
                throw WebSocketFrameError.unmaskedClientFrame
            }

            if opcode.isControl && !fin {
                throw WebSocketFrameError.controlFrameFragmented
            }

            var cursor = readOffset + 2
            let len7 = Int(b1 & 0x7F)
            let payloadLength: Int

            if len7 < 126 {
                payloadLength = len7
            } else if len7 == 126 {
                guard buffer.count - cursor >= 2 else { return nil }
                let len16 = (Int(buffer[cursor]) << 8) | Int(buffer[cursor + 1])
                payloadLength = len16
                cursor += 2
            } else {
                guard buffer.count - cursor >= 8 else { return nil }
                var len64: UInt64 = 0
                for i in 0..<8 {
                    len64 = (len64 << 8) | UInt64(buffer[cursor + i])
                }
                // RFC 6455 §5.2: most significant bit of 64-bit length MUST be 0
                if (len64 & 0x8000_0000_0000_0000) != 0 || len64 > UInt64(maxPayloadSize) {
                    throw WebSocketFrameError.payloadTooLarge
                }
                payloadLength = Int(len64)
                cursor += 8
            }

            if opcode.isControl && payloadLength > 125 {
                throw WebSocketFrameError.controlFrameTooLarge
            }

            if payloadLength > maxPayloadSize {
                throw WebSocketFrameError.payloadTooLarge
            }

            let maskLen = masked ? 4 : 0
            guard buffer.count - cursor >= maskLen + payloadLength else {
                return nil
            }

            var payload: Data
            if masked {
                let key = [
                    buffer[cursor],
                    buffer[cursor + 1],
                    buffer[cursor + 2],
                    buffer[cursor + 3]
                ]
                cursor += 4
                payload = Data(count: payloadLength)
                let sliceStart = cursor
                payload.withUnsafeMutableBytes { dstRaw in
                    buffer.withUnsafeBytes { srcRaw in
                        guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                              let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        for i in 0..<payloadLength {
                            dst[i] = src[sliceStart + i] ^ key[i & 3]
                        }
                    }
                }
                cursor += payloadLength
            } else {
                payload = buffer.subdata(in: cursor..<(cursor + payloadLength))
                cursor += payloadLength
            }

            readOffset = cursor

            switch opcode {
            case .ping:
                return .ping(payload)
            case .pong:
                return .pong(payload)
            case .close:
                if payload.count >= 2 {
                    let code = (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1])
                    let reasonData = payload.dropFirst(2)
                    guard let reason = String(data: reasonData, encoding: .utf8) else {
                        throw WebSocketFrameError.invalidUTF8
                    }
                    return .close(code: code, reason: reason)
                }
                return .close(code: nil, reason: "")

            case .text, .binary:
                guard fragmentOpcode == nil else {
                    throw WebSocketFrameError.fragmentationInProgress
                }
                if fin {
                    return try makeDataEvent(opcode: opcode, data: payload)
                } else {
                    fragmentOpcode = opcode
                    fragmentBuffer = payload
                }

            case .continuation:
                guard let activeOpcode = fragmentOpcode else {
                    throw WebSocketFrameError.unexpectedContinuation
                }
                if fragmentBuffer.count + payload.count > maxPayloadSize {
                    throw WebSocketFrameError.payloadTooLarge
                }
                fragmentBuffer.append(payload)
                if fin {
                    let fullData = fragmentBuffer
                    fragmentBuffer.removeAll(keepingCapacity: false)
                    fragmentOpcode = nil
                    return try makeDataEvent(opcode: activeOpcode, data: fullData)
                }
            }
        }
    }

    private func makeDataEvent(opcode: WebSocketOpcode, data: Data) throws -> WebSocketMessageEvent {
        switch opcode {
        case .text:
            guard let str = String(data: data, encoding: .utf8) else {
                throw WebSocketFrameError.invalidUTF8
            }
            return .text(str)
        case .binary:
            return .binary(data)
        default:
            return .binary(data)
        }
    }

    private func compactBufferIfNeeded() {
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: false)
            readOffset = 0
        } else if readOffset >= 4096 {
            buffer = Data(buffer[readOffset...])
            readOffset = 0
        }
    }
}
