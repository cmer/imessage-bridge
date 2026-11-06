import Foundation

public struct Message: Sendable {
    public let rowID: Int64
    public let chatRowID: Int64
    public let chatIdentifier: String
    public let date: Date
    public let isFromMe: Bool
    public let sender: String
    public let text: String
    public let hasAttachment: Bool
}

public struct ChatInfo: Sendable {
    public let rowID: Int64
    public let identifier: String
    public let displayName: String
    public let service: String
    public let isGroup: Bool
    public let participants: [String]
    public let lastMessageDate: Date?
}

/// Read-only access to ~/Library/Messages/chat.db.
public final class MessagesDB {
    public static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }
    static let appleEpoch: TimeInterval = 978_307_200

    private let db: SQLiteDB

    public init(path: String = MessagesDB.defaultPath) throws {
        db = try SQLiteDB(path: path)
    }

    /// True when this process can open chat.db (i.e. has Full Disk Access).
    public static func canRead(path: String = MessagesDB.defaultPath) -> Bool {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return false }
        close(fd)
        return true
    }

    static func date(fromApple raw: Int64) -> Date {
        // Modern databases store nanoseconds; very old ones store seconds.
        let seconds = raw > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + appleEpoch)
    }

    static func appleNanos(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - appleEpoch) * 1_000_000_000)
    }

    static let messageColumns = """
        SELECT m.ROWID, c.ROWID, c.chat_identifier, m.date, m.is_from_me,
               COALESCE(h.id, ''), m.text, m.attributedBody,
               COALESCE(m.cache_has_attachments, 0)
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE COALESCE(m.associated_message_type, 0) NOT BETWEEN 2000 AND 3999
          AND COALESCE(m.item_type, 0) = 0
        """

    public func messages(since: Date, chatRowIDs: [Int64]? = nil) throws -> [Message] {
        var sql = MessagesDB.messageColumns + " AND m.date > ?"
        if let ids = chatRowIDs {
            if ids.isEmpty { return [] }
            sql += " AND c.ROWID IN (" + ids.map(String.init).joined(separator: ",") + ")"
        }
        sql += " ORDER BY m.date ASC"
        return try db.query(sql, [.int(MessagesDB.appleNanos(from: since))]).compactMap(MessagesDB.message)
    }

    /// Messages with row IDs in `(after, through]`, oldest first. Row IDs only
    /// grow, unlike dates, which can arrive out of order when other devices
    /// sync. When there are more than `limit`, the newest `limit` are returned.
    public func messages(afterRowID after: Int64, through: Int64, limit: Int = 500) throws -> [Message] {
        let sql = MessagesDB.messageColumns + " AND m.ROWID > ? AND m.ROWID <= ? ORDER BY m.ROWID DESC LIMIT \(max(1, limit))"
        return try db.query(sql, [.int(after), .int(through)]).compactMap(MessagesDB.message).reversed()
    }

    /// The highest message row ID, or 0 for an empty database. Also the baseline a send
    /// is verified against.
    public func maxMessageRowID() throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message").first?.first?.int64 ?? 0
    }

    static func message(_ r: [SQLValue]) -> Message? {
        var text = r[6].string
        if text.isEmpty { text = AttributedBody.decode(r[7].data) }
        let hasAttachment = r[8].int64 != 0 || text.contains("\u{FFFC}")
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && !hasAttachment { return nil }
        return Message(
            rowID: r[0].int64,
            chatRowID: r[1].int64,
            chatIdentifier: r[2].string,
            date: MessagesDB.date(fromApple: r[3].int64),
            isFromMe: r[4].int64 != 0,
            sender: r[5].string,
            text: text,
            hasAttachment: hasAttachment
        )
    }

    // MARK: Send-path reads

    /// Messages written after `baseline`, oldest first, with the columns that prove
    /// whether an outbound send really happened.
    public func outboundRows(after baseline: Int64) throws -> [SendPath.OutboundRow] {
        try db.query("""
            SELECT ROWID, COALESCE(is_from_me, 0), COALESCE(text, ''), attributedBody,
                   COALESCE(error, 0), COALESCE(service, '')
            FROM message WHERE ROWID > ? ORDER BY ROWID ASC
            """, [.int(baseline)]).map { r in
            var text = r[2].string
            if text.isEmpty { text = AttributedBody.decode(r[3].data) }
            return SendPath.OutboundRow(rowID: r[0].int64, isFromMe: r[1].int64 != 0, text: text,
                                        error: r[4].int64, service: r[5].string)
        }
    }

    /// (handle ROWID, service) for every stored handle that is this recipient.
    private func handles(for recipient: String) throws -> [(Int64, String)] {
        try db.query("SELECT ROWID, id, COALESCE(service, '') FROM handle")
            .filter { SendPath.sameHandle($0[1].string, recipient) }
            .map { ($0[0].int64, $0[2].string) }
    }

    /// Distinct services chat.db has handle rows for, for this recipient.
    public func handleServices(for recipient: String) throws -> [String] {
        var seen: [String] = []
        for (_, s) in try handles(for: recipient) where !s.isEmpty && !seen.contains(s) { seen.append(s) }
        return seen
    }

    /// Service of the newest message exchanged with this recipient, if any.
    public func recentService(for recipient: String) throws -> String? {
        let ids = try handles(for: recipient).map { String($0.0) }
        if ids.isEmpty { return nil }
        let r = try db.query("""
            SELECT COALESCE(service, '') FROM message
            WHERE handle_id IN (\(ids.joined(separator: ","))) ORDER BY date DESC LIMIT 1
            """)
        let s = r.first?[0].string ?? ""
        return s.isEmpty ? nil : s
    }

    /// The chat's real GUID, read rather than built from the handle, because stored
    /// handles carry suffixes that string construction would mangle.
    public func chatGUID(rowID: Int64) throws -> String? {
        let r = try db.query("SELECT guid FROM chat WHERE ROWID = ?", [.int(rowID)])
        guard let g = r.first?[0].string, !g.isEmpty else { return nil }
        return g
    }

    public func chats() throws -> [ChatInfo] {
        var participants: [Int64: [String]] = [:]
        for r in try db.query("""
            SELECT chj.chat_id, h.id FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """) {
            participants[r[0].int64, default: []].append(r[1].string)
        }

        let fast = """
            SELECT c.ROWID, c.chat_identifier, COALESCE(c.display_name, ''),
                   COALESCE(c.service_name, ''), COALESCE(c.style, 0), MAX(cmj.message_date)
            FROM chat c LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            GROUP BY c.ROWID
            """
        let slow = """
            SELECT c.ROWID, c.chat_identifier, COALESCE(c.display_name, ''),
                   COALESCE(c.service_name, ''), COALESCE(c.style, 0), MAX(m.date)
            FROM chat c LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            LEFT JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.ROWID
            """
        let rows: [[SQLValue]]
        if let r = try? db.query(fast) {
            rows = r
        } else {
            rows = try db.query(slow)
        }
        return rows.map { r in
            let id = r[0].int64
            let ident = r[1].string
            let parts = participants[id] ?? []
            let isGroup = r[4].int64 == 43 || (ident.hasPrefix("chat") && parts.count > 1)
            return ChatInfo(
                rowID: id,
                identifier: ident,
                displayName: r[2].string,
                service: r[3].string,
                isGroup: isGroup,
                participants: parts,
                lastMessageDate: r[5].isNull ? nil : MessagesDB.date(fromApple: r[5].int64)
            )
        }
    }
}
