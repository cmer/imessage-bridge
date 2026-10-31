import Foundation

public struct ScreeningConfig: Sendable {
    /// Score at or above which a layer flags a message.
    public var threshold: Double
    /// Also screen senders who are in the owner's contacts.
    public var scanContacts: Bool
    /// On-device model (Prompt Guard), if enabled.
    public var local: LocalInjectionClassifier?
    /// Remote model (Jev), if enabled.
    public var jev: JevConfig?

    public init(threshold: Double, scanContacts: Bool, local: LocalInjectionClassifier?, jev: JevConfig?) {
        self.threshold = threshold
        self.scanContacts = scanContacts
        self.local = local
        self.jev = jev
    }
}

public struct ScreenSummary: Sendable {
    public var screened = 0
    public var flagged: [(sender: String, reason: String)] = []
    public var unavailable = 0
    public var lastError: String?
    public var cost = 0.0
}

/// Screens each message in layers, stopping at the first that flags it:
///
/// 1. Local heuristics (blatant phrases, hidden Unicode text).
/// 2. Prompt Guard on this Mac, when enabled and installed.
/// 3. Jev, when enabled with an API key.
///
/// A message counts as screened only when every enabled layer ran. If one
/// fails (Jev unreachable, model missing), it is "unavailable" even when an
/// earlier layer passed it, so the agent that reads it is still held to
/// confirmations. Verdicts are cached, so a message goes through each layer
/// once per app session.
public final class LayeredScreener: MessageScreener, @unchecked Sendable {
    public static let maxRemotePerCall = 200
    static let localReason = "looks like a jailbreak or an attempt to override an assistant's instructions"

    let config: ScreeningConfig
    let cache: VerdictCache
    let classifyRemote: @Sendable (String, Bool, JevConfig) throws -> JevResult
    let onSummary: @Sendable (ScreenSummary) -> Void

    public init(config: ScreeningConfig, cache: VerdictCache,
                classifyRemote: @escaping @Sendable (String, Bool, JevConfig) throws -> JevResult = {
                    try JevClient.classify(text: $0, senderInContacts: $1, config: $2)
                },
                onSummary: @escaping @Sendable (ScreenSummary) -> Void) {
        self.config = config
        self.cache = cache
        self.classifyRemote = classifyRemote
        self.onSummary = onSummary
    }

    public func screen(_ items: [ScreenItem]) -> [Int64: ScreenVerdict] {
        var out: [Int64: ScreenVerdict] = [:]
        var summary = ScreenSummary()
        var remote: [ScreenItem] = []

        func finish(_ item: ScreenItem, _ v: ScreenVerdict, error: String? = nil) {
            out[item.rowID] = v
            switch v.kind {
            case .flagged:
                cache.set(item, v)
                summary.screened += 1
                summary.flagged.append((item.senderLabel, v.reason))
            case .clean:
                cache.set(item, v)
                summary.screened += 1
            case .unavailable:
                summary.unavailable += 1
                summary.lastError = error ?? summary.lastError
            }
        }

        for item in items {
            if !config.scanContacts && item.senderName != nil { continue }
            if let cached = cache.get(item) {
                out[item.rowID] = cached
                if cached.isFlagged { summary.flagged.append((item.senderLabel, cached.reason)) }
                continue
            }
            if let reason = InjectionHeuristics.blatantReason(item.text) {
                finish(item, ScreenVerdict(kind: .flagged, score: 1, reason: reason))
                continue
            }
            var localScore: Double?
            if let local = config.local {
                do {
                    let p = try local.attackProbability(InjectionHeuristics.normalizedForScreening(item.text))
                    if p >= config.threshold {
                        finish(item, ScreenVerdict(kind: .flagged, score: p, reason: LayeredScreener.localReason))
                        continue
                    }
                    localScore = p
                } catch {
                    finish(item, ScreenVerdict(kind: .unavailable, score: nil, reason: "on-device check failed"),
                           error: "On-device check: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                    continue
                }
            }
            if config.jev != nil {
                remote.append(item)
            } else {
                finish(item, ScreenVerdict(kind: .clean, score: localScore, reason: ""))
            }
        }

        if let jev = config.jev, !remote.isEmpty {
            let toSend = Array(remote.prefix(LayeredScreener.maxRemotePerCall))
            for item in remote.dropFirst(LayeredScreener.maxRemotePerCall) {
                finish(item, ScreenVerdict(kind: .unavailable, score: nil, reason: "not screened (too many messages in one request)"))
            }
            var results = [(ScreenVerdict, Double, String?)?](repeating: nil, count: toSend.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: toSend.count) { i in
                let item = toSend[i]
                let r: (ScreenVerdict, Double, String?)
                do {
                    let j = try classifyRemote(item.text, item.senderName != nil, jev)
                    r = (j.score >= config.threshold
                            ? ScreenVerdict(kind: .flagged, score: j.score, reason: j.reason)
                            : ScreenVerdict(kind: .clean, score: j.score, reason: ""), j.cost, nil)
                } catch {
                    r = (ScreenVerdict(kind: .unavailable, score: nil, reason: "screening failed"), 0,
                         (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
                lock.lock()
                results[i] = r
                lock.unlock()
            }
            for (item, r) in zip(toSend, results) {
                guard let (verdict, cost, err) = r else { continue }
                summary.cost += cost
                finish(item, verdict, error: err)
            }
        }

        if summary.screened > 0 || !summary.flagged.isEmpty || summary.unavailable > 0 {
            onSummary(summary)
        }
        return out
    }
}
