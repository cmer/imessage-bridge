import AppKit
import BridgeCore
import Foundation
import ServiceManagement

enum AuthResult {
    case ok(AgentRecord)
    case missing
    case invalid
    case networkNotAllowed(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    nonisolated static let version = "0.1.0"
    static let maxPendingPairings = 3
    static let pairingTTL: TimeInterval = 600
    nonisolated static let sendsPerHour = 30

    @Published private(set) var agents: [AgentRecord] = []
    @Published private(set) var settings = BridgeSettings()
    @Published private(set) var pairings: [PairingRequest] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var fullDiskAccess = false
    @Published private(set) var automation: AutomationStatus = .notDetermined
    @Published private(set) var loopbackStatus = "Starting…"
    @Published private(set) var networkStatus = "Off"
    @Published private(set) var tlsFingerprint: String?
    @Published private(set) var launchAtLogin = false

    let service = MessageService()
    let supportDir: URL
    private var loopback: HTTPServer?
    private var network: HTTPServer?
    private var router: Router!
    private var sendHistory: [UUID: [Date]] = [:]
    private var timers: [Timer] = []

    var configURL: URL { supportDir.appendingPathComponent("config.json") }
    var tlsDir: URL { supportDir.appendingPathComponent("tls") }
    var localURL: String { "http://127.0.0.1:\(settings.port)" }
    var networkURL: String { "https://\(AppState.localHostName):\(settings.networkPort)" }

    static var localHostName: String {
        if let n = SCDynamicStoreCopyLocalHostNameCompat() { return n + ".local" }
        return ProcessInfo.processInfo.hostName
    }

    /// Path of the bundled CLI, which agents run.
    var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/imessage-bridge").path
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("iMessage Bridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        load()
        router = Router(state: self, service: service)
    }

    func start() {
        startServers()
        refreshPermissions()
        refreshLaunchAtLogin()
        timers.append(Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in AppState.shared.refreshPermissions() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in AppState.shared.expirePairings() }
        })
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: configURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let cfg = try? dec.decode(BridgeConfig.self, from: data) {
            settings = cfg.settings
            agents = cfg.agents
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(BridgeConfig(settings: settings, agents: agents)) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    // MARK: Servers

    func startServers() {
        loopback?.stop()
        network?.stop()
        loopback = nil
        network = nil
        let router = self.router!

        let port = settings.port
        do {
            let s = try HTTPServer(port: port, identity: nil) { req in await router.handle(req) }
            s.onState = { st in
                Task { @MainActor in
                    AppState.shared.loopbackStatus = st == "ready" ? "Listening on 127.0.0.1:\(port)" : "Local server \(st)"
                }
            }
            s.start()
            loopback = s
        } catch {
            loopbackStatus = "Local server failed: \(error.localizedDescription)"
        }

        guard settings.networkEnabled else {
            networkStatus = "Off"
            return
        }
        let netPort = settings.networkPort
        do {
            let (identity, fp) = try TLSIdentityStore.loadOrCreate(in: tlsDir)
            tlsFingerprint = fp
            let s = try HTTPServer(port: netPort, identity: identity) { req in await router.handle(req) }
            s.onState = { st in
                Task { @MainActor in
                    AppState.shared.networkStatus = st == "ready" ? "Listening with TLS on port \(netPort)" : "Network server \(st)"
                }
            }
            s.start()
            network = s
        } catch {
            networkStatus = "Network server failed: \(error.localizedDescription)"
        }
    }

    func updateSettings(_ new: BridgeSettings) {
        let restart = new.port != settings.port || new.networkEnabled != settings.networkEnabled || new.networkPort != settings.networkPort
        settings = new
        save()
        if restart { startServers() }
    }

    func regenerateCertificate() {
        do {
            let (_, fp) = try TLSIdentityStore.regenerate(in: tlsDir)
            tlsFingerprint = fp
            if settings.networkEnabled { startServers() }
        } catch {
            networkStatus = "Certificate error: \(error.localizedDescription)"
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        fullDiskAccess = MessagesDB.canRead()
        Task.detached {
            let status = Messaging.automationStatus(ask: false)
            await MainActor.run { AppState.shared.automation = status }
        }
    }

    func requestAutomation() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Messaging.messagesBundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    let status = Messaging.automationStatus(ask: true)
                    Task { @MainActor in AppState.shared.automation = status }
                }
            }
        }
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log(agent: "App", action: "launch_at_login", detail: error.localizedDescription, ok: false)
        }
        refreshLaunchAtLogin()
    }

    // MARK: Agents

    func authenticate(_ token: String?, isNetwork: Bool) -> AuthResult {
        guard let token, !token.isEmpty else { return .missing }
        let hash = Tokens.sha256Hex(token)
        guard let idx = agents.firstIndex(where: { $0.tokenHash == hash }) else { return .invalid }
        if isNetwork && !agents[idx].allowNetwork { return .networkNotAllowed(agents[idx].name) }
        let now = Date()
        if (agents[idx].lastUsedAt ?? .distantPast).timeIntervalSince(now) < -60 {
            agents[idx].lastUsedAt = now
            save()
        }
        return .ok(agents[idx])
    }

    func update(_ agent: AgentRecord) {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        var a = agent
        a.tokenHash = agents[idx].tokenHash      // never changed from the UI
        a.lastUsedAt = agents[idx].lastUsedAt    // the UI copy may be stale
        if !a.canSend { a.confirmSends = true }
        agents[idx] = a
        save()
    }

    func revoke(_ id: UUID) {
        if let a = agents.first(where: { $0.id == id }) {
            log(agent: a.name, action: "revoked", detail: "access removed", ok: true)
        }
        agents.removeAll { $0.id == id }
        save()
    }

    /// Sliding one-hour cap on sends per agent.
    func takeSendQuota(_ id: UUID) -> Bool {
        let cutoff = Date().addingTimeInterval(-3600)
        var recent = (sendHistory[id] ?? []).filter { $0 > cutoff }
        guard recent.count < AppState.sendsPerHour else { return false }
        recent.append(Date())
        sendHistory[id] = recent
        return true
    }

    // MARK: Pairing

    func beginPairing(name: String, read: Bool, send: Bool, isNetwork: Bool, remote: String) throws -> [String: Any] {
        guard settings.allowPairing else {
            throw BridgeError.forbidden("Pairing is turned off in iMessage Bridge settings.")
        }
        expirePairings()
        guard pairings.filter(\.isPending).count < AppState.maxPendingPairings else {
            throw BridgeError.forbidden("Too many pairing requests are waiting. Approve or deny them in the app first.")
        }
        let secret = Tokens.random(bytes: 24)
        let req = PairingRequest(
            id: Tokens.random(bytes: 12),
            code: Tokens.pairingCode(),
            agentName: name,
            pollSecretHash: Tokens.sha256Hex(secret),
            viaNetwork: isNetwork,
            remote: remote,
            requestedRead: read,
            requestedSend: send
        )
        pairings.append(req)
        log(agent: name, action: "pair_request", detail: isNetwork ? "from \(remote)" : "from this Mac", ok: true)
        WindowManager.shared.showPairing(req.id)
        return [
            "request_id": req.id,
            "poll_secret": secret,
            "code": req.code,
            "expires_in": Int(AppState.pairingTTL),
        ]
    }

    func pairing(_ id: String) -> PairingRequest? { pairings.first { $0.id == id } }

    /// nil when the request is unknown, expired or the secret is wrong.
    func pollPairing(id: String, secret: String) -> [String: Any]? {
        guard let idx = pairings.firstIndex(where: { $0.id == id }),
              pairings[idx].pollSecretHash == Tokens.sha256Hex(secret) else { return nil }
        switch pairings[idx].status {
        case .pending:
            return ["status": "pending"]
        case .denied:
            pairings.remove(at: idx)
            return ["status": "denied"]
        case .approved(let token, let agentID):
            pairings.remove(at: idx)
            guard let a = agents.first(where: { $0.id == agentID }) else { return ["status": "denied"] }
            return [
                "status": "approved",
                "token": token,
                "agent": a.name,
                "permissions": ["read": a.canRead, "send": a.canSend, "confirm_sends": a.confirmSends,
                                "network": a.allowNetwork, "chats": a.chatAccess.rawValue],
            ]
        }
    }

    func approvePairing(_ id: String, read: Bool, send: Bool, confirmSends: Bool, allowNetwork: Bool) {
        guard let idx = pairings.firstIndex(where: { $0.id == id }), pairings[idx].isPending else { return }
        let req = pairings[idx]
        let token = Tokens.newAgentToken()
        // Re-pairing under the same name replaces the old agent and its token.
        agents.removeAll { $0.name.caseInsensitiveCompare(req.agentName) == .orderedSame }
        let agent = AgentRecord(
            name: req.agentName,
            tokenHash: Tokens.sha256Hex(token),
            tokenHint: String(token.suffix(4)),
            canRead: read,
            canSend: send,
            confirmSends: send ? confirmSends : true,
            allowNetwork: allowNetwork || req.viaNetwork
        )
        agents.append(agent)
        pairings[idx].status = .approved(token: token, agentID: agent.id)
        save()
        log(agent: agent.name, action: "paired", detail: agent.permissionSummary, ok: true)
        WindowManager.shared.closePairing(id)
    }

    func denyPairing(_ id: String) {
        guard let idx = pairings.firstIndex(where: { $0.id == id }) else { return }
        pairings[idx].status = .denied
        log(agent: pairings[idx].agentName, action: "pair_denied", detail: "", ok: false)
        WindowManager.shared.closePairing(id)
    }

    func expirePairings() {
        let cutoff = Date().addingTimeInterval(-AppState.pairingTTL)
        for p in pairings where p.createdAt < cutoff { WindowManager.shared.closePairing(p.id) }
        pairings.removeAll { $0.createdAt < cutoff }
    }

    // MARK: Activity

    func log(agent: String, action: String, detail: String, ok: Bool) {
        activity.insert(ActivityEntry(agent: agent, action: action, detail: detail, ok: ok), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
    }
}

import SystemConfiguration

private func SCDynamicStoreCopyLocalHostNameCompat() -> String? {
    SCDynamicStoreCopyLocalHostName(nil) as String?
}
