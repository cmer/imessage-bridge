import Foundation
import Testing
@testable import BridgeCore

@Suite struct WebhookURLTests {
    @Test(arguments: [
        "https://agent.example.com/hooks/imessage",
        "  https://example.com  ",
        "HTTPS://Example.com:8443/x?y=1",
        "http://localhost:3000/hook",
        "http://127.0.0.1/hook",
        "http://[::1]:8080/hook",
        "http://LOCALHOST/hook",
    ])
    func accepts(_ raw: String) throws {
        _ = try Webhook.validate(raw)
    }

    @Test(arguments: [
        "",
        "   ",
        "example.com/hook",
        "http://example.com/hook",
        "http://192.168.1.10/hook",
        "http://localhost.evil.com/hook",
        "http://127.0.0.2/hook",
        "ftp://example.com/hook",
        "file:///etc/passwd",
        "https://",
        "javascript:alert(1)",
    ])
    func rejects(_ raw: String) {
        #expect(throws: BridgeError.self) { try Webhook.validate(raw) }
    }

    @Test func plainHTTPMessageExplainsTheRule() {
        do {
            _ = try Webhook.validate("http://example.com")
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("https://"))
            #expect(error.localizedDescription.contains("localhost"))
        }
    }
}

@Suite struct WebhookRetryTests {
    @Test func backsOffThenRepeatsEveryFiveMinutes() {
        #expect((1...6).map(Webhook.retryDelay(afterFailures:)) == [5, 30, 120, 300, 300, 300])
        #expect(Webhook.retryDelay(afterFailures: 0) == 5)
    }

    /// Replays an outage: every attempt fails, starting at t = 0.
    func outage(_ result: WebhookResult) -> (attempts: [TimeInterval], offAt: TimeInterval) {
        let start = Date(timeIntervalSince1970: 0)
        var t: TimeInterval = 0
        var attempts: [TimeInterval] = []
        for failures in 1...100 {
            attempts.append(t)
            switch Webhook.next(after: result, failingSince: start, failures: failures, now: start + t) {
            case .turnOff: return (attempts, t)
            case .retry(let d): t += d
            }
        }
        Issue.record("never turned off")
        return (attempts, t)
    }

    @Test func turnsOffFifteenMinutesIntoAnOutage() {
        let (attempts, offAt) = outage(WebhookResult(status: 503))
        #expect(offAt == Webhook.giveUpAfter)
        #expect(attempts == [0, 5, 35, 155, 455, 755, 900])
    }

    @Test func clientErrorsAreRetriedToo() {
        #expect(outage(WebhookResult(status: 404)).offAt == Webhook.giveUpAfter)
        #expect(outage(WebhookResult(status: 302)).offAt == Webhook.giveUpAfter)
        #expect(outage(WebhookResult(status: nil, error: "timed out")).offAt == Webhook.giveUpAfter)
    }

    @Test func goneTurnsOffAtOnce() {
        #expect(outage(WebhookResult(status: 410)).attempts == [0])
    }

    @Test func clockSpansEvents() {
        // A new event during an outage doesn't restart the clock.
        let start = Date(timeIntervalSince1970: 0)
        let late = Webhook.next(after: WebhookResult(status: 500), failingSince: start, failures: 1, now: start + 899)
        #expect(late == .retry(after: 1))
        #expect(Webhook.next(after: WebhookResult(status: 500), failingSince: start, failures: 1, now: start + 900) == .turnOff)
    }

    @Test func resultClassification() {
        #expect(WebhookResult(status: 200).ok)
        #expect(WebhookResult(status: 204).ok)
        #expect(!WebhookResult(status: 302).ok)
        #expect(WebhookResult(status: 302).summary.contains("redirect"))
        #expect(WebhookResult(status: nil, error: "timed out").summary == "timed out")
    }
}

@Suite struct WebhookRequestTests {
    let secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
    let url = URL(string: "https://agent.example.com/hooks/imessage")!
    let body = Data(#"{"id":"msg_42","type":"message.received"}"#.utf8)

    @Test func carriesStandardWebhooksHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r = Webhook.request(url: url, id: "msg_42", body: body, secret: secret, userAgent: "iMessageBridge/1.2.3", now: now)
        #expect(r.httpMethod == "POST")
        #expect(r.url == url)
        #expect(r.httpBody == body)
        #expect(r.timeoutInterval == Webhook.timeout)
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == "iMessageBridge/1.2.3")
        #expect(r.value(forHTTPHeaderField: "webhook-id") == "msg_42")
        #expect(r.value(forHTTPHeaderField: "webhook-timestamp") == "1700000000")
        let sig = try #require(r.value(forHTTPHeaderField: "webhook-signature"))
        #expect(sig.hasPrefix("v1,"))
        #expect(WebhookSignature.verify(id: "msg_42", timestamp: 1_700_000_000, body: body, secret: secret, header: sig))
        #expect(!WebhookSignature.verify(id: "msg_42", timestamp: 1_700_000_000, body: body, secret: "whsec_b3RoZXI=", header: sig))
    }

    @Test func retriesKeepTheIDButSignAFreshTimestamp() throws {
        let a = Webhook.request(url: url, id: "msg_42", body: body, secret: secret, userAgent: "x",
                                now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = Webhook.request(url: url, id: "msg_42", body: body, secret: secret, userAgent: "x",
                                now: Date(timeIntervalSince1970: 1_700_000_030))
        #expect(a.value(forHTTPHeaderField: "webhook-id") == b.value(forHTTPHeaderField: "webhook-id"))
        #expect(b.value(forHTTPHeaderField: "webhook-timestamp") == "1700000030")
        #expect(a.value(forHTTPHeaderField: "webhook-signature") != b.value(forHTTPHeaderField: "webhook-signature"))
        let sig = try #require(b.value(forHTTPHeaderField: "webhook-signature"))
        #expect(WebhookSignature.verify(id: "msg_42", timestamp: 1_700_000_030, body: body, secret: secret, header: sig))
    }

    @Test func testEventHasNoMessageData() throws {
        let t = Webhook.testEvent(agent: "Grok Bot")
        #expect(t.id.hasPrefix("test_"))
        let obj = try #require(JSONSerialization.jsonObject(with: t.body) as? [String: Any])
        #expect(obj["type"] as? String == "webhook.test")
        #expect(obj["id"] as? String == t.id)
        let data = try #require(obj["data"] as? [String: Any])
        #expect(data["agent"] as? String == "Grok Bot")
        #expect(data["messages"] == nil)
        #expect(data["from"] == nil)
    }
}

@Suite struct WebhookQueueTests {
    @Test func dropsOldestPastCapacity() {
        var q = WebhookQueue<Int>(capacity: 3)
        #expect(q.append(contentsOf: [1, 2]) == 0)
        #expect(q.append(contentsOf: [3, 4, 5]) == 2)
        #expect(q.items == [3, 4, 5])
        #expect(q.popFirst() == 3)
        #expect(q.count == 2)
        q.removeAll()
        #expect(q.isEmpty)
        #expect(q.popFirst() == nil)
    }
}
