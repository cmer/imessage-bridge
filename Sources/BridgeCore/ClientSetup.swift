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
    /// Grok Bot's custom connector dialog, Claude Desktop and Cursor accept.
    public static func mcpServersJSON(cli: String, agent: String) -> String {
        let obj: [String: Any] = ["mcpServers": [connectorName: ["command": cli, "args": mcpArgs(agent: agent)]]]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Grok Bot runs command connectors on xAI's cloud machines, where this
    /// Mac's CLI doesn't exist. An HTTP connector with `placement: client`
    /// asks the Grok Bot app on this Mac to make the connection instead, so
    /// it can reach the bridge on 127.0.0.1. The token goes in the header.
    public static func grokConnectorJSON(url: String, token: String) -> String {
        let server: [String: Any] = [
            "type": "http",
            "url": url + "/mcp",
            "headers": ["Authorization": "Bearer " + token],
            "placement": "client",
        ]
        let obj: [String: Any] = ["mcpServers": [connectorName: server]]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The saved credential's URL and token, if this Mac has one for `agent`.
    public static func savedCredential(agent: String) -> (url: String, token: String)? {
        guard let d = try? Data(contentsOf: credentialURL(agent: agent)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let url = o["url"] as? String, let token = o["token"] as? String else { return nil }
        return (url, token)
    }

    /// Turns `key=value` words into tool arguments: numbers and true/false
    /// become JSON numbers and booleans, everything else stays a string.
    public static func toolArguments(_ words: [String]) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for w in words {
            guard let eq = w.firstIndex(of: "="), eq != w.startIndex else {
                throw BridgeError.invalid("expected key=value, got \"\(w)\"")
            }
            let key = String(w[..<eq]), raw = String(w[w.index(after: eq)...])
            if let i = Int(raw) { out[key] = i }
            else if raw == "true" || raw == "false" { out[key] = raw == "true" }
            else { out[key] = raw }
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
