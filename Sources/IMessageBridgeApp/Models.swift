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
        case .high: return "High (flags more)"
        case .balanced: return "Balanced"
        case .low: return "Low (flags less)"
        }
    }
}

struct DetectionSettings: Codable, Equatable {
    var enabled = false
    var provider: JevProvider = .typesafe
    var model = ""                          // empty = provider default
    var sensitivity: DetectionSensitivity = .balanced
    var scanContacts = false
    var hideFlagged = true
    var requireNoDataCollection = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectionSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = try c.decodeIfPresent(JevProvider.self, forKey: .provider) ?? d.provider
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        sensitivity = try c.decodeIfPresent(DetectionSensitivity.self, forKey: .sensitivity) ?? d.sensitivity
        scanContacts = try c.decodeIfPresent(Bool.self, forKey: .scanContacts) ?? d.scanContacts
        hideFlagged = try c.decodeIfPresent(Bool.self, forKey: .hideFlagged) ?? d.hideFlagged
        requireNoDataCollection = try c.decodeIfPresent(Bool.self, forKey: .requireNoDataCollection) ?? d.requireNoDataCollection
    }
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
