import BridgeCore
import Combine
import Foundation

/// What the agent page shows about an agent's webhook. Kept in memory only.
struct WebhookStatus: Equatable {
    var lastAttempt: Date?
    var lastResult: WebhookResult?
    var lastSuccess: Date?
    /// When the current run of failed attempts began; nil while deliveries work.
    var failingSince: Date?
    /// Failed attempts in a row.
    var failures = 0
    /// Waiting to try the current event again.
    var retrying = false
    var pending = 0
}

/// Posts new-message events to the webhook of each agent that has one.
///
/// Each agent has its own queue, delivered in order, one event at a time.
/// While the receiver fails, the event at the front is retried with backoff
/// under the same webhook-id and the rest wait behind it. Once the receiver
/// has been failing for `Webhook.giveUpAfter` (or answers 410 Gone), the
/// webhook is turned off and the waiting events are dropped.
@MainActor
final class WebhookDispatcher: ObservableObject {
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
        while !Task.isCancelled {
            guard let (agent, url) = current(id) else { return }
            let req = Webhook.request(url: url, id: event.id, body: body, secret: secret(for: id),
                                      userAgent: WebhookDispatcher.userAgent)
            let result = await sender.send(req)
            guard !Task.isCancelled else { return }
            let now = Date()
            var s = status[id] ?? WebhookStatus()
            s.lastAttempt = now
            s.lastResult = result
            if result.ok {
                if let since = s.failingSince {
                    state.log(agent: agent.name, action: "webhook_delivered",
                              detail: "working again after failing for \(WebhookDispatcher.duration(now.timeIntervalSince(since)))", ok: true)
                }
                s.lastSuccess = now
                s.failingSince = nil
                s.failures = 0
                s.retrying = false
                status[id] = s
                return
            }
            let since = s.failingSince ?? now
            if s.failingSince == nil {
                // Once per outage, not per attempt.
                state.log(agent: agent.name, action: "webhook_failed",
                          detail: "\(result.summary); retrying for up to \(WebhookDispatcher.duration(Webhook.giveUpAfter))", ok: false)
            }
            s.failingSince = since
            s.failures += 1
            switch Webhook.next(after: result, failingSince: since, failures: s.failures, now: now) {
            case .turnOff:
                s.retrying = false
                status[id] = s
                turnOff(agent, last: result, failingSince: since, now: now)
                return
            case .retry(let delay):
                s.retrying = true
                status[id] = s
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func turnOff(_ agent: AgentRecord, last: WebhookResult, failingSince: Date, now: Date) {
        var a = agent
        let note: String
        if last.status == 410 {
            note = "Turned off because the receiver answered HTTP 410 (Gone)."
        } else {
            note = "Turned off after failing for \(WebhookDispatcher.duration(now.timeIntervalSince(failingSince))). The last attempt got \(last.summary)."
        }
        a.eventSettings.webhookEnabled = false
        a.eventSettings.webhookDisabledNote = note
        queues[a.id]?.removeAll()
        status[a.id]?.pending = 0
        state.update(a)
        state.log(agent: a.name, action: "webhook_disabled", detail: note, ok: false)
    }

    /// "15 minutes", "40 seconds".
    nonisolated static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t < 60 ? [.second] : t < 3600 ? [.minute] : [.hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: max(1, t.rounded())) ?? "\(Int(t)) seconds"
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
                status[id]?.failingSince = nil
                status[id]?.failures = 0
            }
        }
        known = now
    }
}
