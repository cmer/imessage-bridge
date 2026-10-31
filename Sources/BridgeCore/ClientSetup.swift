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

    public static func claudeCodeCommand(cli: String, agent: String) -> String {
        "claude mcp add \(connectorName) --scope user -- \(shellQuote(cli)) " + mcpArgs(agent: agent).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-~".contains($0) })
            ? s
            : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
