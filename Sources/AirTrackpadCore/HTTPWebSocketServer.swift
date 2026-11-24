import Foundation
import Network

public enum HTTPWebSocketServerError: Error, Sendable {
    case failedToBindPort(UInt16)
    case serverStopped
    case underlying(String)
}

public final class HTTPWebSocketServer: @unchecked Sendable {
    public struct Callbacks: Sendable {
        public var onMessage: @Sendable (UUID, IncomingMessage) -> Void
        public var onClientConnected: @Sendable (UUID) -> Void
        public var onClientDisconnected: @Sendable (UUID) -> Void
        public var onClientCountChanged: @Sendable (Int) -> Void
        public var onAllClientsDisconnected: @Sendable () -> Void

        public init(
            onMessage: @escaping @Sendable (UUID, IncomingMessage) -> Void = { _, _ in },
            onClientConnected: @escaping @Sendable (UUID) -> Void = { _ in },
            onClientDisconnected: @escaping @Sendable (UUID) -> Void = { _ in },
            onClientCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
            onAllClientsDisconnected: @escaping @Sendable () -> Void = {}
        ) {
            self.onMessage = onMessage
            self.onClientConnected = onClientConnected
            self.onClientDisconnected = onClientDisconnected
            self.onClientCountChanged = onClientCountChanged
            self.onAllClientsDisconnected = onAllClientsDisconnected
        }
    }

    private final class ClientConnection: @unchecked Sendable {
        enum Mode {
            case http(buffer: Data)
            case webSocket(decoder: WebSocketFrameDecoder, lastActivity: Date, closeSent: Bool)
        }

        let id = UUID()
        let connection: NWConnection
        var mode: Mode = .http(buffer: Data())
        var isClosing = false
        var isClosed = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private static let staticAssets: [String: (filename: String, contentType: String, cacheControl: String)] = [
        "/style.css": ("style.css", "text/css; charset=utf-8", "no-cache"),
        "/app.js": ("app.js", "application/javascript; charset=utf-8", "no-cache"),
        "/gesture-engine.js": ("gesture-engine.js", "application/javascript; charset=utf-8", "no-cache"),
        "/apple-touch-icon.png": ("apple-touch-icon.png", "image/png", "public, max-age=86400"),
        "/icon-192.png": ("icon-192.png", "image/png", "public, max-age=86400"),
        "/icon-512.png": ("icon-512.png", "image/png", "public, max-age=86400")
    ]

    private let queue = DispatchQueue(label: "com.airtrackpad.http-ws-server")
    private let tokenStore: TokenStore
    private let webDirectory: URL
    private let heartbeatTimeout: TimeInterval
    private let callbacks: Callbacks
    private let hostNameProvider: @Sendable () -> String

    private var listener: NWListener?
    private var connections: [UUID: ClientConnection] = [:]
    private var activeWebSocketIDs: Set<UUID> = []
    private var heartbeatTimer: DispatchSourceTimer?
    private var currentPort: UInt16 = 0
    private var isRunning = false
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    public init(
        tokenStore: TokenStore,
        webDirectory: URL,
        heartbeatTimeout: TimeInterval = 5.0,
        hostNameProvider: @escaping @Sendable () -> String = {
            Host.current().localizedName ?? "Mac"
        },
        callbacks: Callbacks = Callbacks()
    ) {
        self.tokenStore = tokenStore
        self.webDirectory = webDirectory
        self.heartbeatTimeout = max(0.1, heartbeatTimeout)
        self.hostNameProvider = hostNameProvider
        self.callbacks = callbacks
    }

    public var port: UInt16 {
        queue.sync { currentPort }
    }

    public var connectedClientCount: Int {
        queue.sync { activeWebSocketIDs.count }
    }

    public func start(port preferredPort: UInt16 = TokenStore.defaultPort, persistPort: Bool = true) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: HTTPWebSocketServerError.serverStopped)
                    return
                }
                self.stopLocked()
                self.isRunning = true
                self.startContinuation = continuation
                let candidates = Self.candidatePorts(startingFrom: preferredPort)
                self.tryBindPorts(candidates, persistPort: persistPort)
            }
        }
    }

    public func start(
        port preferredPort: UInt16 = TokenStore.defaultPort,
        persistPort: Bool = true,
        completion: @escaping @Sendable (Result<UInt16, Error>) -> Void
    ) {
        Task {
            do {
                let bound = try await start(port: preferredPort, persistPort: persistPort)
                completion(.success(bound))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func stop() {
        queue.sync {
            stopLocked()
        }
    }

    public func disconnectAllClients(reason: String = "Token rotated") {
        queue.async { [weak self] in
            guard let self else { return }
            let wsClients = self.activeWebSocketIDs.compactMap { self.connections[$0] }
            for client in wsClients {
                let frame = WebSocketFrameEncoder.encodeClose(code: 4001, reason: reason)
                self.sendAndClose(client: client, data: frame)
            }
        }
    }

    private static func candidatePorts(startingFrom preferred: UInt16) -> [UInt16] {
        if preferred == 0 {
            return [0]
        }
        var ports: [UInt16] = []
        for offset in UInt16(0)...UInt16(20) {
            let (next, overflow) = preferred.addingReportingOverflow(offset)
            if !overflow && next >= 1024 {
                ports.append(next)
            }
        }
        ports.append(0)
        return ports
    }

    private func tryBindPorts(_ remainingPorts: [UInt16], persistPort: Bool) {
        guard isRunning else {
            resumeStart(with: .failure(HTTPWebSocketServerError.serverStopped))
            return
        }
        guard let candidate = remainingPorts.first else {
            resumeStart(with: .failure(HTTPWebSocketServerError.failedToBindPort(0)))
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            if candidate == 0 {
                newListener = try NWListener(using: params)
            } else if let nwPort = NWEndpoint.Port(rawValue: candidate) {
                newListener = try NWListener(using: params, on: nwPort)
            } else {
                tryBindPorts(Array(remainingPorts.dropFirst()), persistPort: persistPort)
                return
            }
        } catch {
            if Self.isAddressInUse(error), remainingPorts.count > 1 {
                tryBindPorts(Array(remainingPorts.dropFirst()), persistPort: persistPort)
            } else {
                resumeStart(with: .failure(error))
            }
            return
        }

        // IMPORTANT (Apple TN3179): Do NOT set newListener.service (Bonjour publishing)
        // to avoid triggering Local Network Privacy rejections on ad-hoc signed apps.
        self.listener = newListener

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, self.listener === newListener else { return }
            switch state {
            case .ready:
                let bound = newListener.port?.rawValue ?? candidate
                self.currentPort = bound
                if persistPort && bound != 0 {
                    TokenStore.savePreferredPort(bound)
                }
                self.startHeartbeatTimerLocked()
                self.resumeStart(with: .success(bound))

            case .failed(let error):
                if self.startContinuation != nil {
                    newListener.cancel()
                    self.listener = nil
                    if Self.isAddressInUse(error) && remainingPorts.count > 1 {
                        self.tryBindPorts(Array(remainingPorts.dropFirst()), persistPort: persistPort)
                    } else {
                        self.resumeStart(with: .failure(error))
                    }
                }

            case .cancelled:
                break

            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        newListener.start(queue: queue)
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        if let nwError = error as? NWError {
            if case .posix(let code) = nwError, code == .EADDRINUSE {
                return true
            }
        }
        let nsErr = error as NSError
        return nsErr.domain == NSPOSIXErrorDomain && nsErr.code == Int(EADDRINUSE)
    }

    private func resumeStart(with result: Result<UInt16, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        switch result {
        case .success(let port):
            continuation.resume(returning: port)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func stopLocked() {
        isRunning = false
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        listener?.cancel()
        listener = nil
        currentPort = 0

        let allClients = Array(connections.values)
        for client in allClients {
            closeClientLocked(client)
        }
        connections.removeAll()
        resumeStart(with: .failure(HTTPWebSocketServerError.serverStopped))
    }

    private func startHeartbeatTimerLocked() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = min(1.0, max(0.05, heartbeatTimeout / 3.0))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeatsLocked()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func checkHeartbeatsLocked() {
        let now = Date()
        let wsIDs = Array(activeWebSocketIDs)
        for id in wsIDs {
            guard let client = connections[id],
                  case .webSocket(_, let lastActivity, _) = client.mode else { continue }
            if now.timeIntervalSince(lastActivity) > heartbeatTimeout {
                let closeFrame = WebSocketFrameEncoder.encodeClose(code: 1001, reason: "Heartbeat timeout")
                sendAndClose(client: client, data: closeFrame)
            }
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        guard isRunning else {
            nwConnection.cancel()
            return
        }
        let client = ClientConnection(connection: nwConnection)
        connections[client.id] = client

        nwConnection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled:
                self.closeClientLocked(client)
            default:
                break
            }
        }

        nwConnection.start(queue: queue)
        receiveNextChunk(for: client)
    }

    private func receiveNextChunk(for client: ClientConnection) {
        guard !client.isClosed, !client.isClosing else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client, !client.isClosed else { return }
            if let data, !data.isEmpty {
                self.processReceivedData(data, for: client)
            }
            if error != nil || isComplete {
                self.closeClientLocked(client)
                return
            }
            if !client.isClosed, !client.isClosing {
                self.receiveNextChunk(for: client)
            }
        }
    }

    private func processReceivedData(_ data: Data, for client: ClientConnection) {
        switch client.mode {
        case .http(var buffer):
            buffer.append(data)
            if buffer.count > 16384 {
                sendHTTPResponseAndClose(
                    client: client,
                    status: "431 Request Header Fields Too Large",
                    contentType: "text/plain; charset=utf-8",
                    cacheControl: "no-store",
                    body: Data("Request headers too large".utf8)
                )
                return
            }
            let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            if let range = buffer.range(of: delimiter) {
                let headerData = buffer[..<range.lowerBound]
                let trailingData = Data(buffer[range.upperBound...])
                handleHTTPRequest(headerData: headerData, trailingData: trailingData, client: client)
            } else {
                client.mode = .http(buffer: buffer)
            }

        case .webSocket(let decoder, _, let closeSent):
            client.mode = .webSocket(decoder: decoder, lastActivity: Date(), closeSent: closeSent)
            decoder.append(data)
            processWebSocketFrames(for: client, decoder: decoder)
        }
    }

    private func handleHTTPRequest(headerData: Data.SubSequence, trailingData: Data, client: ClientConnection) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            sendHTTPResponseAndClose(
                client: client,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Invalid header encoding".utf8)
            )
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponseAndClose(
                client: client,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Missing request line".utf8)
            )
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            sendHTTPResponseAndClose(
                client: client,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Malformed request line".utf8)
            )
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let name = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                if let existing = headers[name], !existing.isEmpty {
                    headers[name] = "\(existing), \(value)"
                } else {
                    headers[name] = value
                }
            }
        }

        guard method == "GET" || method == "HEAD" else {
            sendHTTPResponseAndClose(
                client: client,
                status: "405 Method Not Allowed",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Method Not Allowed".utf8)
            )
            return
        }

        guard let components = URLComponents(string: target),
              components.path.hasPrefix("/") else {
            sendHTTPResponseAndClose(
                client: client,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Bad Request".utf8)
            )
            return
        }

        let path = components.path
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value

        if path == "/ws" {
            guard method == "GET" else {
                sendHTTPResponseAndClose(
                    client: client,
                    status: "405 Method Not Allowed",
                    contentType: "text/plain; charset=utf-8",
                    cacheControl: "no-store",
                    body: Data("Method Not Allowed".utf8)
                )
                return
            }
            handleWebSocketUpgrade(headers: headers, token: token, trailingData: trailingData, client: client)
            return
        }

        if path == "/manifest.json" {
            serveManifest(token: token, headOnly: method == "HEAD", client: client)
            return
        }

        if path == "/" || path == "/index.html" {
            serveIndexHTML(token: token, headOnly: method == "HEAD", client: client)
            return
        }

        if let asset = Self.staticAssets[path] {
            serveStaticFile(
                filename: asset.filename,
                contentType: asset.contentType,
                cacheControl: asset.cacheControl,
                headOnly: method == "HEAD",
                client: client
            )
            return
        }

        sendHTTPResponseAndClose(
            client: client,
            status: "404 Not Found",
            contentType: "text/plain; charset=utf-8",
            cacheControl: "no-store",
            body: Data("Not Found".utf8)
        )
    }

    private func handleWebSocketUpgrade(
        headers: [String: String],
        token: String?,
        trailingData: Data,
        client: ClientConnection
    ) {
        guard tokenStore.isValid(token) else {
            sendHTTPResponseAndClose(
                client: client,
                status: "401 Unauthorized",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Unauthorized".utf8)
            )
            return
        }

        let upgradeTokens = (headers["upgrade"] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let connectionTokens = (headers["connection"] ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard upgradeTokens.contains("websocket"),
              connectionTokens.contains("upgrade"),
              let wsKey = headers["sec-websocket-key"],
              !wsKey.isEmpty else {
            sendHTTPResponseAndClose(
                client: client,
                status: "400 Bad Request",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Invalid WebSocket upgrade headers".utf8)
            )
            return
        }

        let acceptKey = WebSocketHandshake.acceptKey(for: wsKey)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptKey)",
            "Cache-Control: no-store",
            "",
            ""
        ].joined(separator: "\r\n")

        let decoder = WebSocketFrameDecoder(requireMask: true)
        client.mode = .webSocket(decoder: decoder, lastActivity: Date(), closeSent: false)
        activeWebSocketIDs.insert(client.id)

        let count = activeWebSocketIDs.count
        let clientID = client.id

        sendRaw(client: client, data: Data(response.utf8))

        let hello = OutgoingMessage.hello(hostName: hostNameProvider(), version: "1.0.0").encodeJSON()
        sendRaw(client: client, data: WebSocketFrameEncoder.encodeText(hello))

        callbacks.onClientConnected(clientID)
        callbacks.onClientCountChanged(count)

        if !trailingData.isEmpty {
            decoder.append(trailingData)
            processWebSocketFrames(for: client, decoder: decoder)
        }
    }

    private func serveIndexHTML(token: String?, headOnly: Bool, client: ClientConnection) {
        let indexURL = webDirectory.appendingPathComponent("index.html")
        guard let rawData = try? Data(contentsOf: indexURL),
              var html = String(data: rawData, encoding: .utf8) else {
            sendHTTPResponseAndClose(
                client: client,
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Missing index.html".utf8)
            )
            return
        }

        if let token, tokenStore.isValid(token) {
            html = html.replacingOccurrences(
                of: #"<link rel="manifest" href="/manifest.json">"#,
                with: #"<link rel="manifest" href="/manifest.json?token=\#(token)">"#
            )
        }

        sendHTTPResponseAndClose(
            client: client,
            status: "200 OK",
            contentType: "text/html; charset=utf-8",
            cacheControl: "no-cache",
            body: Data(html.utf8),
            headOnly: headOnly
        )
    }

    private func serveManifest(token: String?, headOnly: Bool, client: ClientConnection) {
        let startURL: String
        if let token, tokenStore.isValid(token) {
            startURL = "/?token=\(token)"
        } else {
            startURL = "/"
        }

        let manifest: [String: Any] = [
            "name": "AirTrackpad",
            "short_name": "AirTrackpad",
            "start_url": startURL,
            "scope": "/",
            "display": "standalone",
            "background_color": "#000000",
            "theme_color": "#000000",
            "icons": [
                ["src": "/icon-192.png", "sizes": "192x192", "type": "image/png"],
                ["src": "/icon-512.png", "sizes": "512x512", "type": "image/png"]
            ]
        ]

        let body = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendHTTPResponseAndClose(
            client: client,
            status: "200 OK",
            contentType: "application/manifest+json; charset=utf-8",
            cacheControl: "no-store",
            body: body,
            headOnly: headOnly
        )
    }

    private func serveStaticFile(
        filename: String,
        contentType: String,
        cacheControl: String,
        headOnly: Bool,
        client: ClientConnection
    ) {
        let fileURL = webDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            sendHTTPResponseAndClose(
                client: client,
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                cacheControl: "no-store",
                body: Data("Not Found".utf8)
            )
            return
        }

        sendHTTPResponseAndClose(
            client: client,
            status: "200 OK",
            contentType: contentType,
            cacheControl: cacheControl,
            body: data,
            headOnly: headOnly
        )
    }

    private func processWebSocketFrames(for client: ClientConnection, decoder: WebSocketFrameDecoder) {
        let events: [WebSocketMessageEvent]
        do {
            events = try decoder.drainEvents()
        } catch {
            let closeFrame = WebSocketFrameEncoder.encodeClose(code: 1002, reason: "Protocol error")
            sendAndClose(client: client, data: closeFrame)
            return
        }

        for event in events {
            guard !client.isClosed else { return }
            switch event {
            case .ping(let payload):
                let pong = WebSocketFrameEncoder.encodePong(payload: payload)
                sendRaw(client: client, data: pong)

            case .pong:
                break

            case .close(let code, _):
                if case .webSocket(let dec, let last, false) = client.mode {
                    client.mode = .webSocket(decoder: dec, lastActivity: last, closeSent: true)
                    let closeFrame = WebSocketFrameEncoder.encodeClose(code: code ?? 1000, reason: "")
                    sendAndClose(client: client, data: closeFrame)
                } else {
                    closeClientLocked(client)
                }
                return

            case .text(let text):
                guard let data = text.data(using: .utf8) else { continue }
                do {
                    let message = try IncomingMessage.decode(from: data)
                    if case .ping(let ts) = message {
                        let pong = OutgoingMessage.pong(ts: ts).encodeJSON()
                        sendRaw(client: client, data: WebSocketFrameEncoder.encodeText(pong))
                    }
                    callbacks.onMessage(client.id, message)
                } catch {
                    let errMsg = OutgoingMessage.error(message: "Invalid gesture payload").encodeJSON()
                    sendRaw(client: client, data: WebSocketFrameEncoder.encodeText(errMsg))
                }

            case .binary:
                break
            }
        }
    }

    private func sendHTTPResponseAndClose(
        client: ClientConnection,
        status: String,
        contentType: String,
        cacheControl: String,
        body: Data,
        headOnly: Bool = false
    ) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: \(cacheControl)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var packet = Data(header.utf8)
        if !headOnly {
            packet.append(body)
        }
        sendAndClose(client: client, data: packet)
    }

    private func sendRaw(client: ClientConnection, data: Data) {
        guard !client.isClosed else { return }
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            if error != nil, let self, let client {
                self.queue.async {
                    self.closeClientLocked(client)
                }
            }
        })
    }

    private func sendAndClose(client: ClientConnection, data: Data) {
        guard !client.isClosed, !client.isClosing else { return }
        client.isClosing = true
        deactivateWebSocketLocked(client)
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.queue.async {
                self.closeClientLocked(client)
            }
        })
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak client] in
            guard let self, let client else { return }
            self.closeClientLocked(client)
        }
    }

    private func deactivateWebSocketLocked(_ client: ClientConnection) {
        if activeWebSocketIDs.remove(client.id) != nil {
            let remaining = activeWebSocketIDs.count
            callbacks.onClientDisconnected(client.id)
            callbacks.onClientCountChanged(remaining)
            if remaining == 0 {
                callbacks.onAllClientsDisconnected()
            }
        }
    }

    private func closeClientLocked(_ client: ClientConnection) {
        guard !client.isClosed else { return }
        client.isClosed = true
        connections.removeValue(forKey: client.id)
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        deactivateWebSocketLocked(client)
    }
}
