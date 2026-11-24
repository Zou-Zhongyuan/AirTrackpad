import Foundation
import Network
import Testing
@testable import AirTrackpadCore

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func waitUntil(
    timeoutSeconds: TimeInterval = 3.0,
    condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
    }
    return condition()
}

@Suite("HTTP and WebSocket Server")
struct HTTPWebSocketServerTests {
    private func makeTempWebDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirTrackpadWebTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let html = """
        <!DOCTYPE html>
        <html>
        <head><link rel="manifest" href="/manifest.json"></head>
        <body>AirTrackpad</body>
        </html>
        """
        try Data(html.utf8).write(to: dir.appendingPathComponent("index.html"))
        try Data("body { background: #000; }".utf8).write(to: dir.appendingPathComponent("style.css"))
        try Data("export const ok = true;".utf8).write(to: dir.appendingPathComponent("gesture-engine.js"))
        try Data("console.log('app');".utf8).write(to: dir.appendingPathComponent("app.js"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("icon-192.png"))
        return dir
    }

    private func makeIsolatedTokenStore() -> (TokenStore, String) {
        let suite = "AirTrackpadServerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (TokenStore(defaults: defaults, tokenKey: "token"), suite)
    }

    @Test func httpStaticAssetsManifestAndTokenRewriting() async throws {
        let webDir = try makeTempWebDirectory()
        defer { try? FileManager.default.removeItem(at: webDir) }

        let (tokenStore, suite) = makeIsolatedTokenStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let server = HTTPWebSocketServer(tokenStore: tokenStore, webDirectory: webDir)
        let port = try await server.start(port: 0, persistPort: false)
        defer { server.stop() }

        let token = tokenStore.currentToken
        let baseURL = "http://127.0.0.1:\(port)"

        // 1. Valid token rewrites manifest link
        let (indexData, indexResp) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/?token=\(token)")!)
        let indexHTTP = try #require(indexResp as? HTTPURLResponse)
        #expect(indexHTTP.statusCode == 200)
        #expect(indexHTTP.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        let indexHTML = String(decoding: indexData, as: UTF8.self)
        #expect(indexHTML.contains(#"<link rel="manifest" href="/manifest.json?token=\#(token)">"#))

        // 2. Missing/invalid token does NOT rewrite manifest link
        let (anonData, _) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/?token=wrong")!)
        let anonHTML = String(decoding: anonData, as: UTF8.self)
        #expect(anonHTML.contains(#"<link rel="manifest" href="/manifest.json">"#))
        #expect(!anonHTML.contains("wrong"))

        // 3. Dynamic manifest.json with valid token
        let (manifestData, manifestResp) = try await URLSession.shared.data(
            from: URL(string: "\(baseURL)/manifest.json?token=\(token)")!
        )
        let manifestHTTP = try #require(manifestResp as? HTTPURLResponse)
        #expect(manifestHTTP.statusCode == 200)
        let manifestObj = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        #expect(manifestObj["display"] as? String == "standalone")
        #expect(manifestObj["background_color"] as? String == "#000000")
        #expect(manifestObj["theme_color"] as? String == "#000000")
        #expect(manifestObj["start_url"] as? String == "/?token=\(token)")

        // 4. Dynamic manifest.json without token falls back to "/"
        let (anonManifestData, _) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/manifest.json")!)
        let anonManifestObj = try #require(try JSONSerialization.jsonObject(with: anonManifestData) as? [String: Any])
        #expect(anonManifestObj["start_url"] as? String == "/")

        // 5. JS/CSS have Cache-Control: no-cache
        let (_, jsResp) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/gesture-engine.js")!)
        #expect((jsResp as? HTTPURLResponse)?.statusCode == 200)
        #expect((jsResp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-cache")

        // 6. Path traversal / unknown route returns 404
        let (_, notFoundResp) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/../Package.swift")!)
        #expect((notFoundResp as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func webSocketRejectsUnauthorizedToken() async throws {
        let webDir = try makeTempWebDirectory()
        defer { try? FileManager.default.removeItem(at: webDir) }

        let (tokenStore, suite) = makeIsolatedTokenStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let server = HTTPWebSocketServer(tokenStore: tokenStore, webDirectory: webDir)
        let port = try await server.start(port: 0, persistPort: false)
        defer { server.stop() }

        let rawResponse = try await sendRawTCPRequest(
            port: port,
            request: [
                "GET /ws?token=invalid_token HTTP/1.1",
                "Host: 127.0.0.1:\(port)",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                "Sec-WebSocket-Version: 13",
                "",
                ""
            ].joined(separator: "\r\n")
        )

        let text = String(decoding: rawResponse, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized"))
        #expect(server.connectedClientCount == 0)
    }

    @Test func webSocketUpgradeRoundTripAndDisconnectCallbacks() async throws {
        let webDir = try makeTempWebDirectory()
        defer { try? FileManager.default.removeItem(at: webDir) }

        let (tokenStore, suite) = makeIsolatedTokenStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let receivedMessages = LockedBox<[IncomingMessage]>([])
        let connected = LockedBox(false)
        let allDisconnected = LockedBox(false)

        let server = HTTPWebSocketServer(
            tokenStore: tokenStore,
            webDirectory: webDir,
            callbacks: .init(
                onMessage: { _, msg in
                    receivedMessages.withLock { $0.append(msg) }
                },
                onClientConnected: { _ in
                    connected.withLock { $0 = true }
                },
                onAllClientsDisconnected: {
                    allDisconnected.withLock { $0 = true }
                }
            )
        )

        let port = try await server.start(port: 0, persistPort: false)
        defer { server.stop() }

        let conn = try await connectTCP(port: port)
        defer { conn.cancel() }

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let upgradeReq = [
            "GET /ws?token=\(tokenStore.currentToken) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "",
            ""
        ].joined(separator: "\r\n")

        try await sendTCP(conn, data: Data(upgradeReq.utf8))
        let didConnect = await waitUntil { connected.withLock { $0 } }
        #expect(didConnect)
        #expect(server.connectedClientCount == 1)

        // Read HTTP 101 + trailing data
        let decoder = WebSocketFrameDecoder(requireMask: false)
        var httpDone = false
        var buffer = Data()
        while !httpDone {
            let chunk = try await receiveTCP(conn)
            buffer.append(chunk)
            if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                #expect(header.contains("101 Switching Protocols"))
                #expect(header.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
                let rest = Data(buffer[range.upperBound...])
                decoder.append(rest)
                httpDone = true
            }
        }

        // Send masked WebSocket Ping + 3 JSON gestures
        var outFrames = Data()
        outFrames.append(WebSocketFrameEncoder.encodeMasked(opcode: .ping, payload: Data("hi".utf8)))
        outFrames.append(WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(#"{"t":"dragStart"}"#.utf8)))
        outFrames.append(WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(#"{"t":"swipe4","dir":"up"}"#.utf8)))
        outFrames.append(WebSocketFrameEncoder.encodeMasked(opcode: .text, payload: Data(#"{"t":"ping","ts":42.5}"#.utf8)))
        try await sendTCP(conn, data: outFrames)

        let gotMessages = await waitUntil { receivedMessages.withLock { $0.count == 3 } }
        #expect(gotMessages)
        #expect(receivedMessages.withLock { $0 } == [
            .dragStart,
            .swipe4(dir: .up, naturalSpaces: true),
            .ping(ts: 42.5)
        ])

        var serverEvents: [WebSocketMessageEvent] = try decoder.drainEvents()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && serverEvents.count < 3 {
            let chunk = try await receiveTCP(conn)
            decoder.append(chunk)
            serverEvents.append(contentsOf: try decoder.drainEvents())
        }

        #expect(serverEvents.contains(.pong(Data("hi".utf8))))
        #expect(serverEvents.contains { event in
            if case .text(let s) = event {
                return s.contains(#""t":"hello""#)
            }
            return false
        })
        #expect(serverEvents.contains { event in
            if case .text(let s) = event {
                return s.contains(#""t":"pong""#) && s.contains("42.5")
            }
            return false
        })

        // Trigger token rotation disconnect
        server.disconnectAllClients(reason: "Rotated")
        let didDisconnect = await waitUntil { allDisconnected.withLock { $0 } }
        #expect(didDisconnect)
        #expect(server.connectedClientCount == 0)
    }

    @Test func heartbeatTimeoutReleasesIdleClient() async throws {
        let webDir = try makeTempWebDirectory()
        defer { try? FileManager.default.removeItem(at: webDir) }

        let (tokenStore, suite) = makeIsolatedTokenStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let disconnected = LockedBox(false)
        let server = HTTPWebSocketServer(
            tokenStore: tokenStore,
            webDirectory: webDir,
            heartbeatTimeout: 0.35,
            callbacks: .init(onAllClientsDisconnected: {
                disconnected.withLock { $0 = true }
            })
        )

        let port = try await server.start(port: 0, persistPort: false)
        defer { server.stop() }

        let conn = try await connectTCP(port: port)
        defer { conn.cancel() }

        let upgradeReq = [
            "GET /ws?token=\(tokenStore.currentToken) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version: 13",
            "",
            ""
        ].joined(separator: "\r\n")

        try await sendTCP(conn, data: Data(upgradeReq.utf8))
        let didTimeout = await waitUntil(timeoutSeconds: 3.0) { disconnected.withLock { $0 } }
        #expect(didTimeout)
        #expect(server.connectedClientCount == 0)
    }

    @Test func malformedURIAndHeadOnWebSocketAreRejected() async throws {
        let webDir = try makeTempWebDirectory()
        defer { try? FileManager.default.removeItem(at: webDir) }

        let (tokenStore, suite) = makeIsolatedTokenStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let server = HTTPWebSocketServer(tokenStore: tokenStore, webDirectory: webDir)
        let port = try await server.start(port: 0, persistPort: false)
        defer { server.stop() }

        let malformedResp = try await sendRawTCPRequest(
            port: port,
            request: [
                "GET http://[::1/ws HTTP/1.1",
                "Host: 127.0.0.1:\(port)",
                "",
                ""
            ].joined(separator: "\r\n")
        )
        #expect(String(decoding: malformedResp, as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request"))

        let relativeResp = try await sendRawTCPRequest(
            port: port,
            request: [
                "GET relative-path HTTP/1.1",
                "Host: 127.0.0.1:\(port)",
                "",
                ""
            ].joined(separator: "\r\n")
        )
        #expect(String(decoding: relativeResp, as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request"))

        let headWSResp = try await sendRawTCPRequest(
            port: port,
            request: [
                "HEAD /ws?token=\(tokenStore.currentToken) HTTP/1.1",
                "Host: 127.0.0.1:\(port)",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                "",
                ""
            ].joined(separator: "\r\n")
        )
        #expect(String(decoding: headWSResp, as: UTF8.self).hasPrefix("HTTP/1.1 405 Method Not Allowed"))
        #expect(server.connectedClientCount == 0)
    }

    @Test func repeatedConnectionHeadersAndMultiClientPerClientDisconnect() async throws {
        let webDir = try makeTempWebDirectory()
        defer { try? FileManager.default.removeItem(at: webDir) }

        let (tokenStore, suite) = makeIsolatedTokenStore()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let connectedIDs = LockedBox<[UUID]>([])
        let disconnectedIDs = LockedBox<[UUID]>([])
        let allDisconnected = LockedBox(false)

        let server = HTTPWebSocketServer(
            tokenStore: tokenStore,
            webDirectory: webDir,
            callbacks: .init(
                onClientConnected: { id in
                    connectedIDs.withLock { $0.append(id) }
                },
                onClientDisconnected: { id in
                    disconnectedIDs.withLock { $0.append(id) }
                },
                onAllClientsDisconnected: {
                    allDisconnected.withLock { $0 = true }
                }
            )
        )

        let port = try await server.start(port: 0, persistPort: false)
        defer { server.stop() }

        let conn1 = try await connectTCP(port: port)
        defer { conn1.cancel() }
        let req1 = [
            "GET /ws?token=\(tokenStore.currentToken) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Connection: keep-alive",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "",
            ""
        ].joined(separator: "\r\n")
        try await sendTCP(conn1, data: Data(req1.utf8))
        let resp1 = String(decoding: try await receiveTCP(conn1), as: UTF8.self)
        #expect(resp1.contains("101 Switching Protocols"))

        let conn2 = try await connectTCP(port: port)
        defer { conn2.cancel() }
        let req2 = [
            "GET /ws?token=\(tokenStore.currentToken) HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
            "",
            ""
        ].joined(separator: "\r\n")
        try await sendTCP(conn2, data: Data(req2.utf8))
        let resp2 = String(decoding: try await receiveTCP(conn2), as: UTF8.self)
        #expect(resp2.contains("101 Switching Protocols"))

        let bothConnected = await waitUntil { connectedIDs.withLock { $0.count == 2 } }
        #expect(bothConnected)
        #expect(server.connectedClientCount == 2)

        let firstID = connectedIDs.withLock { $0[0] }
        let closeFrame = WebSocketFrameEncoder.encodeMasked(
            opcode: .close,
            payload: Data([0x03, 0xE8])
        )
        try await sendTCP(conn1, data: closeFrame)

        let oneDisconnected = await waitUntil { disconnectedIDs.withLock { $0.count == 1 } }
        #expect(oneDisconnected)
        #expect(disconnectedIDs.withLock { $0 } == [firstID])
        #expect(server.connectedClientCount == 1)
        #expect(!allDisconnected.withLock { $0 })
    }

    // MARK: - Raw TCP Test Helpers

    private func connectTCP(port: UInt16) async throws -> NWConnection {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "test.tcp.\(UUID().uuidString)")
        let resumed = LockedBox(false)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        cont.resume()
                    }
                case .failed(let err):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        cont.resume(throwing: err)
                    }
                case .cancelled:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        cont.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
        return conn
    }

    private func sendTCP(_ conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveTCP(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func sendRawTCPRequest(port: UInt16, request: String) async throws -> Data {
        let conn = try await connectTCP(port: port)
        defer { conn.cancel() }
        try await sendTCP(conn, data: Data(request.utf8))
        return try await receiveTCP(conn)
    }
}
