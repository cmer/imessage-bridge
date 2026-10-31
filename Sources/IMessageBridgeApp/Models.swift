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
    let date = Date()
    let agent: String
    let action: String
    let detail: String
    let ok: Bool
}
