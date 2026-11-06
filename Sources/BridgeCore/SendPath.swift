import Foundation

/// Pure decisions behind sending on macOS 26: which stored handle a recipient is,
/// which existing 1:1 chat to send into, which transports to try when there is
/// no chat, and what counts as proof in chat.db that a message actually went out.
/// Nothing here touches Messages or the database; the app target does that.
public enum SendPath {
    public struct OutboundRow: Equatable, Sendable {
        public let rowID: Int64
        public let isFromMe: Bool
        public let text: String
        public let error: Int64
        public let service: String

        public init(rowID: Int64, isFromMe: Bool, text: String, error: Int64, service: String) {
            self.rowID = rowID
            self.isFromMe = isFromMe
            self.text = text
            self.error = error
            self.service = service
        }
    }

    /// Canonical form of a recipient: lowercased email, or E.164-style phone number
    /// (`+` plus digits; a bare 10-digit number is read as US).
    public static func normalize(_ recipient: String) -> String {
        let t = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("@") { return t.lowercased() }
        let digits = t.filter(\.isNumber)
        if t.hasPrefix("+") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        return "+" + digits
    }

    /// True when two handles name the same address, ignoring formatting and the
    /// `(smsft_rm)`-style suffix chat.db appends to some stored handles.
    public static func sameHandle(_ a: String, _ b: String) -> Bool {
        normalize(stripSuffix(a)) == normalize(stripSuffix(b))
    }

    private static func stripSuffix(_ h: String) -> String {
        h.replacingOccurrences(of: #"\([A-Za-z_]+\)$"#, with: "", options: .regularExpression)
    }

    /// The most recently active 1:1 chat with this recipient, or nil when the only
    /// chats that include them are groups.
    public static func directChat(for recipient: String, in chats: [ChatInfo]) -> ChatInfo? {
        chats
            .filter { !$0.isGroup }
            .filter { c in
                sameHandle(c.identifier, recipient) || c.participants.contains { sameHandle($0, recipient) }
            }
            .max { ($0.lastMessageDate ?? .distantPast) < ($1.lastMessageDate ?? .distantPast) }
    }

    /// Transports to try, in order, when sending to a participant with no existing chat.
    /// `handleServices` are the services chat.db has handle rows for; `recentService`
    /// is the service of the newest message exchanged with them.
    public static func fallbackOrder(recipient: String, handleServices: [String],
                                     recentService: String?, requested: String?) -> [String] {
        if let requested { return [requested] }
        if recipient.contains("@") { return ["iMessage"] }
        if let recent = recentService, recent == "RCS" || recent == "SMS" {
            return [recent] + ["RCS", "SMS"].filter { $0 != recent }
        }
        if handleServices.contains("RCS") { return ["RCS", "SMS"] }
        if handleServices.contains("iMessage") { return ["iMessage", "SMS"] }
        if handleServices.contains("SMS") { return ["SMS"] }
        return ["SMS", "iMessage"]
    }

    /// The newest outbound row written after `baseline` whose text matches and whose
    /// error column is 0. Nil means the send is unproven and must be reported as not sent.
    public static func verifiedRow(text: String, baseline: Int64, rows: [OutboundRow]) -> OutboundRow? {
        let want = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows
            .filter { $0.rowID > baseline && $0.isFromMe && $0.error == 0 }
            .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == want }
            .max { $0.rowID < $1.rowID }
    }
}
