import CryptoKit
import Security
import Foundation

/// One "new messages" event for an agent: the messages that arrived in one
/// chat during one check. `rowID` is the newest message's row, which also
/// serves as the stream's event ID for resuming.
public struct MessageEvent: @unchecked Sendable {
    public static let type = "message.received"

    public let id: String
    public let rowID: Int64
    public let payload: [String: Any]

    public var json: Data {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}

extension MessageService {
    /// Turns newly arrived messages into events for one agent: incoming
    /// messages only, limited to the chats its scope allows, one event per chat.
    ///
    /// Without `includeText` an event says who wrote and where, and the agent
    /// reads the messages through its tools, which screen them. With it, the
    /// text is redacted and screened exactly as the read tools do, so flagged
    /// messages arrive hidden and the screener's summary taints the agent.
    public func events(for msgs: [Message], scope: ReadScope, includeText: Bool, now: Date = Date()) throws -> [MessageEvent] {
        let inbound = msgs.filter { !$0.isFromMe && (scope.allowedChats?.contains($0.chatIdentifier) ?? true) }
        guard !inbound.isEmpty else { return [] }

        let chatsByRow = Dictionary(try openDB().chats().map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        let contacts = contacts()
        let verdicts = includeText ? screen(inbound, contacts, scope) : [:]

        var order: [String] = []
        var groups: [String: [Message]] = [:]
        for m in inbound {
            if groups[m.chatIdentifier] == nil { order.append(m.chatIdentifier) }
            groups[m.chatIdentifier, default: []].append(m)
        }

        return order.map { ident in
            let ms = groups[ident]!
            let chat = chatsByRow[ms[0].chatRowID]
            var senders: [String] = []
            for m in ms {
                let s = sender(m, contacts)
                if !senders.contains(s) { senders.append(s) }
            }
            var data: [String: Any] = [
                "chat": chat.map { label($0, contacts) } ?? ident,
                "chat_id": ident,
                "is_group": chat?.isGroup ?? false,
                "count": ms.count,
                "from": senders,
                "message_ids": ms.map(\.rowID),
                "first_ts": MessageService.ts(ms.first!.date),
                "last_ts": MessageService.ts(ms.last!.date),
            ]
            if includeText {
                data["messages"] = ms.map { render($0, contacts, scope, verdicts) }
            } else {
                data["hint"] = "Read them with get_conversation, passing chat_id as chat."
            }
            let row = ms.last!.rowID
            let id = "msg_\(row)"
            return MessageEvent(id: id, rowID: row, payload: [
                "id": id,
                "type": MessageEvent.type,
                "created_at": MessageService.ts(now),
                "data": data,
            ])
        }
    }
}

/// Signatures in the Standard Webhooks format (https://www.standardwebhooks.com),
/// so receivers can use an off-the-shelf library to check them.
public enum WebhookSignature {
    /// A new signing secret: "whsec_" followed by 32 random bytes in base64.
    public static func newSecret() -> String {
        var buf = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buf.count, &buf)
        return "whsec_" + Data(buf).base64EncodedString()
    }

    /// The `webhook-signature` header value for a delivery.
    public static func sign(id: String, timestamp: Int, body: Data, secret: String) -> String {
        let key = SymmetricKey(data: keyBytes(secret))
        let signed = Data("\(id).\(timestamp).".utf8) + body
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: key)
        return "v1," + Data(mac).base64EncodedString()
    }

    /// True when any signature in a `webhook-signature` header matches.
    public static func verify(id: String, timestamp: Int, body: Data, secret: String, header: String) -> Bool {
        let expected = sign(id: id, timestamp: timestamp, body: body, secret: secret)
        return header.split(separator: " ").contains { $0 == expected }
    }

    static func keyBytes(_ secret: String) -> Data {
        if secret.hasPrefix("whsec_"), let d = Data(base64Encoded: String(secret.dropFirst(6))) { return d }
        return Data(secret.utf8)
    }
}
