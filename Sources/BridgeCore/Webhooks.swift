import Foundation

/// The parts of webhook delivery that don't depend on the app: which URLs are
/// allowed, when to retry, and what a signed request looks like.
public enum Webhook {
    /// Checks a webhook address. `https://` works anywhere; plain `http://`
    /// only for this Mac, since anything else would send message data in the clear.
    public static func validate(_ raw: String) throws -> URL {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw BridgeError.invalid("Enter the address to send to.") }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, let url = c.url else {
            throw BridgeError.invalid("That isn't a valid address. It should look like https://example.com/hooks/imessage.")
        }
        switch scheme {
        case "https":
            return url
        case "http":
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard ["localhost", "127.0.0.1", "::1"].contains(bare) else {
                throw BridgeError.invalid("Use an https:// address. Plain http:// only works for this Mac (localhost, 127.0.0.1 or ::1).")
            }
            return url
        default:
            throw BridgeError.invalid("The address must start with https://.")
        }
    }

    /// Waits before each retry. With the first try that makes 5 attempts over about 7.5 minutes.
    public static let retryDelays: [TimeInterval] = [5, 30, 120, 300]

    /// The wait before the next attempt after `attempt` failed (1 = the first try), or nil to give up.
    public static func retryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= retryDelays.count else { return nil }
        return retryDelays[attempt - 1]
    }

    /// Whether a failed attempt is worth repeating. Network errors (nil), 5xx,
    /// 408 and 429 might pass later; other answers (3xx, most 4xx) won't change.
    public static func shouldRetry(status: Int?) -> Bool {
        guard let status else { return true }
        return status >= 500 || status == 408 || status == 429
    }

    public static let timeout: TimeInterval = 10

    /// A signed POST in the Standard Webhooks format. Retries reuse `id` with a
    /// fresh timestamp and signature, so receivers can drop duplicates.
    public static func request(url: URL, id: String, body: Data, secret: String, userAgent: String,
                               now: Date = Date()) -> URLRequest {
        let ts = Int(now.timeIntervalSince1970)
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpBody = body
        r.httpShouldHandleCookies = false
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(id, forHTTPHeaderField: "webhook-id")
        r.setValue(String(ts), forHTTPHeaderField: "webhook-timestamp")
        r.setValue(WebhookSignature.sign(id: id, timestamp: ts, body: body, secret: secret), forHTTPHeaderField: "webhook-signature")
        return r
    }

    /// The body of a "Send test" delivery: no message data.
    public static func testEvent(agent: String, now: Date = Date()) -> (id: String, body: Data) {
        let id = "test_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        let payload: [String: Any] = [
            "id": id,
            "type": "webhook.test",
            "created_at": MessageService.ts(now),
            "data": ["agent": agent, "message": "Test from iMessage Bridge. Webhooks for this agent work."],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return (id, body)
    }
}

/// What one delivery attempt got back.
public struct WebhookResult: Sendable, Equatable {
    /// The HTTP status, or nil when no response arrived.
    public let status: Int?
    /// Why no response arrived (timeout, refused connection…).
    public let error: String?

    public init(status: Int?, error: String? = nil) {
        self.status = status
        self.error = error
    }

    public var ok: Bool { status.map { (200..<300).contains($0) } ?? false }
    public var retryable: Bool { !ok && Webhook.shouldRetry(status: status) }

    /// Short text for the UI and the Activity list: "HTTP 503", "timed out".
    public var summary: String {
        if let status {
            if (300..<400).contains(status) { return "HTTP \(status) (redirects aren't followed)" }
            return "HTTP \(status)"
        }
        return error ?? "no response"
    }
}

/// Sends webhook requests: short timeout, no cookies or cache, and redirects
/// are not followed (a 3xx counts as a failure).
public final class WebhookSender: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Webhook.timeout
        cfg.timeoutIntervalForResource = Webhook.timeout * 2
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    public override init() {}

    public func send(_ request: URLRequest) async -> WebhookResult {
        do {
            let (_, response) = try await session.data(for: request)
            return WebhookResult(status: (response as? HTTPURLResponse)?.statusCode)
        } catch let e as URLError {
            return WebhookResult(status: nil, error: Self.describe(e))
        } catch {
            return WebhookResult(status: nil, error: error.localizedDescription)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func describe(_ e: URLError) -> String {
        switch e.code {
        case .timedOut: return "timed out"
        case .cannotConnectToHost: return "couldn't connect"
        case .cannotFindHost, .dnsLookupFailed: return "server not found"
        case .notConnectedToInternet: return "offline"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "TLS error"
        case .networkConnectionLost: return "connection lost"
        default: return e.localizedDescription
        }
    }
}

/// Events waiting for delivery, oldest first, capped so a dead receiver can't
/// grow it without bound: past the cap the oldest are dropped.
public struct WebhookQueue<Element> {
    public let capacity: Int
    public private(set) var items: [Element] = []

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    /// Adds items and returns how many old ones were dropped to make room.
    @discardableResult
    public mutating func append(contentsOf new: [Element]) -> Int {
        items.append(contentsOf: new)
        let over = max(0, items.count - capacity)
        if over > 0 { items.removeFirst(over) }
        return over
    }

    public mutating func popFirst() -> Element? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() { items.removeAll() }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
}
