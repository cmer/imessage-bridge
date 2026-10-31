import Foundation

public enum JevProvider: String, Codable, CaseIterable, Sendable {
    case typesafe
    case openrouter

    public var label: String { self == .typesafe ? "Jev (TypeSafe API key)" : "OpenRouter" }

    public var endpoint: URL {
        switch self {
        case .typesafe: return URL(string: "https://api.typesafe.ai/v1/systemone")!
        case .openrouter: return URL(string: "https://openrouter.ai/api/alpha/decisions")!
        }
    }

    public var defaultModel: String { self == .typesafe ? "jev-latest" : "typesafe/jev-1.14" }
    public var keychainAccount: String { self == .typesafe ? "typesafe-api-key" : "openrouter-api-key" }
}

public struct JevConfig: Sendable {
    public var provider: JevProvider
    public var apiKey: String
    public var model: String
    public var threshold: Double
    public var scanContacts: Bool
    public var requireNoDataCollection: Bool

    public init(provider: JevProvider, apiKey: String, model: String, threshold: Double,
                scanContacts: Bool, requireNoDataCollection: Bool) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model.isEmpty ? provider.defaultModel : model
        self.threshold = threshold
        self.scanContacts = scanContacts
        self.requireNoDataCollection = requireNoDataCollection
    }
}

public struct JevResult: Sendable {
    public let score: Double
    public let reason: String
    public let cost: Double
}

public enum JevClient {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    /// Blocking call; run off the main thread.
    public static func classify(text: String, senderInContacts: Bool, config: JevConfig) throws -> JevResult {
        var body: [String: Any] = [
            "model": config.model,
            "state": JevPrompt.state(text: text, senderInContacts: senderInContacts),
            "questions": JevPrompt.questions,
        ]
        if config.provider == .openrouter && config.requireNoDataCollection {
            body["provider"] = ["data_collection": "deny"]
        }
        var req = URLRequest(url: config.provider.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if config.provider == .openrouter {
            req.setValue("iMessage Bridge", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(BridgeError.failed("no response"))
        session.dataTask(with: req) { data, resp, err in
            if let http = resp as? HTTPURLResponse {
                result = .success((http.statusCode, data ?? Data()))
            } else {
                result = .failure(err ?? BridgeError.failed("no response"))
            }
            sem.signal()
        }.resume()
        sem.wait()

        let (status, data) = try result.get()
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200 else {
            throw BridgeError.failed("\(config.provider.label) returned HTTP \(status): \(errorMessage(obj) ?? String(decoding: data.prefix(300), as: UTF8.self))")
        }
        // TypeSafe may wrap the payload in {code, message, data}.
        let payload = obj["answers"] != nil ? obj : (obj["data"] as? [String: Any] ?? obj)
        guard let answers = payload["answers"] as? [String: Any],
              let (score, reason) = JevPrompt.evaluate(answers) else {
            throw BridgeError.failed("unexpected response from \(config.provider.label): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let cost = ((payload["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue ?? 0
        return JevResult(score: score, reason: reason, cost: cost)
    }

    static func errorMessage(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = obj["message"] as? String { return m }
        if let m = obj["error"] as? String { return m }
        return nil
    }
}

/// Thread-safe verdict cache keyed by message row + text hash.
public final class VerdictCache: @unchecked Sendable {
    private var store: [String: ScreenVerdict] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let limit = 5000

    public init() {}

    static func key(_ item: ScreenItem) -> String {
        "\(item.rowID):\(Tokens.sha256Hex(item.text).prefix(16))"
    }

    func get(_ item: ScreenItem) -> ScreenVerdict? {
        lock.lock(); defer { lock.unlock() }
        return store[VerdictCache.key(item)]
    }

    func set(_ item: ScreenItem, _ v: ScreenVerdict) {
        lock.lock(); defer { lock.unlock() }
        let k = VerdictCache.key(item)
        if store[k] == nil { order.append(k) }
        store[k] = v
        if order.count > limit {
            for old in order.prefix(order.count - limit) { store[old] = nil }
            order.removeFirst(order.count - limit)
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        store = [:]
        order = []
    }
}

public struct ScreenSummary: Sendable {
    public var screened = 0
    public var flagged: [(sender: String, reason: String)] = []
    public var unavailable = 0
    public var lastError: String?
    public var cost = 0.0
}

/// Screens with local heuristics first, then Jev. Results are cached, so a
/// message is only sent to the provider once per app session.
public final class JevScreener: MessageScreener, @unchecked Sendable {
    public static let maxRemotePerCall = 200
    let config: JevConfig
    let cache: VerdictCache
    let onSummary: @Sendable (ScreenSummary) -> Void

    public init(config: JevConfig, cache: VerdictCache, onSummary: @escaping @Sendable (ScreenSummary) -> Void) {
        self.config = config
        self.cache = cache
        self.onSummary = onSummary
    }

    public func screen(_ items: [ScreenItem]) -> [Int64: ScreenVerdict] {
        var out: [Int64: ScreenVerdict] = [:]
        var summary = ScreenSummary()
        var remote: [ScreenItem] = []

        for item in items {
            if !config.scanContacts && item.senderName != nil { continue }
            if let cached = cache.get(item) {
                out[item.rowID] = cached
                if cached.isFlagged { summary.flagged.append((item.senderLabel, cached.reason)) }
                continue
            }
            if let reason = InjectionHeuristics.blatantReason(item.text) {
                let v = ScreenVerdict(kind: .flagged, score: 1, reason: reason)
                cache.set(item, v)
                out[item.rowID] = v
                summary.flagged.append((item.senderLabel, reason))
                continue
            }
            remote.append(item)
        }

        let toSend = Array(remote.prefix(JevScreener.maxRemotePerCall))
        for item in remote.dropFirst(JevScreener.maxRemotePerCall) {
            out[item.rowID] = ScreenVerdict(kind: .unavailable, score: nil, reason: "not screened (too many messages in one request)")
            summary.unavailable += 1
        }

        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: toSend.count) { i in
            let item = toSend[i]
            let verdict: ScreenVerdict
            var cost = 0.0
            var err: String?
            do {
                let r = try JevClient.classify(text: item.text, senderInContacts: item.senderName != nil, config: config)
                cost = r.cost
                verdict = r.score >= config.threshold
                    ? ScreenVerdict(kind: .flagged, score: r.score, reason: r.reason)
                    : ScreenVerdict(kind: .clean, score: r.score, reason: "")
                cache.set(item, verdict)
            } catch {
                err = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                verdict = ScreenVerdict(kind: .unavailable, score: nil, reason: "screening failed")
            }
            lock.lock()
            out[item.rowID] = verdict
            summary.screened += err == nil ? 1 : 0
            summary.cost += cost
            switch verdict.kind {
            case .flagged: summary.flagged.append((item.senderLabel, verdict.reason))
            case .unavailable: summary.unavailable += 1; summary.lastError = err
            case .clean: break
            }
            lock.unlock()
        }
        if summary.screened > 0 || !summary.flagged.isEmpty || summary.unavailable > 0 {
            onSummary(summary)
        }
        return out
    }
}
