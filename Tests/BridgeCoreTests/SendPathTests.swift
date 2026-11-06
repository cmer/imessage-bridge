import Foundation
import Testing
@testable import BridgeCore

/// Goal tests for the macOS 26 send path (docs/superpowers/specs/2026-11-01-grok-texting-via-bridge-design.md, D2).
/// Pure logic only: chat.db reads and AppleScript stay in the app target.
@Suite struct SendPathTests {
    private func chat(_ id: Int64, _ ident: String, service: String, group: Bool, parts: [String], ago: TimeInterval) -> ChatInfo {
        ChatInfo(rowID: id, identifier: ident, displayName: "", service: service, isGroup: group,
                 participants: parts, lastMessageDate: Date(timeIntervalSinceNow: -ago))
    }

    // MARK: Recipient normalization

    @Test func phoneNumbersNormalizeToE164() {
        #expect(SendPath.normalize("(904) 555-1234") == "+19045551234")
        #expect(SendPath.normalize("+1 904 555 1234") == "+19045551234")
        #expect(SendPath.normalize("9045551234") == "+19045551234")
        #expect(SendPath.normalize("+447700900123") == "+447700900123")
    }

    @Test func emailsNormalizeToLowercase() {
        #expect(SendPath.normalize(" Kyle@Example.com ") == "kyle@example.com")
    }

    @Test func storedHandleVariantsMatchTheSameNumber() {
        #expect(SendPath.sameHandle("+14144550143(smsft_rm)", "414-455-0143"))
        #expect(SendPath.sameHandle("14144550143", "+1 (414) 455-0143"))
        #expect(!SendPath.sameHandle("+14144550143", "+14144550144"))
    }

    // MARK: Existing-chat resolution

    @Test func directChatWinsOverGroupWithSameParticipant() {
        let chats = [
            chat(1, "chat123456", service: "iMessage", group: true, parts: ["+19045551234", "+19045550000"], ago: 10),
            chat(2, "+19045551234", service: "SMS", group: false, parts: ["+19045551234"], ago: 3600),
        ]
        #expect(SendPath.directChat(for: "(904) 555-1234", in: chats)?.rowID == 2)
    }

    @Test func groupOnlyMeansNoDirectChat() {
        let chats = [chat(1, "chat123456", service: "iMessage", group: true, parts: ["+19045551234", "+19045550000"], ago: 10)]
        #expect(SendPath.directChat(for: "+19045551234", in: chats) == nil)
    }

    @Test func mostRecentDirectChatWins() {
        let chats = [
            chat(1, "+19045551234", service: "iMessage", group: false, parts: ["+19045551234"], ago: 86_400 * 30),
            chat(2, "+19045551234", service: "RCS", group: false, parts: ["+19045551234(smsft_rm)"], ago: 60),
        ]
        #expect(SendPath.directChat(for: "9045551234", in: chats)?.rowID == 2)
    }

    // MARK: Participant fallback order (no existing chat)

    @Test func recentGreenBubbleTrafficLeads() {
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["iMessage", "RCS"], recentService: "RCS", requested: nil) == ["RCS", "SMS"])
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["iMessage", "SMS"], recentService: "SMS", requested: nil) == ["SMS", "RCS"])
    }

    @Test func iMessageHandleTriesIMessageThenSMS() {
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["iMessage"], recentService: "iMessage", requested: nil) == ["iMessage", "SMS"])
    }

    @Test func rcsHandleNeverTriesIMessage() {
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["RCS"], recentService: nil, requested: nil) == ["RCS", "SMS"])
    }

    @Test func smsHandleIsSMSOnly() {
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["SMS"], recentService: nil, requested: nil) == ["SMS"])
    }

    @Test func unknownPhoneNumberIsSMSFirst() {
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: [], recentService: nil, requested: nil) == ["SMS", "iMessage"])
    }

    @Test func emailIsIMessageOnly() {
        #expect(SendPath.fallbackOrder(recipient: "kyle@example.com", handleServices: [], recentService: nil, requested: nil) == ["iMessage"])
    }

    @Test func callerServiceOverridesDetection() {
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["RCS"], recentService: "RCS", requested: "iMessage") == ["iMessage"])
        #expect(SendPath.fallbackOrder(recipient: "+19045551234", handleServices: ["iMessage"], recentService: "iMessage", requested: "SMS") == ["SMS"])
    }

    // MARK: Delivery verification (chat.db is the truth, not osascript's exit code)

    @Test func verifiedRowIsNewOutboundMatchingTextWithoutError() {
        let rows = [
            SendPath.OutboundRow(rowID: 99, isFromMe: true, text: "On my way", error: 0, service: "SMS"),   // before baseline
            SendPath.OutboundRow(rowID: 101, isFromMe: false, text: "On my way", error: 0, service: "SMS"), // inbound
            SendPath.OutboundRow(rowID: 102, isFromMe: true, text: "Something else", error: 0, service: "SMS"),
            SendPath.OutboundRow(rowID: 103, isFromMe: true, text: "On my way", error: 22, service: "iMessage"), // failed
            SendPath.OutboundRow(rowID: 104, isFromMe: true, text: "On my way", error: 0, service: "RCS"),
        ]
        let hit = SendPath.verifiedRow(text: "On my way", baseline: 100, rows: rows)
        #expect(hit?.rowID == 104)
        #expect(hit?.service == "RCS")
    }

    @Test func noMatchingRowMeansNotVerified() {
        let rows = [SendPath.OutboundRow(rowID: 101, isFromMe: true, text: "On my way", error: 0, service: "SMS")]
        #expect(SendPath.verifiedRow(text: "Different text", baseline: 100, rows: rows) == nil)
        #expect(SendPath.verifiedRow(text: "On my way", baseline: 101, rows: rows) == nil)
    }

    @Test func verificationIgnoresWhitespaceDifferences() {
        let rows = [SendPath.OutboundRow(rowID: 101, isFromMe: true, text: "On my way \n", error: 0, service: "SMS")]
        #expect(SendPath.verifiedRow(text: "On my way", baseline: 100, rows: rows)?.rowID == 101)
    }
}

@Suite struct SendPathServiceParamTests {
    @Test func omittedServiceMeansAuto() throws {
        #expect(try Validate.service(nil) == nil)
        #expect(try Validate.service(NSNull()) == nil)
    }

    @Test func explicitServiceIsKept() throws {
        #expect(try Validate.service("SMS") == "SMS")
        #expect(try Validate.service("iMessage") == "iMessage")
    }

    @Test func unknownServiceIsRejected() {
        #expect(throws: BridgeError.self) { try Validate.service("RCS") }
    }
}
