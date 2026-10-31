import Foundation

/// What a single agent is allowed to see.
public struct ReadScope: Sendable {
    /// nil = every chat; otherwise the chat identifiers this agent may read.
    public var allowedChats: Set<String>?
    public var redact: Bool

    public init(allowedChats: Set<String>?, redact: Bool) {
        self.allowedChats = allowedChats
        self.redact = redact
    }

    public func allows(_ chat: ChatInfo) -> Bool {
        guard let allowedChats else { return true }
        return allowedChats.contains(chat.identifier)
    }

    /// Normalized handles of the allowed 1:1 chats (used for contacts and sending).
    var allowedHandles: Set<String>? {
        allowedChats.map { Set($0.map(ContactBook.normalize).filter { !$0.isEmpty }) }
    }
}

public struct ChatSummary: Identifiable, Hashable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let label: String
    public let isGroup: Bool
    public let lastMessageDate: Date?
}

/// Implements the read tools on top of chat.db and the address book.
/// Results are plain JSON-ready dictionaries.
public final class MessageService: @unchecked Sendable {
    public let dbPath: String
    private let lock = NSLock()
    private var cachedContacts: ContactBook?
    private var contactsLoadedAt = Date.distantPast

    public init(dbPath: String = MessagesDB.defaultPath) {
        self.dbPath = dbPath
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func ts(_ d: Date) -> String { iso.string(from: d) }

    public func contacts() -> ContactBook {
        lock.lock()
        defer { lock.unlock() }
        if let c = cachedContacts, Date().timeIntervalSince(contactsLoadedAt) < 300 { return c }
        let c = ContactBook.load()
        cachedContacts = c
        contactsLoadedAt = Date()
        return c
    }

    func openDB() throws -> MessagesDB {
        do {
            return try MessagesDB(path: dbPath)
        } catch {
            throw BridgeError.failed("Cannot open the Messages database. Grant Full Disk Access to the app in System Settings → Privacy & Security. (\(error.localizedDescription))")
        }
    }

    // MARK: Labels

    func label(_ chat: ChatInfo, _ contacts: ContactBook) -> String {
        if !chat.displayName.isEmpty { return chat.displayName }
        if !chat.isGroup { return contacts.name(for: chat.identifier) ?? chat.identifier }
        let names = chat.participants.map { h -> String in
            if let n = contacts.name(for: h) { return n.split(separator: " ").first.map(String.init) ?? n }
            if h.contains("@") { return h }
            let d = h.filter(\.isNumber)
            return d.count >= 4 ? "…" + d.suffix(4) : h
        }
        if names.isEmpty { return chat.identifier }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " & \(names.count - 3) others"
    }

    func sender(_ m: Message, _ contacts: ContactBook) -> String {
        if m.isFromMe { return "me" }
        if m.sender.isEmpty { return "unknown" }
        return contacts.name(for: m.sender) ?? m.sender
    }

    func text(_ m: Message, _ scope: ReadScope, max: Int = 2000) -> String {
        var t = scope.redact ? Redactor.redact(m.text) : m.text
        if t.count > max { t = String(t.prefix(max)) + "…" }
        if m.hasAttachment { t = t.isEmpty ? "[attachment]" : t + " [attachment]" }
        return t
    }

    func visibleChats(_ db: MessagesDB, _ scope: ReadScope) throws -> [ChatInfo] {
        try db.chats().filter(scope.allows)
    }

    // MARK: Chat resolution

    /// Resolves a name, phone, email, chat identifier or group name to chats
    /// the scope allows. Never reveals contacts outside the scope.
    func resolve(_ raw: String, chats: [ChatInfo], contacts: ContactBook, scope: ReadScope) throws -> [ChatInfo] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = chats.filter { $0.identifier.caseInsensitiveCompare(q) == .orderedSame }
        if !exact.isEmpty { return exact }

        let norm = ContactBook.normalize(q)
        if !norm.isEmpty {
            let m = chats.filter { !$0.isGroup && ContactBook.normalize($0.identifier) == norm }
            if !m.isEmpty { return m }
            throw BridgeError.notFound("No conversation with \(q) is available.")
        }

        let allowed = scope.allowedHandles
        var matches = contacts.search(q)
        if let allowed {
            matches = matches.filter { e in e.handles.contains { allowed.contains(ContactBook.normalize($0)) } }
        }
        if matches.count > 1 {
            let exactName = matches.filter { $0.name.caseInsensitiveCompare(q) == .orderedSame }
            if !exactName.isEmpty {
                matches = exactName
            } else {
                let names = matches.prefix(10).map(\.name).joined(separator: ", ")
                throw BridgeError.invalid("\"\(q)\" matches several contacts: \(names). Use a full name, phone number or email.")
            }
        }
        if let contact = matches.first {
            let handles = Set(contact.handles.map(ContactBook.normalize).filter { !$0.isEmpty })
            let m = chats.filter { !$0.isGroup && handles.contains(ContactBook.normalize($0.identifier)) }
            if !m.isEmpty { return m }
        }

        let groups = chats.filter {
            $0.isGroup && (
                $0.displayName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                label($0, contacts).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        if !groups.isEmpty { return groups }
        throw BridgeError.notFound("No conversation matching \"\(q)\" is available.")
    }

    // MARK: Tools

    public func recentChats(limit: Int = 300) throws -> [ChatSummary] {
        let db = try openDB()
        let contacts = contacts()
        var seen = Set<String>()
        return try db.chats()
            .sorted { ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast) }
            .filter { seen.insert($0.identifier).inserted }
            .prefix(limit)
            .map { ChatSummary(identifier: $0.identifier, label: label($0, contacts), isGroup: $0.isGroup, lastMessageDate: $0.lastMessageDate) }
    }

    public func listChats(days: Double, limit: Int, query: String?, scope: ReadScope) throws -> [String: Any] {
        let db = try openDB()
        let contacts = contacts()
        let cutoff = Date().addingTimeInterval(-days * 86400)
        var rows = try visibleChats(db, scope).filter { ($0.lastMessageDate ?? .distantPast) >= cutoff }
        if let query {
            rows = rows.filter { c in
                label(c, contacts).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                c.identifier.localizedCaseInsensitiveContains(query) ||
                c.participants.contains { $0.localizedCaseInsensitiveContains(query) || (contacts.name(for: $0)?.localizedCaseInsensitiveContains(query) ?? false) }
            }
        }
        rows.sort { ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast) }
        let out: [[String: Any]] = rows.prefix(limit).map { c in
            [
                "chat_id": c.identifier,
                "label": label(c, contacts),
                "is_group": c.isGroup,
                "service": c.service,
                "participants": c.participants.map { ["handle": $0, "name": contacts.name(for: $0) ?? ""] },
                "last_message_at": c.lastMessageDate.map(MessageService.ts) ?? NSNull(),
            ]
        }
        return ["days": days, "count": out.count, "chats": out]
    }

    public func conversation(chat: String, days: Double, limit: Int, scope: ReadScope) throws -> [String: Any] {
        let db = try openDB()
        let contacts = contacts()
        let matched = try resolve(chat, chats: try visibleChats(db, scope), contacts: contacts, scope: scope)
        let msgs = try db.messages(since: Date().addingTimeInterval(-days * 86400), chatRowIDs: matched.map(\.rowID))
        let shown = msgs.suffix(limit)
        return [
            "chat": label(matched[0], contacts),
            "chat_ids": Array(Set(matched.map(\.identifier))).sorted(),
            "days": days,
            "total_in_window": msgs.count,
            "truncated": msgs.count > shown.count,
            "messages": shown.map { m in
                ["ts": MessageService.ts(m.date), "from": sender(m, contacts), "text": text(m, scope)]
            },
        ]
    }

    public func search(query: String, chat: String?, days: Double, limit: Int, scope: ReadScope) throws -> [String: Any] {
        let db = try openDB()
        let contacts = contacts()
        let chats = try visibleChats(db, scope)
        let byRow = Dictionary(chats.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        let rowIDs = try chat.map { try resolve($0, chats: chats, contacts: contacts, scope: scope).map(\.rowID) }
            ?? chats.map(\.rowID)
        let hits = try db.messages(since: Date().addingTimeInterval(-days * 86400), chatRowIDs: rowIDs)
            .filter { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .reversed()
        let shown = hits.prefix(limit)
        return [
            "query": query,
            "days": days,
            "total_matches": hits.count,
            "matches": shown.map { m -> [String: Any] in
                [
                    "ts": MessageService.ts(m.date),
                    "chat_id": m.chatIdentifier,
                    "chat": byRow[m.chatRowID].map { label($0, contacts) } ?? m.chatIdentifier,
                    "from": sender(m, contacts),
                    "text": text(m, scope),
                ]
            },
        ]
    }

    public func review(days: Double, scope: ReadScope) throws -> [String: Any] {
        let db = try openDB()
        let contacts = contacts()
        let chats = try visibleChats(db, scope)
        let byRow = Dictionary(chats.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        let msgs = try db.messages(since: Date().addingTimeInterval(-days * 86400), chatRowIDs: chats.map(\.rowID))
        let grouped = Dictionary(grouping: msgs, by: \.chatRowID)

        var needsReply: [[String: Any]] = []
        var lowPriority: [[String: Any]] = []
        var automated: [[String: Any]] = []
        for (rowID, ms) in grouped {
            guard let chat = byRow[rowID], let last = ms.last, !last.isFromMe else { continue }
            let entry: [String: Any] = [
                "chat_id": chat.identifier,
                "label": label(chat, contacts),
                "is_group": chat.isGroup,
                "last_ts": MessageService.ts(last.date),
                "last_text": text(last, scope, max: 500),
                "message_count": ms.count,
                "context": ms.suffix(6).map { m in
                    ["ts": MessageService.ts(m.date), "from": sender(m, contacts), "text": text(m, scope, max: 400)]
                },
            ]
            let hasHuman = ms.contains { !$0.isFromMe && !Triage.isAutomated(chatIdentifier: chat.identifier, text: $0.text) }
            if Triage.isAutomated(chatIdentifier: chat.identifier, text: last.text) && !hasHuman {
                automated.append(entry)
            } else if Triage.isLowSignal(last.text) {
                lowPriority.append(entry)
            } else {
                needsReply.append(entry)
            }
        }
        let byDate: ([String: Any], [String: Any]) -> Bool = { ($0["last_ts"] as! String) > ($1["last_ts"] as! String) }
        return [
            "days": days,
            "needs_reply": Array(needsReply.sorted(by: byDate).prefix(50)),
            "low_priority": Array(lowPriority.sorted(by: byDate).prefix(50)),
            "automated": Array(automated.sorted(by: byDate).prefix(50)),
        ]
    }

    public func responseStats(chat: String, hours: Double, scope: ReadScope) throws -> [String: Any] {
        let db = try openDB()
        let contacts = contacts()
        let matched = try resolve(chat, chats: try visibleChats(db, scope), contacts: contacts, scope: scope)
        let msgs = try db.messages(since: Date().addingTimeInterval(-hours * 3600), chatRowIDs: matched.map(\.rowID))

        var deltas: [Double] = []
        var pending: Date?
        for m in msgs {
            if !m.isFromMe {
                if pending == nil { pending = m.date }
            } else if let p = pending {
                let dt = m.date.timeIntervalSince(p)
                if dt >= 0 { deltas.append(dt) }
                pending = nil
            }
        }
        let sorted = deltas.sorted()
        let avg = deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count)
        func human(_ s: Double?) -> Any {
            guard let s else { return NSNull() }
            if s < 60 { return String(format: "%.0fs", s) }
            if s < 3600 { return String(format: "%.1fm", s / 60) }
            if s < 86400 { return String(format: "%.2fh", s / 3600) }
            return String(format: "%.2fd", s / 86400)
        }
        return [
            "chat": label(matched[0], contacts),
            "hours": hours,
            "replies_measured": deltas.count,
            "average": human(avg),
            "median": human(sorted.isEmpty ? nil : sorted[sorted.count / 2]),
            "fastest": human(sorted.first),
            "slowest": human(sorted.last),
            "average_seconds": avg ?? NSNull(),
            "inbound_messages": msgs.filter { !$0.isFromMe }.count,
            "outbound_messages": msgs.filter(\.isFromMe).count,
        ]
    }

    public func lookupContact(name: String, scope: ReadScope) -> [String: Any] {
        let allowed = scope.allowedHandles
        let results: [[String: Any]] = contacts().search(name).compactMap { e in
            let handles = allowed.map { a in e.handles.filter { a.contains(ContactBook.normalize($0)) } } ?? e.handles
            return handles.isEmpty ? nil : ["name": e.name, "handles": handles]
        }
        return ["query": name, "matches": Array(results.prefix(20))]
    }

    /// Throws unless the scope allows messaging this recipient.
    public func checkSendAllowed(to: String, scope: ReadScope) throws {
        guard let allowed = scope.allowedHandles else { return }
        guard allowed.contains(ContactBook.normalize(to)) else {
            throw BridgeError.forbidden("This agent may only message the chats selected for it in the app.")
        }
    }

    public func displayName(for handle: String) -> String? {
        contacts().name(for: handle)
    }
}
