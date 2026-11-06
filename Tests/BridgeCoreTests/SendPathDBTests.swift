import Foundation
import Testing
@testable import BridgeCore

/// chat.db reads the send path depends on, against a fixture built with the sqlite3 CLI.
@Suite struct SendPathDBTests {
    private static func fixture() throws -> MessagesDB {
        let path = NSTemporaryDirectory() + "sendpath-\(UUID().uuidString).db"
        let sql = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT, style INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER,
            handle_id INTEGER, error INTEGER, service TEXT, associated_message_type INTEGER, item_type INTEGER, cache_has_attachments INTEGER);
        INSERT INTO handle VALUES (1, '+19045551234', 'iMessage');
        INSERT INTO handle VALUES (2, '+19045551234(smsft_rm)', 'RCS');
        INSERT INTO handle VALUES (3, '+19045550000', 'SMS');
        INSERT INTO chat VALUES (10, 'RCS;-;+19045551234(smsft_rm)', '+19045551234', NULL, 'RCS', 45);
        INSERT INTO chat VALUES (11, 'iMessage;+;chat123', 'chat123', 'Family', 'iMessage', 43);
        INSERT INTO chat_handle_join VALUES (10, 2);
        INSERT INTO chat_handle_join VALUES (11, 1);
        INSERT INTO chat_handle_join VALUES (11, 3);
        INSERT INTO message VALUES (1, 'old', NULL, 100, 1, 1, 0, 'iMessage', 0, 0, 0);
        INSERT INTO message VALUES (2, 'hey', NULL, 200, 0, 2, 0, 'RCS', 0, 0, 0);
        INSERT INTO message VALUES (5, 'On my way', NULL, 300, 1, 2, 0, 'RCS', 0, 0, 0);
        INSERT INTO message VALUES (6, 'nope', NULL, 400, 1, 3, 22, 'SMS', 0, 0, 0);
        INSERT INTO chat_message_join VALUES (10, 1, 100);
        INSERT INTO chat_message_join VALUES (10, 2, 200);
        INSERT INTO chat_message_join VALUES (10, 5, 300);
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path]
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        pipe.fileHandleForWriting.write(sql.data(using: .utf8)!)
        pipe.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        return try MessagesDB(path: path)
    }

    @Test func maxMessageRowIDIsTheNewestRow() throws {
        #expect(try Self.fixture().maxMessageRowID() == 6)
    }

    @Test func outboundRowsAfterBaselineCarryErrorAndService() throws {
        let rows = try Self.fixture().outboundRows(after: 1)
        #expect(rows.map(\.rowID) == [2, 5, 6])
        #expect(rows[1] == SendPath.OutboundRow(rowID: 5, isFromMe: true, text: "On my way", error: 0, service: "RCS"))
        #expect(rows[0].isFromMe == false)
        #expect(rows[2].error == 22)
    }

    @Test func handleServicesMatchEveryStoredVariant() throws {
        #expect(try Self.fixture().handleServices(for: "(904) 555-1234").sorted() == ["RCS", "iMessage"])
        #expect(try Self.fixture().handleServices(for: "+15555555555") == [])
    }

    @Test func recentServiceIsTheNewestMessageWithThatPerson() throws {
        #expect(try Self.fixture().recentService(for: "9045551234") == "RCS")
        #expect(try Self.fixture().recentService(for: "+15555555555") == nil)
    }

    @Test func chatGUIDComesFromTheDatabaseNotStringBuilding() throws {
        #expect(try Self.fixture().chatGUID(rowID: 10) == "RCS;-;+19045551234(smsft_rm)")
        #expect(try Self.fixture().chatGUID(rowID: 99) == nil)
    }
}
