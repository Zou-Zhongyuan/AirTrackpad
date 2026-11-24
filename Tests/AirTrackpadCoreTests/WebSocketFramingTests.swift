import Foundation
import Testing
@testable import AirTrackpadCore

@Suite("WebSocket Framing")
struct WebSocketFramingTests {
    @Test func rfc6455HandshakeAcceptKeyVector() {
        let clientKey = "dGhlIHNhbXBsZSBub25jZQ=="
        let accept = WebSocketHandshake.acceptKey(for: clientKey)
        #expect(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func maskedShort16BitAnd64BitTextFrames() throws {
        let decoder = WebSocketFrameDecoder(requireMask: true)

        let shortText = "hello"
        let mediumText = String(repeating: "a", count: 300)
        let largeText = String(repeating: "z", count: 70_000)

        let wire1 = WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(shortText.utf8))
        let wire2 = WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(mediumText.utf8))
        let wire3 = WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(largeText.utf8))

        var combined = Data()
        combined.append(wire1)
        combined.append(wire2)
        combined.append(wire3)

        decoder.append(combined)
        let events = try decoder.drainEvents()
        #expect(events == [
            .text(shortText),
            .text(mediumText),
            .text(largeText)
        ])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func byteByByteStreamingAndBufferCompaction() throws {
        let decoder = WebSocketFrameDecoder(requireMask: true)
        let payload = String(repeating: "x", count: 5000)
        let frame = WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(payload.utf8))

        var collected: [WebSocketMessageEvent] = []
        for idx in frame.indices {
            decoder.append(Data([frame[idx]]))
            collected.append(contentsOf: try decoder.drainEvents())
        }

        #expect(collected == [.text(payload)])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func fragmentedMessageWithInterleavedPing() throws {
        let decoder = WebSocketFrameDecoder(requireMask: true)

        let part1 = WebSocketFrameEncoder.encodeMasked(
            opcode: .text,
            payload: Data("Hello, ".utf8),
            fin: false
        )
        let ping = WebSocketFrameEncoder.encodeMasked(
            opcode: .ping,
            payload: Data("hb".utf8),
            fin: true
        )
        let part2 = WebSocketFrameEncoder.encodeMasked(
            opcode: .continuation,
            payload: Data("AirTrackpad!".utf8),
            fin: true
        )

        var stream = Data()
        stream.append(part1)
        stream.append(ping)
        stream.append(part2)

        decoder.append(stream)
        let events = try decoder.drainEvents()

        #expect(events == [
            .ping(Data("hb".utf8)),
            .text("Hello, AirTrackpad!")
        ])
    }

    @Test func closeFrameRoundTrip() throws {
        let closeWire = WebSocketFrameEncoder.encodeClose(code: 1000, reason: "normal")
        let serverDecoder = WebSocketFrameDecoder(requireMask: false)
        serverDecoder.append(closeWire)
        let events = try serverDecoder.drainEvents()
        #expect(events == [.close(code: 1000, reason: "normal")])
    }

    @Test func rejectsUnmaskedClientFrame() {
        let decoder = WebSocketFrameDecoder(requireMask: true)
        let unmasked = WebSocketFrameEncoder.encodeText("unmasked")
        decoder.append(unmasked)
        #expect(throws: WebSocketFrameError.unmaskedClientFrame) {
            try decoder.drainEvents()
        }
    }

    @Test func rejectsInvalidFrames() {
        // Reserved bit RSV1 set
        let rsvDecoder = WebSocketFrameDecoder(requireMask: false)
        rsvDecoder.append(Data([0xC1, 0x00]))
        #expect(throws: WebSocketFrameError.reservedBitsSet) {
            try rsvDecoder.drainEvents()
        }

        // Fragmented ping
        let fragCtrlDecoder = WebSocketFrameDecoder(requireMask: false)
        fragCtrlDecoder.append(Data([0x09, 0x00]))
        #expect(throws: WebSocketFrameError.controlFrameFragmented) {
            try fragCtrlDecoder.drainEvents()
        }

        // Control frame > 125 bytes
        let bigCtrlDecoder = WebSocketFrameDecoder(requireMask: false)
        bigCtrlDecoder.append(Data([0x89, 126, 0x00, 126]))
        #expect(throws: WebSocketFrameError.controlFrameTooLarge) {
            try bigCtrlDecoder.drainEvents()
        }

        // Unexpected continuation
        let contDecoder = WebSocketFrameDecoder(requireMask: false)
        contDecoder.append(Data([0x80, 0x00]))
        #expect(throws: WebSocketFrameError.unexpectedContinuation) {
            try contDecoder.drainEvents()
        }

        // Invalid UTF-8 in text frame
        let utf8Decoder = WebSocketFrameDecoder(requireMask: false)
        utf8Decoder.append(WebSocketFrameEncoder.encode(opcode: .text, payload: Data([0xFF, 0xFE])))
        #expect(throws: WebSocketFrameError.invalidUTF8) {
            try utf8Decoder.drainEvents()
        }
    }

    @Test func rejectsOversizedPayload() {
        let decoder = WebSocketFrameDecoder(requireMask: false, maxPayloadSize: 100)
        let large = WebSocketFrameEncoder.encode(opcode: .binary, payload: Data(repeating: 1, count: 101))
        decoder.append(large)
        #expect(throws: WebSocketFrameError.payloadTooLarge) {
            try decoder.drainEvents()
        }
    }
}
