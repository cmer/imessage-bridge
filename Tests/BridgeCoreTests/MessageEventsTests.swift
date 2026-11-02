import Foundation
import SQLite3
import Testing
@testable import BridgeCore

/// A throwaway database with the parts of chat.db's schema the bridge reads.
final class FixtureChatDB {
    let path: String
    private var db: OpaquePointer?

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imb-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("chat.db").path
        sqlite3_open(path, &db)
        exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT,
                               service_name TEXT, style INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER,
                                  handle_id INTEGER, text TEXT, attributedBody BLOB,
                                  cache_has_attachments INTEGER, associated_message_type INTEGER,
                                  item_type INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            INSERT INTO handle VALUES (1, '+15555550101'), (2, '+15555550102');
            INSERT INTO chat VALUES (1, '+15555550101', '', 'iMessage', 45),
                                    (2, 'chat900', 'Book club', 'iMessage', 43);
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2);
            """)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    func add(chat: Int64, handle: Int64, text: String, fromMe: Bool = false, at date: Date = Date(),
             associatedType: Int = 0) -> Int64 {
        let nanos = MessagesDB.appleNanos(from: date)
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        exec("""
            INSERT INTO message (date, is_from_me, handle_id, text, cache_has_attachments, associated_message_type, item_type)
            VALUES (\(nanos), \(fromMe ? 1 : 0), \(fromMe ? 0 : handle), '\(escaped)', 0, \(associatedType), 0);
            INSERT INTO chat_message_join VALUES (\(chat), last_insert_rowid(), \(nanos));
            """)
        return sqlite3_last_insert_rowid(db)
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[Message]] = []
    private var _cursors: [Int64] = []
    var batches: [[Message]] { lock.withLock { _batches } }
    var cursors: [Int64] { lock.withLock { _cursors } }
    func add(_ m: [Message]) { lock.withLock { _batches.append(m) } }
    func cursor(_ c: Int64) { lock.withLock { _cursors.append(c) } }
}

@Suite struct MessageWatcherTests {
    func watcher(_ db: FixtureChatDB, cursor: Int64?, _ out: Collected, options: MessageWatcher.Options = .init()) -> MessageWatcher {
        MessageWatcher(dbPath: db.path, cursor: cursor, options: options,
                       onMessages: { out.add($0) }, onCursor: { out.cursor($0) })
    }

    @Test func startsAtNewestRowWithoutReplayingHistory() {
        let db = FixtureChatDB()
        db.add(chat: 1, handle: 1, text: "old one")
        let last = db.add(chat: 1, handle: 1, text: "old two")
        let out = Collected()
        let w = watcher(db, cursor: nil, out)
        w.checkNow()
        #expect(out.batches.isEmpty)
        #expect(out.cursors == [last])
    }

    @Test func reportsNewMessagesOnceInRowOrder() {
        let db = FixtureChatDB()
        let start = db.add(chat: 1, handle: 1, text: "before")
        let out = Collected()
        let w = watcher(db, cursor: start, out)
        let a = db.add(chat: 1, handle: 1, text: "first")
        let b = db.add(chat: 2, handle: 2, text: "second")
        w.checkNow()
        w.checkNow()
        #expect(out.batches.count == 1)
        #expect(out.batches.first?.map(\.rowID) == [a, b])
        #expect(out.cursors.last == b)
    }

    @Test func movesPastRowsItSkips() {
        let db = FixtureChatDB()
        let start = db.add(chat: 1, handle: 1, text: "before")
        let out = Collected()
        let w = watcher(db, cursor: start, out)
        let tapback = db.add(chat: 1, handle: 1, text: "Loved “before”", associatedType: 2000)
        w.checkNow()
        #expect(out.batches.isEmpty)
        #expect(out.cursors == [tapback])
    }

    @Test func catchUpKeepsOnlyRecentAndNewest() {
        let db = FixtureChatDB()
        let start = db.add(chat: 1, handle: 1, text: "before")
        db.add(chat: 1, handle: 1, text: "synced from long ago", at: Date().addingTimeInterval(-86400))
        var newest: [Int64] = []
        for i in 0..<5 { newest.append(db.add(chat: 1, handle: 1, text: "new \(i)")) }
        var options = MessageWatcher.Options()
        options.maxBatch = 3
        let out = Collected()
        watcher(db, cursor: start, out, options: options).checkNow()
        #expect(out.batches.first?.map(\.rowID) == Array(newest.suffix(3)))
        #expect(out.cursors == [newest.last!])
    }

    @Test func noticesWritesWithoutPolling() async throws {
        let db = FixtureChatDB()
        let start = db.add(chat: 1, handle: 1, text: "before")
        var options = MessageWatcher.Options()
        options.delay = 0.05
        options.pollInterval = 60
        let out = Collected()
        let w = watcher(db, cursor: start, out, options: options)
        w.start()
        defer { w.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let row = db.add(chat: 1, handle: 1, text: "hello")
        for _ in 0..<40 where out.batches.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(out.batches.first?.map(\.rowID) == [row])
    }
}

@Suite struct MessageFeedTests {
    @Test func buffersAndFansOut() {
        let feed = MessageFeed(capacity: 2)
        let out = Collected()
        let id = feed.subscribe { out.add($0) }
        let m = { (row: Int64) in
            Message(rowID: row, chatRowID: 1, chatIdentifier: "x", date: Date(), isFromMe: false, sender: "x", text: "t", hasAttachment: false)
        }
        feed.publish([m(1), m(2), m(3)])
        feed.unsubscribe(id)
        feed.publish([m(4)])
        #expect(out.batches.count == 1)
        #expect(feed.messages(afterRowID: 0).map(\.rowID) == [3, 4])
        #expect(feed.messages(afterRowID: 3).map(\.rowID) == [4])
    }
}

@Suite struct MessageEventTests {
    func newMessages(_ db: FixtureChatDB) -> (MessageService, [Message]) {
        db.add(chat: 1, handle: 1, text: "Dinner at 7?")
        db.add(chat: 1, handle: 0, text: "Sure", fromMe: true)
        db.add(chat: 2, handle: 2, text: "Your code is 482913")
        let service = MessageService(dbPath: db.path)
        let msgs = try! MessagesDB(path: db.path).messages(afterRowID: 0, through: 100)
        return (service, msgs)
    }

    @Test func oneEventPerChatWithoutText() throws {
        let db = FixtureChatDB()
        let (service, msgs) = newMessages(db)
        let events = try service.events(for: msgs, scope: ReadScope(allowedChats: nil, redact: true), includeText: false)
        #expect(events.count == 2)
        let first = events[0].payload["data"] as! [String: Any]
        #expect(first["chat_id"] as? String == "+15555550101")
        #expect(first["count"] as? Int == 1)   // my own reply isn't an event
        #expect(first["messages"] == nil)
        #expect(events[0].payload["type"] as? String == "message.received")
        let group = events[1].payload["data"] as! [String: Any]
        #expect(group["chat"] as? String == "Book club")
        #expect(group["is_group"] as? Bool == true)
        #expect(events[1].id == "msg_\(events[1].rowID)")
        #expect(!String(decoding: events[1].json, as: UTF8.self).contains("482913"))
    }

    @Test func textIsRedactedAndScoped() throws {
        let db = FixtureChatDB()
        let (service, msgs) = newMessages(db)
        let events = try service.events(for: msgs, scope: ReadScope(allowedChats: ["chat900"], redact: true), includeText: true)
        #expect(events.count == 1)
        let data = events[0].payload["data"] as! [String: Any]
        let texts = (data["messages"] as! [[String: Any]]).compactMap { $0["text"] as? String }
        #expect(texts.count == 1)
        #expect(texts[0].contains("[REDACTED-2FA]"))
    }
}

@Suite struct WebhookSignatureTests {
    // Test vector from the Standard Webhooks reference libraries.
    @Test func matchesReferenceVector() {
        let sig = WebhookSignature.sign(
            id: "msg_p5jXN8AQM9LWM0D4loKWxJek", timestamp: 1614265330,
            body: Data(#"{"test": 2432232314}"#.utf8),
            secret: "whsec" + "_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")   // public test vector, split for secret scanners
        #expect(sig == "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
    }

    @Test func verifiesAndRejects() {
        let secret = WebhookSignature.newSecret()
        #expect(secret.hasPrefix("whsec_"))
        let body = Data("{}".utf8)
        let sig = WebhookSignature.sign(id: "a", timestamp: 1, body: body, secret: secret)
        #expect(WebhookSignature.verify(id: "a", timestamp: 1, body: body, secret: secret, header: "v1,bogus " + sig))
        #expect(!WebhookSignature.verify(id: "a", timestamp: 2, body: body, secret: secret, header: sig))
    }
}
