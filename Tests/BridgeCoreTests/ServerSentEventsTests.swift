import Foundation
import Testing
@testable import BridgeCore

@Suite struct ServerSentEventsTests {
    func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    @Test func framesSplitDataLines() {
        let f = SSE.frame(id: "42", event: "message.received", data: "a\nb\r\nc")
        #expect(text(f) == "id: 42\nevent: message.received\ndata: a\ndata: b\ndata: c\n\n")
        #expect(text(SSE.comment("ping")) == ": ping\n\n")
        #expect(text(SSE.frame(id: "1\n2", data: "x")) == "id: 1 2\ndata: x\n\n")
    }

    @Test func parserRoundTripsFrames() {
        var p = SSEParser()
        let stream = SSE.comment("connected") + SSE.frame(id: "7", event: "message.received", data: "{\"a\":1}\nsecond")
        let events = p.feed(stream)
        #expect(events == [SSEEvent(id: "7", event: "message.received", data: "{\"a\":1}\nsecond")])
        #expect(p.lastEventID == "7")
    }

    @Test func parserHandlesSplitChunksAndLineEndings() {
        var p = SSEParser(lastEventID: "3")
        let raw = Data("data:one\r\n\r\nevent: x\rdata: two\r\rid: 9\ndata: three\n\n".utf8)
        var events: [SSEEvent] = []
        for b in raw { events += p.feed(Data([b])) }   // one byte at a time, so \r\n spans chunks
        #expect(events == [
            SSEEvent(id: "3", event: "message", data: "one"),
            SSEEvent(id: "3", event: "x", data: "two"),
            SSEEvent(id: "9", event: "message", data: "three"),
        ])
    }

    @Test func idOnlyFrameMovesResumePointWithoutAnEvent() {
        var p = SSEParser()
        #expect(p.feed(SSE.id("120") + SSE.comment("ping")).isEmpty)
        #expect(p.lastEventID == "120")
    }

    @Test func batchCarriesOneResumeIDAtTheEnd() {
        let e = { (row: Int64) in
            MessageEvent(id: "msg_\(row)", rowID: row, payload: ["id": "msg_\(row)", "type": MessageEvent.type])
        }
        var p = SSEParser(lastEventID: "5")
        let events = p.feed(SSE.frames(for: [e(12), e(11)], batchLastRow: 12))
        #expect(events.count == 2)
        #expect(events[0].id == "5")   // a drop here resumes before the batch
        #expect(events[0].data.contains("msg_12"))
        #expect(events[1].id == "12")
        #expect(events.allSatisfy { $0.event == "message.received" })
        #expect(p.lastEventID == "12")
    }

    @Test func retryBacksOffToThirtySeconds() {
        #expect((0..<8).map(SSE.retryDelay) == [1, 2, 4, 8, 16, 30, 30, 30])
    }
}
