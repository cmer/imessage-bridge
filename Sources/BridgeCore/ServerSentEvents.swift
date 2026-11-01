import Foundation

/// Server-Sent Events (text/event-stream) framing, shared by the app's
/// GET /v1/events and the CLI's `watch`.
public enum SSE {
    /// One event. Each line of `data` becomes its own `data:` line. With no
    /// `id`, the client's last event ID stays as it was.
    public static func frame(id: String? = nil, event: String? = nil, data: String) -> Data {
        var s = ""
        if let id { s += "id: \(oneLine(id))\n" }
        if let event { s += "event: \(oneLine(event))\n" }
        let lines = data.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines { s += "data: \(line)\n" }
        s += "\n"
        return Data(s.utf8)
    }

    /// Sets the client's last event ID without sending an event, so a client
    /// that reconnects before any event arrives resumes from here.
    public static func id(_ id: String) -> Data {
        Data("id: \(oneLine(id))\n\n".utf8)
    }

    /// A comment line, which clients ignore. Used for "connected" and keep-alive pings.
    public static func comment(_ text: String) -> Data {
        Data(": \(oneLine(text))\n\n".utf8)
    }

    /// The frames for one batch of new messages.
    ///
    /// Events come from `MessageService.events`, one per chat, and a chat's
    /// messages can interleave with another's. If every event carried its own
    /// row as the ID, a client that dropped mid-batch could resume past a
    /// message it never got. So only the batch's last frame carries an ID,
    /// `batchLastRow` (the newest row in the batch): a client that drops
    /// mid-batch gets the whole batch again, and can skip repeats by the
    /// event's `id` field.
    public static func frames(for events: [MessageEvent], batchLastRow: Int64) -> Data {
        var out = Data()
        for (i, e) in events.enumerated() {
            let last = i == events.count - 1
            out += frame(id: last ? String(batchLastRow) : nil, event: MessageEvent.type,
                         data: String(decoding: e.json, as: UTF8.self))
        }
        return out
    }

    /// Seconds to wait before reconnect attempt `attempt` (0-based): 1, 2, 4… up to 30.
    public static func retryDelay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(min(max(attempt, 0), 5))))
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// A received event.
public struct SSEEvent: Equatable, Sendable {
    public var id: String?
    public var event: String
    public var data: String

    public init(id: String? = nil, event: String = "message", data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

/// Reads a text/event-stream incrementally, following the WHATWG rules that
/// matter here: data, event and id fields, comments, any line ending, and an
/// event ID that persists until the next `id:` line.
public struct SSEParser: Sendable {
    /// The last event ID seen, to send back as Last-Event-ID when reconnecting.
    public private(set) var lastEventID: String?

    private var buffer = Data()
    private var data: [String] = []
    private var event = ""
    private var sawCR = false

    public init(lastEventID: String? = nil) {
        self.lastEventID = lastEventID
    }

    /// Adds bytes as they arrive and returns the events they complete.
    public mutating func feed(_ bytes: Data) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in bytes {
            if b == 0x0A, sawCR { sawCR = false; continue }   // \n after \r
            sawCR = b == 0x0D
            if b == 0x0A || b == 0x0D {
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                if let e = process(line) { out.append(e) }
            } else {
                buffer.append(b)
            }
        }
        return out
    }

    private mutating func process(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { data = []; event = "" }
            guard !data.isEmpty else { return nil }
            return SSEEvent(id: lastEventID, event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        var field = line
        var value = ""
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        }
        switch field {
        case "data": data.append(value)
        case "event": event = value
        case "id" where !value.contains("\0"): lastEventID = value
        default: break
        }
        return nil
    }
}
