import BridgeCore
import Combine
import Foundation

/// What the agent page shows about an agent's webhook. Kept in memory only.
struct WebhookStatus: Equatable {
    var lastAttempt: Date?
    var lastResult: WebhookResult?
    var lastSuccess: Date?
    /// Events in a row that couldn't be delivered, even after retries.
    var consecutiveFailures = 0
    /// Waiting to try the current event again.
    var retrying = false
    var pending = 0
}

/// Posts new-message events to the webhook of each agent that has one.
///
/// Each agent has its own queue, delivered in order, one event at a time.
/// A failed attempt is retried with backoff (Webhook.retryDelays) under the
/// same webhook-id; an event that still fails counts as one failed delivery.
/// After `maxConsecutiveFailures` of those in a row the webhook is turned off.
@MainActor
final class WebhookDispatcher: ObservableObject {
    static let maxConsecutiveFailures = 10
    static let queueCapacity = 200
    nonisolated static var userAgent: String { "iMessageBridge/\(AppState.version)" }
    nonisolated static func secretAccount(_ id: UUID) -> String { "webhook-\(id.uuidString.lowercased())" }

    @Published private(set) var status: [UUID: WebhookStatus] = [:]

    private unowned let state: AppState
    private let sender = WebhookSender()
    private var queues: [UUID: WebhookQueue<MessageEvent>] = [:]
    private var workers: [UUID: (gen: UUID, task: Task<Void, Never>)] = [:]
    private var dropLogged: Set<UUID> = []
    private var secrets: [UUID: String] = [:]
    private var known: [UUID: AgentRecord] = [:]
    private var building: Task<Void, Never>?
    private var subscription: UUID?
    private var agentsSink: AnyCancellable?

    init(state: AppState) {
        self.state = state
        if state.isDemo {
            let now = Date()
            for a in state.agents where a.eventSettings.webhookEnabled {
                status[a.id] = WebhookStatus(lastAttempt: now.addingTimeInterval(-240), lastResult: WebhookResult(status: 200),
                                             lastSuccess: now.addingTimeInterval(-240))
            }
        }
    }

    func start() {
        guard !state.isDemo, subscription == nil else { return }
        known = Dictionary(state.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        agentsSink = state.$agents.sink { [weak self] agents in
            MainActor.assumeIsolated { self?.agentsChanged(agents) }
        }
        // The feed calls back on the watcher's queue; hop to the main queue in
        // order, so batches are handled in the order they arrived.
        subscription = state.feed.subscribe { [weak self] msgs in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(msgs) } }
        }
    }

    // MARK: Secrets

    /// The agent's signing secret, made and saved in the Keychain the first time.
    @discardableResult
    func secret(for id: UUID) -> String {
        if state.isDemo { return "whsec_ZGVtbyBzZWNyZXQgZm9yIHRoZSB3ZWJzaXRlIHNjcmVlbnNob3Q=" }
        if let s = secrets[id] ?? Keychain.get(WebhookDispatcher.secretAccount(id)) {
            secrets[id] = s
            return s
        }
        return newSecret(for: id)
    }

    /// Replaces the signing secret; the receiver needs the new one.
    @discardableResult
    func newSecret(for id: UUID) -> String {
        guard !state.isDemo else { return secret(for: id) }
        let s = WebhookSignature.newSecret()
        Keychain.set(s, for: WebhookDispatcher.secretAccount(id))
        secrets[id] = s
        if let a = state.agents.first(where: { $0.id == id }) {
            state.log(agent: a.name, action: "webhook_secret", detail: "new signing secret", ok: true)
        }
        return s
    }

    // MARK: Test

    /// Sends a `webhook.test` event once, now, without retries.
    func sendTest(_ agent: AgentRecord, url raw: String) async -> WebhookResult {
        let url: URL
        do { url = try Webhook.validate(raw) } catch {
            return WebhookResult(status: nil, error: error.localizedDescription)
        }
        if state.isDemo { return WebhookResult(status: 200) }
        let test = Webhook.testEvent(agent: agent.name)
        let req = Webhook.request(url: url, id: test.id, body: test.body, secret: secret(for: agent.id),
                                  userAgent: WebhookDispatcher.userAgent)
        return await sender.send(req)
    }

    // MARK: Delivery

    private func webhookURL(_ a: AgentRecord) -> URL? {
        guard a.canRead, a.eventSettings.webhookEnabled else { return nil }
        return try? Webhook.validate(a.eventSettings.webhookURL)
    }

    private func current(_ id: UUID) -> (AgentRecord, URL)? {
        guard let a = state.agents.first(where: { $0.id == id }), let url = webhookURL(a) else { return nil }
        return (a, url)
    }

    private func receive(_ msgs: [Message]) {
        let jobs = state.agents.filter { webhookURL($0) != nil }
            .map { (id: $0.id, name: $0.name, scope: state.scope(for: $0), includeText: $0.eventSettings.includeText) }
        guard !jobs.isEmpty else { return }
        let service = state.service
        let previous = building
        building = Task {
            await previous?.value
            let built = await Task.detached { () -> [(UUID, String, Result<[MessageEvent], Error>)] in
                jobs.map { job in
                    (job.id, job.name, Result { try service.events(for: msgs, scope: job.scope, includeText: job.includeText) })
                }
            }.value
            for (id, name, result) in built {
                switch result {
                case .success(let events): enqueue(events, for: id)
                case .failure(let error):
                    state.log(agent: name, action: "webhook_failed",
                              detail: "couldn't read new messages: \((error as? LocalizedError)?.errorDescription ?? "\(error)")", ok: false)
                }
            }
        }
    }

    private func enqueue(_ events: [MessageEvent], for id: UUID) {
        guard !events.isEmpty, let (agent, _) = current(id) else { return }
        var q = queues[id] ?? WebhookQueue(capacity: WebhookDispatcher.queueCapacity)
        let dropped = q.append(contentsOf: events)
        queues[id] = q
        status[id, default: WebhookStatus()].pending = q.count
        if dropped > 0, !dropLogged.contains(id) {
            dropLogged.insert(id)
            state.log(agent: agent.name, action: "webhook_dropped",
                      detail: "more than \(WebhookDispatcher.queueCapacity) events waiting; dropping the oldest", ok: false)
        }
        if workers[id] == nil {
            let gen = UUID()
            workers[id] = (gen, Task { await self.run(id, gen: gen) })
        }
    }

    private func run(_ id: UUID, gen: UUID) async {
        while !Task.isCancelled, let event = queues[id]?.popFirst() {
            status[id, default: WebhookStatus()].pending = queues[id]?.count ?? 0
            await deliver(event, to: id)
        }
        // A cancelled worker may already have been replaced by a new one.
        if workers[id]?.gen == gen {
            workers[id] = nil
            dropLogged.remove(id)
        }
    }

    private func stopWorker(_ id: UUID) {
        workers[id]?.task.cancel()
        workers[id] = nil
        queues[id] = nil
        dropLogged.remove(id)
    }

    private func deliver(_ event: MessageEvent, to id: UUID) async {
        let body = event.json
        var attempt = 1
        while !Task.isCancelled {
            guard let (agent, url) = current(id) else { return }
            let req = Webhook.request(url: url, id: event.id, body: body, secret: secret(for: id),
                                      userAgent: WebhookDispatcher.userAgent)
            let result = await sender.send(req)
            guard !Task.isCancelled else { return }
            var s = status[id] ?? WebhookStatus()
            s.lastAttempt = Date()
            s.lastResult = result
            if result.ok {
                if s.consecutiveFailures > 0 {
                    state.log(agent: agent.name, action: "webhook_delivered",
                              detail: "working again after \(s.consecutiveFailures) failed deliver\(s.consecutiveFailures == 1 ? "y" : "ies")", ok: true)
                }
                s.lastSuccess = s.lastAttempt
                s.consecutiveFailures = 0
                s.retrying = false
                status[id] = s
                return
            }
            if result.retryable, let delay = Webhook.retryDelay(afterAttempt: attempt) {
                s.retrying = true
                status[id] = s
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
                continue
            }
            s.retrying = false
            s.consecutiveFailures += 1
            status[id] = s
            state.log(agent: agent.name, action: "webhook_failed",
                      detail: "\(event.id): \(result.summary) after \(attempt) attempt\(attempt == 1 ? "" : "s")", ok: false)
            if s.consecutiveFailures >= WebhookDispatcher.maxConsecutiveFailures {
                turnOff(agent, last: result)
            }
            return
        }
    }

    private func turnOff(_ agent: AgentRecord, last: WebhookResult) {
        var a = agent
        let n = WebhookDispatcher.maxConsecutiveFailures
        a.eventSettings.webhookEnabled = false
        a.eventSettings.webhookDisabledNote = "Turned off after \(n) failed deliveries in a row. The last one got \(last.summary)."
        queues[a.id]?.removeAll()
        status[a.id]?.pending = 0
        state.update(a)
        state.log(agent: a.name, action: "webhook_disabled", detail: "\(n) failed deliveries in a row (last: \(last.summary))", ok: false)
    }

    /// Stops deliveries that no longer apply, starts over when a webhook is
    /// turned back on, and deletes the secret of an agent that was removed.
    private func agentsChanged(_ agents: [AgentRecord]) {
        let now = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in known.keys where now[id] == nil {
            stopWorker(id)
            status[id] = nil
            secrets[id] = nil
            Keychain.set(nil, for: WebhookDispatcher.secretAccount(id))
        }
        for (id, a) in now {
            let wasOn = known[id].map { webhookURL($0) != nil } ?? false
            let isOn = webhookURL(a) != nil
            if wasOn && !isOn {
                stopWorker(id)
                status[id]?.pending = 0
                status[id]?.retrying = false
            } else if !wasOn && isOn {
                status[id]?.consecutiveFailures = 0
            }
        }
        known = now
    }
}
