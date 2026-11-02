import Foundation

/// MCP tool definitions, filtered by what each agent may do.
enum Tools {
    static let readTools = ["review_messages", "list_chats", "get_conversation", "search_messages",
                            "response_stats", "lookup_contact"]

    static func allowed(for agent: AgentRecord) -> [String] {
        (agent.canRead ? readTools : []) + (agent.canSend ? ["send_message"] : [])
    }

    static func definitions(for agent: AgentRecord) -> [[String: Any]] {
        let allowed = Set(allowed(for: agent))
        return all.filter { allowed.contains($0["name"] as! String) }
    }

    /// One-line summary for the activity log. Never includes message text.
    static func describe(_ name: String, _ a: [String: Any]) -> String {
        func v(_ k: String) -> String? { a[k].map { "\($0)" } }
        switch name {
        case "send_message":
            let n = (a["text"] as? String)?.count ?? 0
            return "to \(v("to") ?? "?") (\(n) characters)"
        default:
            return ["chat", "query", "name", "days", "hours", "limit"]
                .compactMap { k in v(k).map { "\(k)=\($0)" } }
                .joined(separator: " ")
        }
    }

    private static let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]

    private static let all: [[String: Any]] = [
        [
            "name": "review_messages",
            "title": "Review recent messages",
            "description": "Triage recent conversations whose last message is from someone else. Returns three buckets: needs_reply, low_priority (reactions, 'ok', 'thanks') and automated (codes, deliveries, alerts), each with recent context.",
            "inputSchema": schema([
                "days": ["type": "number", "description": "How far back to look, in days (default 2, max 30)."],
            ]),
            "annotations": readOnly,
        ],
        [
            "name": "list_chats",
            "title": "List conversations",
            "description": "List conversations with activity in the last N days, newest first, with participants and resolved contact names.",
            "inputSchema": schema([
                "days": ["type": "number", "description": "Activity window in days (default 30)."],
                "limit": ["type": "integer", "description": "Maximum chats to return (default 50, max 500)."],
                "query": ["type": "string", "description": "Optional filter on name, phone, email or group name."],
            ]),
            "annotations": readOnly,
        ],
        [
            "name": "get_conversation",
            "title": "Read a conversation",
            "description": "Messages from one conversation, oldest first. `chat` can be a contact name, phone number, email, group name or chat_id from list_chats.",
            "inputSchema": schema([
                "chat": ["type": "string", "description": "Contact name, phone, email, group name or chat_id."],
                "days": ["type": "number", "description": "How far back, in days (default 7)."],
                "limit": ["type": "integer", "description": "Maximum messages, most recent kept (default 100, max 1000)."],
            ], required: ["chat"]),
            "annotations": readOnly,
        ],
        [
            "name": "search_messages",
            "title": "Search messages",
            "description": "Case-insensitive text search across messages, newest first. Optionally limit to one conversation.",
            "inputSchema": schema([
                "query": ["type": "string", "description": "Text to find."],
                "chat": ["type": "string", "description": "Optional conversation (name, phone, email or chat_id)."],
                "days": ["type": "number", "description": "How far back, in days (default 30)."],
                "limit": ["type": "integer", "description": "Maximum matches (default 50, max 500)."],
            ], required: ["query"]),
            "annotations": readOnly,
        ],
        [
            "name": "response_stats",
            "title": "Reply-time statistics",
            "description": "How quickly the user replies in one conversation: average, median, fastest and slowest reply times.",
            "inputSchema": schema([
                "chat": ["type": "string", "description": "Contact name, phone, email or chat_id."],
                "hours": ["type": "number", "description": "Window in hours (default 24)."],
            ], required: ["chat"]),
            "annotations": readOnly,
        ],
        [
            "name": "lookup_contact",
            "title": "Look up a contact",
            "description": "Find contacts by name, phone or email and return their phone numbers and email addresses.",
            "inputSchema": schema([
                "name": ["type": "string", "description": "Name (or part of it), phone or email."],
            ], required: ["name"]),
            "annotations": readOnly,
        ],
        [
            "name": "send_message",
            "title": "Send an iMessage",
            "description": "Send a plain-text message to one phone number or email address. Group chats are not supported. Show the user the exact text before calling. The message goes into the existing conversation when there is one, so Messages picks iMessage, RCS or SMS itself; the result reports the service used and is returned only after the Mac's message database confirms the send. An error means nothing was delivered. Depending on settings, the user may have to approve the send on the Mac; if they decline, nothing is sent.",
            "inputSchema": schema([
                "to": ["type": "string", "description": "Recipient phone number (with area code) or email address."],
                "text": ["type": "string", "description": "Message body, up to 4000 characters."],
                "service": ["type": "string", "enum": ["iMessage", "SMS"], "description": "Force a service instead of using the existing conversation. Leave unset normally."],
            ], required: ["to", "text"]),
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": true],
        ],
    ]

    private static func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
}
