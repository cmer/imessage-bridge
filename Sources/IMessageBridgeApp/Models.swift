import BridgeCore
import Foundation

enum ChatAccess: String, Codable, CaseIterable {
    case all
    case selected
}

struct AgentRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tokenHash: String
    var tokenHint: String           // last 4 chars, for display only
    var canRead = true
    var canSend = false
    var confirmSends = true
    var allowNetwork = false
    var redactSensitive = true
    var chatAccess: ChatAccess = .all
    var allowedChats: [String] = []
    var createdAt = Date()
    var lastUsedAt: Date?
    /// New-message events. Optional so configs from before events keep loading.
    var events: EventSettings?

    var eventSettings: EventSettings {
        get { events ?? EventSettings() }
        set { events = newValue }
    }

    var scope: ReadScope {
        ReadScope(allowedChats: chatAccess == .all ? nil : Set(allowedChats), redact: redactSensitive)
    }

    var permissionSummary: String {
        var parts: [String] = []
        if canRead { parts.append("read") }
        if canSend { parts.append(confirmSends ? "send (asks)" : "send") }
        if parts.isEmpty { parts.append("no access") }
        if chatAccess == .selected { parts.append("\(allowedChats.count) chats") }
        if allowNetwork { parts.append("network") }
        return parts.joined(separator: " · ")
    }
}

/// How an agent hears about new messages: a stream it connects to
/// (GET /v1/events, any agent that can read), and optionally a webhook.
struct EventSettings: Codable, Equatable {
    /// Put message text (redacted and screened) in events, not just who wrote.
    var includeText = false
    var webhookEnabled = false
    var webhookURL = ""
    /// Why the app turned the webhook off (repeated failures), shown until it's turned back on.
    var webhookDisabledNote: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EventSettings()
        includeText = try c.decodeIfPresent(Bool.self, forKey: .includeText) ?? d.includeText
        webhookEnabled = try c.decodeIfPresent(Bool.self, forKey: .webhookEnabled) ?? d.webhookEnabled
        webhookURL = try c.decodeIfPresent(String.self, forKey: .webhookURL) ?? d.webhookURL
        webhookDisabledNote = try c.decodeIfPresent(String.self, forKey: .webhookDisabledNote)
    }
}

struct BridgeSettings: Codable, Equatable {
    var port: UInt16 = 7542
    var networkEnabled = false
    var networkPort: UInt16 = 7543
    var allowPairing = true

    // Recipients
    var confirmUnknownRecipients = true
    var contactsAreAllowed = false
    var allowedRecipients: [String] = []

    var detection = DetectionSettings()

    init() {}

    // Missing keys fall back to defaults so older config files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BridgeSettings()
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? d.networkEnabled
        networkPort = try c.decodeIfPresent(UInt16.self, forKey: .networkPort) ?? d.networkPort
        allowPairing = try c.decodeIfPresent(Bool.self, forKey: .allowPairing) ?? d.allowPairing
        confirmUnknownRecipients = try c.decodeIfPresent(Bool.self, forKey: .confirmUnknownRecipients) ?? d.confirmUnknownRecipients
        contactsAreAllowed = try c.decodeIfPresent(Bool.self, forKey: .contactsAreAllowed) ?? d.contactsAreAllowed
        allowedRecipients = try c.decodeIfPresent([String].self, forKey: .allowedRecipients) ?? d.allowedRecipients
        detection = try c.decodeIfPresent(DetectionSettings.self, forKey: .detection) ?? d.detection
    }

    func isAllowedRecipient(_ handle: String, isContact: Bool) -> Bool {
        if contactsAreAllowed && isContact { return true }
        let n = ContactBook.normalize(handle)
        return !n.isEmpty && allowedRecipients.contains { ContactBook.normalize($0) == n }
    }
}

enum DetectionSensitivity: Double, Codable, CaseIterable {
    case high = 0.3
    case balanced = 0.5
    case low = 0.7

    var label: String {
        switch self {
        case .high: return "Strict"
        case .balanced: return "Balanced"
        case .low: return "Relaxed"
        }
    }
}

/// Screening is on when at least one check is on and usable (the model is
/// installed, or a Jev key is saved). There is no separate master switch.
struct DetectionSettings: Codable, Equatable {
    var useLocalModel = true                // Prompt Guard on this Mac, once downloaded
    var useJev = true                       // Jev, once an API key is saved
    var provider: JevProvider = .typesafe
    var model = ""                          // empty = provider default
    var sensitivity: DetectionSensitivity = .balanced
    var scanContacts = false
    var hideFlagged = true
    var requireNoDataCollection = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case useLocalModel, useJev, provider, model, sensitivity, scanContacts, hideFlagged, requireNoDataCollection
        case enabled   // read only: the old master switch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectionSettings()
        // Configs from before the per-check switches had one master switch;
        // carry it over so screening someone turned off stays off.
        let legacy = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        useLocalModel = try c.decodeIfPresent(Bool.self, forKey: .useLocalModel) ?? legacy ?? d.useLocalModel
        useJev = try c.decodeIfPresent(Bool.self, forKey: .useJev) ?? legacy ?? d.useJev
        provider = try c.decodeIfPresent(JevProvider.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        sensitivity = try c.decodeIfPresent(DetectionSensitivity.self, forKey: .sensitivity) ?? d.sensitivity
        scanContacts = try c.decodeIfPresent(Bool.self, forKey: .scanContacts) ?? d.scanContacts
        hideFlagged = try c.decodeIfPresent(Bool.self, forKey: .hideFlagged) ?? d.hideFlagged
        requireNoDataCollection = try c.decodeIfPresent(Bool.self, forKey: .requireNoDataCollection) ?? d.requireNoDataCollection
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(useLocalModel, forKey: .useLocalModel)
        try c.encode(useJev, forKey: .useJev)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(scanContacts, forKey: .scanContacts)
        try c.encode(hideFlagged, forKey: .hideFlagged)
        try c.encode(requireNoDataCollection, forKey: .requireNoDataCollection)
    }
}

/// One sample message run through each enabled check (Safety page test).
struct DetectionSample: Identifiable {
    struct Verdict: Identifiable {
        var id: String { check }
        let check: String
        let flagged: Bool?          // nil: the check failed
        let note: String
    }

    let id: Int
    let name: String
    let verdicts: [Verdict]
}

/// Progress of downloading the on-device model.
enum ModelDownload: Equatable {
    case idle
    case downloading(Double)
    case installing
    case failed(String)
}

/// An agent that recently read a flagged (or unscreened) message must get
/// confirmation for its next sends, whatever its own settings say.
struct Taint {
    let until: Date
    let reason: String
}

struct BridgeConfig: Codable {
    var settings = BridgeSettings()
    var agents: [AgentRecord] = []
}

struct PairingRequest: Identifiable {
    enum Status {
        case pending
        case approved(token: String, agentID: UUID)
        case denied
    }

    let id: String
    let code: String
    let agentName: String
    let pollSecretHash: String
    let createdAt = Date()
    let viaNetwork: Bool
    let remote: String
    var requestedRead: Bool
    var requestedSend: Bool
    var status: Status = .pending

    var isPending: Bool {
        if case .pending = status { return true }
        return false
    }

    var formattedCode: String { String(code.prefix(3)) + " " + String(code.suffix(3)) }
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    var date = Date()
    let agent: String
    let action: String
    let detail: String
    let ok: Bool
}
