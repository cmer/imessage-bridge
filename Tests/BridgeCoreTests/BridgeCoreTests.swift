import Foundation
import Testing
@testable import BridgeCore

@Suite struct AttributedBodyTests {
    /// Minimal typedstream-shaped blob: header, NSString marker, length, UTF-8 payload.
    func blob(_ text: String, longLength: Bool = false) -> Data {
        var d = Data([0x04, 0x0B]) + Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84])
        d += Data("NSAttributedString".utf8) + Data([0x00, 0x84, 0x84])
        d += Data("NSObject".utf8) + Data([0x00, 0x85, 0x92, 0x84, 0x84, 0x84])
        d += Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B])
        let bytes = Data(text.utf8)
        if longLength || bytes.count >= 0x80 {
            d += Data([0x81, UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8)])
        } else {
            d += Data([UInt8(bytes.count)])
        }
        return d + bytes + Data([0x86, 0x84])
    }

    @Test func decodesShortString() {
        #expect(AttributedBody.decode(blob("Running 10 minutes late")) == "Running 10 minutes late")
    }

    @Test func decodesUnicode() {
        #expect(AttributedBody.decode(blob("Café 🎉 ok")) == "Café 🎉 ok")
    }

    @Test func decodesLongString() {
        let long = String(repeating: "a", count: 300)
        #expect(AttributedBody.decode(blob(long)) == long)
    }

    @Test func rejectsNonTypedstream() {
        #expect(AttributedBody.decode(Data("hello NSString world".utf8)) == "")
        #expect(AttributedBody.decode(nil) == "")
    }
}

@Suite struct RedactionTests {
    @Test func redactsVerificationCodes() {
        #expect(Redactor.redact("Your verification code is 482913") .contains("[REDACTED-2FA]"))
        #expect(!Redactor.redact("Your verification code is 482913").contains("482913"))
        #expect(Redactor.redact("482913 is your login code").contains("[REDACTED-2FA]"))
    }

    @Test func redactsCardsAndSSN() {
        #expect(Redactor.redact("card 4111 1111 1111 1111 thanks") == "card [REDACTED-CARD] thanks")
        #expect(Redactor.redact("ssn 123-45-6789") == "ssn [REDACTED-SSN]")
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(Redactor.redact("See you at 1030 by the station") == "See you at 1030 by the station")
    }
}

@Suite struct TriageTests {
    @Test func automated() {
        #expect(Triage.isAutomated(chatIdentifier: "22395", text: "anything"))
        #expect(Triage.isAutomated(chatIdentifier: "+15551234567", text: "Your package is out for delivery"))
        #expect(!Triage.isAutomated(chatIdentifier: "+15551234567", text: "Dinner tonight?"))
    }

    @Test func lowSignal() {
        #expect(Triage.isLowSignal("ok!"))
        #expect(Triage.isLowSignal("Loved “see you soon”"))
        #expect(!Triage.isLowSignal("Can you call me?"))
    }
}

@Suite struct ValidationTests {
    @Test func recipients() throws {
        #expect(try Validate.recipient("+1 (555) 123-4567") == "+1 (555) 123-4567")
        #expect(try Validate.recipient("Alex@Example.com") == "alex@example.com")
        #expect(throws: BridgeError.self) { try Validate.recipient("chat123456") }
        #expect(throws: BridgeError.self) { try Validate.recipient("555-1234") }
        #expect(throws: BridgeError.self) { try Validate.recipient("not an address") }
    }

    @Test func sendText() throws {
        #expect(try Validate.sendText("hi\nthere") == "hi\nthere")
        #expect(throws: BridgeError.self) { try Validate.sendText("bell\u{07}") }
        #expect(throws: BridgeError.self) { try Validate.sendText("   ") }
        #expect(throws: BridgeError.self) { try Validate.sendText(String(repeating: "x", count: 4001)) }
    }

    @Test func numbersRejectBooleans() {
        #expect(throws: BridgeError.self) { try Validate.number(true, name: "days", default: 1, min: 0, max: 10) }
        #expect(throws: BridgeError.self) { try Validate.number(99, name: "days", default: 1, min: 0, max: 10) }
        #expect((try? Validate.number(nil, name: "days", default: 2, min: 0, max: 10)) == 2)
    }

    @Test func agentNames() {
        #expect((try? Validate.agentName("Grok")) == "Grok")
        #expect(throws: BridgeError.self) { try Validate.agentName("bad\u{1B}[31m") }
        #expect(throws: BridgeError.self) { try Validate.agentName(String(repeating: "n", count: 41)) }
    }
}

@Suite struct ContactTests {
    @Test func normalize() {
        #expect(ContactBook.normalize("+1 (555) 123-4567") == "5551234567")
        #expect(ContactBook.normalize(" Alex@Example.com ") == "alex@example.com")
        #expect(ContactBook.normalize("22395") == "")
    }

    @Test func mergesAndSearches() {
        let book = ContactBook(entries: [
            ContactEntry(name: "Alex Example", handles: ["+15551234567"]),
            ContactEntry(name: "alex example", handles: ["alex@example.com"]),
            ContactEntry(name: "Bea Other", handles: ["+15559876543"]),
        ])
        #expect(book.entries.count == 2)
        #expect(book.name(for: "555-123-4567") == "Alex Example")
        #expect(book.search("alex").first?.handles.count == 2)
        #expect(book.search("5559876543").first?.name == "Bea Other")
    }

    @Test func scopeLimitsSendTargets() {
        let svc = MessageService(dbPath: "/nonexistent")
        let scope = ReadScope(allowedChats: ["+15551234567"], redact: true)
        #expect((try? svc.checkSendAllowed(to: "(555) 123-4567", scope: scope)) != nil)
        #expect(throws: BridgeError.self) { try svc.checkSendAllowed(to: "+15559876543", scope: scope) }
        #expect((try? svc.checkSendAllowed(to: "+15559876543", scope: ReadScope(allowedChats: nil, redact: true))) != nil)
    }
}

@Suite struct TokenTests {
    @Test func tokens() {
        let t = Tokens.newAgentToken()
        #expect(t.hasPrefix("imb_") && t.count > 40)
        #expect(Tokens.newAgentToken() != t)
        #expect(Tokens.pairingCode().count == 6)
        #expect(Tokens.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Tokens.normalizeFingerprint("ab:cd:EF") == "ABCDEF")
    }
}

@Suite struct ClientSetupTests {
    @Test func slugs() {
        #expect(ClientSetup.slug("Walter Orchestrator") == "walter-orchestrator")
        #expect(ClientSetup.slug("Claude Code!") == "claude-code")
        #expect(ClientSetup.slug("***") == "agent")
    }

    @Test func connectorJSON() throws {
        let json = ClientSetup.mcpServersJSON(cli: "/Users/x/.local/bin/imessage-bridge", agent: "Walter Orchestrator")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let server = (obj["mcpServers"] as! [String: Any])["imessage"] as! [String: Any]
        #expect(server["command"] as? String == "/Users/x/.local/bin/imessage-bridge")
        #expect(server["args"] as? [String] == ["mcp", "--agent", "walter-orchestrator"])
    }

    @Test func claudeCommandQuotesSpaces() {
        let cmd = ClientSetup.claudeCodeCommand(cli: "/Applications/iMessage Bridge.app/Contents/MacOS/imessage-bridge", agent: "Claude")
        #expect(cmd == "claude mcp add imessage --scope user -- '/Applications/iMessage Bridge.app/Contents/MacOS/imessage-bridge' mcp --agent claude")
    }
}
