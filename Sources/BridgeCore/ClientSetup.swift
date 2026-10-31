import Foundation

/// Setup snippets for MCP clients, shared by the app and the CLI so both
/// always produce the same configuration.
public enum ClientSetup {
    public static let connectorName = "imessage"

    /// Credential file name for an agent (also its `--agent` argument).
    public static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let trimmed = s.split(separator: "-").joined(separator: "-")
        return trimmed.isEmpty ? "agent" : String(trimmed.prefix(40))
    }

    public static var credentialsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/imessage-bridge/agents")
    }

    public static func credentialURL(agent: String) -> URL {
        credentialsDir.appendingPathComponent(slug(agent) + ".json")
    }

    public static func hasCredential(agent: String) -> Bool {
        FileManager.default.fileExists(atPath: credentialURL(agent: agent).path)
    }

    /// The stable CLI symlink from scripts/install.sh if present, else `fallback`.
    public static func cliPath(fallback: String) -> String {
        let link = NSHomeDirectory() + "/.local/bin/imessage-bridge"
        return FileManager.default.fileExists(atPath: link) ? link : fallback
    }

    public static func mcpArgs(agent: String) -> [String] {
        ["mcp", "--agent", slug(agent)]
    }

    /// `{"mcpServers": {"imessage": {"command": …, "args": […]}}}` — the format
    /// Claude Desktop and Cursor accept.
    public static func mcpServersJSON(cli: String, agent: String) -> String {
        let obj: [String: Any] = ["mcpServers": [connectorName: ["command": cli, "args": mcpArgs(agent: agent)]]]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Turns the words after a tool name into its arguments, typed by the
    /// tool's input schema. Either `key=value` words, or one JSON object (handy
    /// for message text with quotes or newlines). A value stays a string when
    /// the schema says string, so `to=+15555550142` and `text=7` stay text.
    public static func toolArguments(_ words: [String], schema: [String: Any]) throws -> [String: Any] {
        let props = schema["properties"] as? [String: Any] ?? [:]
        let known = props.keys.sorted().joined(separator: ", ")
        func check(_ key: String) throws -> String? {
            guard let p = props[key] as? [String: Any] else {
                throw BridgeError.invalid(known.isEmpty
                    ? "this tool takes no arguments, got \"\(key)\""
                    : "unknown argument \"\(key)\"; this tool takes: \(known)")
            }
            return p["type"] as? String
        }

        if words.count == 1, words[0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(words[0].utf8))) as? [String: Any] else {
                throw BridgeError.invalid("the arguments aren't a valid JSON object")
            }
            for k in obj.keys { _ = try check(k) }
            return obj
        }

        var out: [String: Any] = [:]
        for w in words {
            guard let eq = w.firstIndex(of: "="), eq != w.startIndex else {
                throw BridgeError.invalid("expected key=value or one JSON object, got \"\(w)\"")
            }
            let key = String(w[..<eq]), raw = String(w[w.index(after: eq)...])
            switch try check(key) {
            case "integer":
                guard let i = Int(raw) else { throw BridgeError.invalid("\(key) must be a whole number") }
                out[key] = i
            case "number":
                guard let d = Double(raw), d.isFinite else { throw BridgeError.invalid("\(key) must be a number") }
                out[key] = d
            case "boolean":
                guard raw == "true" || raw == "false" else { throw BridgeError.invalid("\(key) must be true or false") }
                out[key] = raw == "true"
            default:
                out[key] = raw
            }
        }
        return out
    }

    public static func claudeCodeCommand(cli: String, agent: String) -> String {
        "claude mcp add \(connectorName) --scope user -- \(shellQuote(cli)) " + mcpArgs(agent: agent).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-~".contains($0) })
            ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
