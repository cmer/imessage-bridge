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
    public var requireNoDataCollection: Bool

    public init(provider: JevProvider, apiKey: String, model: String, requireNoDataCollection: Bool) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model.isEmpty ? provider.defaultModel : model
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
