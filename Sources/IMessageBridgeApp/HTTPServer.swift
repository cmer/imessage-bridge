import Foundation
import Network
import Security

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lowercased names
    let body: Data
    let isNetwork: Bool             // arrived on the LAN (TLS) listener
    let remote: String

    var bearerToken: String? {
        guard let auth = headers["authorization"] else { return nil }
        let parts = auth.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}

struct HTTPResponse {
    typealias Streamer = @Sendable (HTTPStream) async -> Void

    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// Set for a streaming response: the server sends the headers with no
    /// Content-Length, then runs this with the open connection, and closes
    /// the connection when it returns.
    var stream: Streamer?

    static func streaming(headers: [String: String], _ streamer: @escaping Streamer) -> HTTPResponse {
        HTTPResponse(status: 200, headers: headers, stream: streamer)
    }

    static func json(_ status: Int, _ obj: Any, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        var h = headers
        h["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: h, body: data)
    }

    static func error(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        json(status, ["error": message], headers: headers)
    }

    static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var h = headers
        if stream == nil { h["Content-Length"] = String(body.count) }
        h["Connection"] = "close"
        h["Cache-Control"] = "no-store"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 503: return "Service Unavailable"
        default: return s < 400 ? "OK" : "Error"
        }
    }
}

/// The open connection behind a streaming response. Safe to use from any thread.
final class HTTPStream: @unchecked Sendable {
    /// A client that stops reading is dropped once this much is waiting to be sent.
    static let maxPendingBytes = 1024 * 1024

    private let conn: NWConnection
    private let lock = NSLock()
    private var closed = false
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var closeHandlers: [() -> Void] = []

    init(_ conn: NWConnection) {
        self.conn = conn
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Queues bytes for the client. Returns false once the stream is closed.
    @discardableResult
    func write(_ data: Data) -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); return false }
        pending += data.count
        let tooMuch = pending > HTTPStream.maxPendingBytes
        lock.unlock()
        if tooMuch { close(flush: false); return false }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pending -= data.count
            self.lock.unlock()
            if error != nil { self.close(flush: false) }
        })
        return true
    }

    /// Ends the stream and the connection. Safe to call more than once.
    /// With `flush`, what was already written is sent first (for up to 5 s).
    func close(flush: Bool = true) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let ws = waiters, hs = closeHandlers
        waiters = []
        closeHandlers = []
        lock.unlock()
        if flush {
            let conn = self.conn
            // Sends go out in order, so this completes after the earlier writes.
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { conn.cancel() }
        } else {
            conn.cancel()
        }
        for w in ws { w.resume() }
        for h in hs { h() }
    }

    /// Runs `handler` once when the stream closes (right away if it already has).
    func onClose(_ handler: @escaping () -> Void) {
        lock.lock()
        if closed { lock.unlock(); handler(); return }
        closeHandlers.append(handler)
        lock.unlock()
    }

    /// Returns when the stream closes, from either side.
    func waitUntilClosed() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closed { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    /// Reads (and drops) anything the client sends, to notice when it hangs up.
    fileprivate func watchForHangUp() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil { self.close(flush: false) } else if !self.isClosed { self.watchForHangUp() }
        }
    }
}

/// Small HTTP/1.1 server on Network.framework. One request per connection.
final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    let port: UInt16
    let isNetwork: Bool
    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "imessage-bridge.http")
    private var connections = 0
    private var streams: [ObjectIdentifier: HTTPStream] = [:]
    var onState: ((String) -> Void)?

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    static let maxConnections = 32
    /// Streams stay open, so they get a smaller share of the connections.
    static let maxStreams = 8

    /// `identity` nil = plain HTTP bound to 127.0.0.1; otherwise TLS on all interfaces.
    init(port: UInt16, identity: SecIdentity?, handler: @escaping Handler) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw BridgeServerError("invalid port \(port)") }
        self.port = port
        self.handler = handler
        let tcp = NWProtocolTCP.Options()
        if let identity {
            let tls = NWProtocolTLS.Options()
            guard let secID = sec_identity_create(identity) else { throw BridgeServerError("could not load TLS identity") }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secID)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let params = NWParameters(tls: tls, tcp: tcp)
            params.allowLocalEndpointReuse = true
            isNetwork = true
            listener = try NWListener(using: params, on: nwPort)
        } else {
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            isNetwork = false
            listener = try NWListener(using: params)
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onState?("ready")
            case .failed(let e): self.onState?("failed: \(e.localizedDescription)")
            case .cancelled: self.onState?("stopped")
            case .waiting(let e): self.onState?("waiting: \(e.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        // Otherwise streams outlive the listener, e.g. after network access is turned off.
        queue.async { [self] in
            for s in streams.values { s.close() }
        }
    }

    private func accept(_ conn: NWConnection) {
        guard connections < HTTPServer.maxConnections else {
            conn.cancel()
            return
        }
        connections += 1
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.connections -= 1 }
            default: break
            }
        }
        conn.start(queue: queue)
        let remote: String
        switch conn.endpoint {
        case .hostPort(let host, _): remote = "\(host)"
        default: remote = "unknown"
        }
        var buffer = Data()
        var finished = false
        // Only for reading the request: `finished` is set once it's parsed,
        // so slow handlers and long-lived streams aren't cut off.
        queue.asyncAfter(deadline: .now() + 15) {
            if !finished { conn.cancel() }
        }

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                switch self.parse(buffer, remote: remote) {
                case .needMore:
                    if isComplete || error != nil { conn.cancel(); return }
                    receive()
                case .bad(let resp):
                    finished = true
                    self.respond(conn, resp)
                case .request(let req):
                    finished = true
                    let handler = self.handler
                    Task {
                        let resp = await handler(req)
                        self.respond(conn, resp)
                    }
                }
            }
        }
        receive()
    }

    private func respond(_ conn: NWConnection, _ resp: HTTPResponse) {
        guard let streamer = resp.stream else {
            conn.send(content: resp.serialized(), completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        queue.async { [self] in
            guard streams.count < HTTPServer.maxStreams else {
                respond(conn, .error(503, "Too many open event streams.", headers: ["Retry-After": "30"]))
                return
            }
            let stream = HTTPStream(conn)
            let key = ObjectIdentifier(stream)
            streams[key] = stream
            stream.onClose { [weak self] in self?.queue.async { self?.streams[key] = nil } }
            stream.write(resp.serialized())
            stream.watchForHangUp()
            Task {
                await streamer(stream)
                stream.close()
            }
        }
    }

    private enum ParseResult {
        case needMore
        case bad(HTTPResponse)
        case request(HTTPRequest)
    }

    private func parse(_ buf: Data, remote: String) -> ParseResult {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > HTTPServer.maxHeaderBytes ? .bad(.error(413, "headers too large")) : .needMore
        }
        guard let head = String(data: buf[buf.startIndex..<sep.lowerBound], encoding: .utf8) else {
            return .bad(.error(400, "bad request"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .bad(.error(400, "bad request line")) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        if headers["transfer-encoding"] != nil { return .bad(.error(400, "chunked bodies are not supported")) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad(.error(400, "bad content-length")) }
        guard length <= HTTPServer.maxBodyBytes else { return .bad(.error(413, "body too large")) }
        let bodyStart = sep.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= length else { return .needMore }
        let body = buf[bodyStart..<(bodyStart + length)]
        var path = String(requestLine[1])
        var query: [String: String] = [:]
        if let q = path.firstIndex(of: "?") {
            for item in URLComponents(string: "/?" + path[path.index(after: q)...])?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            path = String(path[..<q])
        }
        return .request(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: Data(body),
            isNetwork: isNetwork,
            remote: remote
        ))
    }
}

struct BridgeServerError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
