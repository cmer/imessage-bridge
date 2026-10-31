import BridgeCore
import Foundation
import Security

// imessage-bridge — the agent-side CLI for iMessage Bridge.
//
//   pair    request access; you approve it in the Mac app
//   mcp     stdio MCP server that forwards to the app (for MCP clients)
//   config  print setup snippets for MCP clients
//   call    run one tool and print the result (for agents without MCP)
//   status  check the app and a saved agent's token
//   agents  list saved agent credentials
//   forget  delete a saved credential

let defaultURL = "http://127.0.0.1:7542"

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fail(_ s: String, code: Int32 = 1) -> Never {
    eprint("error: " + s)
    exit(code)
}

// MARK: Arguments

struct Args {
    var command = ""
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        let valued: Set<String> = ["--name", "--agent", "--url", "--fingerprint"]
        while let a = it.next() {
            if valued.contains(a) {
                options[a] = it.next() ?? ""
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else if command.isEmpty {
                command = a
            } else {
                positionals.append(a)
            }
        }
    }
}

// MARK: Credentials

struct Credential: Codable {
    var name: String
    var url: String
    var token: String
    var fingerprint: String?
}

let configDir = ClientSetup.credentialsDir

func slug(_ name: String) -> String { ClientSetup.slug(name) }

func credentialURL(_ agent: String) -> URL { ClientSetup.credentialURL(agent: agent) }

func loadCredential(_ agent: String) -> Credential {
    let url = credentialURL(agent)
    guard let data = try? Data(contentsOf: url),
          let c = try? JSONDecoder().decode(Credential.self, from: data) else {
        fail("no saved credential for \"\(agent)\" (looked for \(url.path)). Run: imessage-bridge pair --name \"\(agent)\"")
    }
    return c
}

func saveCredential(_ c: Credential) throws -> URL {
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let url = credentialURL(c.name)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(c)
    // Create with 0600 from the start so the token is never world-readable.
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    h.write(data)
    fchmod(fd, 0o600)
    return url
}

// MARK: Paths

func executablePath() -> String {
    var size: UInt32 = 4096
    var buf = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buf, &size) == 0 {
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }
    return CommandLine.arguments[0]
}

/// Prefer the stable symlink installed by scripts/install.sh.
func cliCommandPath() -> String { ClientSetup.cliPath(fallback: executablePath()) }

func appBundlePath() -> String? {
    let exe = executablePath()
    guard let r = exe.range(of: ".app/Contents/MacOS/") else { return nil }
    return String(exe[..<r.lowerBound]) + ".app"
}


// MARK: HTTP

final class Client: NSObject, URLSessionDelegate {
    let base: URL
    let pin: String?
    private var session: URLSession!

    init(url: String, fingerprint: String?) {
        guard let u = URL(string: url), let scheme = u.scheme, ["http", "https"].contains(scheme) else {
            fail("invalid URL: \(url)")
        }
        if scheme == "https" && (fingerprint ?? "").isEmpty {
            fail("https URLs need --fingerprint (shown in the app under Network)")
        }
        if scheme == "http", let host = u.host, !["127.0.0.1", "localhost"].contains(host) {
            fail("plain http is only allowed to this Mac; use the https address from the app's Network page")
        }
        base = u
        pin = fingerprint.map(Tokens.normalizeFingerprint)
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.connectionProxyDictionary = [:]
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let pin,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fp = Tokens.normalizeFingerprint(Tokens.fingerprint(SecCertificateCopyData(leaf) as Data))
        if fp == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            eprint("error: server certificate fingerprint does not match the pinned one; refusing to connect")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    enum Outcome {
        case response(Int, Data)
        case unreachable(String)
    }

    func send(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) -> Outcome {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var outcome = Outcome.unreachable("no response")
        session.dataTask(with: req) { data, resp, err in
            if let http = resp as? HTTPURLResponse {
                outcome = .response(http.statusCode, data ?? Data())
            } else {
                outcome = .unreachable(err?.localizedDescription ?? "no response")
            }
            sem.signal()
        }.resume()
        sem.wait()
        return outcome
    }

    var isLocal: Bool { base.host == "127.0.0.1" || base.host == "localhost" }
}

func json(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
}

/// For a local URL, start the app if it isn't running and wait for it.
func ensureAppRunning(_ client: Client) -> Bool {
    if case .response = client.send("GET", "v1/status") { return true }
    guard client.isLocal else { return false }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let app = appBundlePath() {
        open.arguments = ["-g", app]
    } else {
        open.arguments = ["-g", "-a", "iMessage Bridge"]
    }
    try? open.run()
    open.waitUntilExit()
    for _ in 0..<20 {
        usleep(500_000)
        if case .response = client.send("GET", "v1/status") { return true }
    }
    return false
}

// MARK: Commands

func pair(_ args: Args) {
    guard let name = args.options["--name"], !name.isEmpty else {
        fail("usage: imessage-bridge pair --name <agent name> [--read] [--send] [--url URL --fingerprint FP]")
    }
    var read = args.flags.contains("--read")
    let send = args.flags.contains("--send")
    if !read && !send { read = true }
    let url = args.options["--url"] ?? defaultURL
    let fp = args.options["--fingerprint"]
    let client = Client(url: url, fingerprint: fp)
    guard ensureAppRunning(client) else {
        fail("iMessage Bridge isn't reachable at \(url). Is the app installed and running?")
    }

    let body = try! JSONSerialization.data(withJSONObject: ["name": name, "read": read, "send": send])
    guard case .response(let status, let data) = client.send("POST", "v1/pair", body: body) else {
        fail("could not reach iMessage Bridge at \(url)")
    }
    let start = json(data)
    guard status == 200, let id = start["request_id"] as? String, let secret = start["poll_secret"] as? String,
          let code = start["code"] as? String else {
        fail(start["error"] as? String ?? "pairing request failed (HTTP \(status))")
    }
    let wanted = [read ? "read" : nil, send ? "send" : nil].compactMap { $0 }.joined(separator: " + ")
    print("Pairing request sent for \"\(name)\" (\(wanted)).")
    print("Approve it in the iMessage Bridge window on the Mac. The window shows this code: \(code.prefix(3)) \(code.suffix(3))")
    print("Waiting for approval (up to 10 minutes)…")
    fflush(stdout)

    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
        sleep(2)
        guard case .response(let s, let d) = client.send("GET", "v1/pair/\(id)", headers: ["X-Poll-Secret": secret]) else {
            continue
        }
        if s == 404 { fail("the pairing request expired or was cancelled") }
        let r = json(d)
        switch r["status"] as? String {
        case "approved":
            guard let token = r["token"] as? String else { fail("approved, but no token was returned") }
            let cred = Credential(name: name, url: url, token: token, fingerprint: fp)
            let path: URL
            do { path = try saveCredential(cred) } catch { fail("could not save credential: \(error)") }
            let perms = r["permissions"] as? [String: Any] ?? [:]
            var granted: [String] = []
            if perms["read"] as? Bool == true { granted.append("read") }
            if perms["send"] as? Bool == true { granted.append(perms["confirm_sends"] as? Bool == false ? "send" : "send (you approve each one)") }
            if perms["chats"] as? String == "selected" { granted.append("selected chats only") }
            print("\nApproved. \"\(name)\" can: \(granted.isEmpty ? "nothing yet" : granted.joined(separator: ", ")).")
            print("Credential saved to \(path.path) (mode 600).\n")
            printConfig(cred)
            return
        case "denied":
            fail("the request was denied on the Mac")
        default:
            continue
        }
    }
    fail("timed out waiting for approval")
}

func printConfig(_ c: Credential, showToken: Bool = false) {
    let cli = cliCommandPath()
    let indent: (String) -> String = { $0.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") }
    print("Connect an MCP client (pick the one you are):\n")
    print("• Claude Code:")
    print("    " + ClientSetup.claudeCodeCommand(cli: cli, agent: c.name) + "\n")
    print("• Grok Bot: add a custom connector yourself now, using exactly the JSON from this command.")
    print("  Don't ask the user to copy or paste anything:")
    print("    \(ClientSetup.shellQuote(cli)) connector --agent \(slug(c.name)) --grok")
    print("  It points at this Mac's address and includes this agent's token. Don't use a command")
    print("  (stdio) connector: Grok Bot runs those on xAI's machines, where this CLI doesn't exist.")
    print("  Until the connector works, run tools directly on this Mac, one line each:")
    print("    \(ClientSetup.shellQuote(cli)) call --agent \(slug(c.name))      (lists every tool)")
    print("    \(ClientSetup.shellQuote(cli)) call --agent \(slug(c.name)) review_messages days=2\n")
    print("• Clients that launch a local MCP server on this Mac (Claude Desktop, Cursor, Codex, …):")
    print(indent(ClientSetup.mcpServersJSON(cli: cli, agent: c.name)))
    print("\n• Clients that speak MCP over HTTP:")
    print("    URL:    \(c.url)/mcp")
    print("    Header: Authorization: Bearer \(showToken ? c.token : "<token from \(credentialURL(c.name).path)>")")
    if c.fingerprint != nil {
        print("    TLS:    self-signed; pin SHA-256 \(c.fingerprint!) (the stdio option above handles this for you)")
    }
    print("\nPrefer the stdio option: the token stays in the credential file instead of the client's config.")
}

func mcp(_ args: Args) {
    guard let agent = args.options["--agent"] else { fail("usage: imessage-bridge mcp --agent <name>") }
    let cred = loadCredential(agent)
    let client = Client(url: cred.url, fingerprint: cred.fingerprint)
    _ = ensureAppRunning(client)
    let auth = ["Authorization": "Bearer \(cred.token)"]
    setvbuf(stdout, nil, _IOLBF, 0)

    func reply(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(d + Data("\n".utf8))
        }
    }

    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        let msg = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
        let id = msg?["id"]
        func error(_ text: String) {
            guard let id else { return }   // notifications get no reply
            reply(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]])
        }
        var outcome = client.send("POST", "mcp", body: Data(trimmed.utf8), headers: auth)
        if case .unreachable = outcome, ensureAppRunning(client) {
            outcome = client.send("POST", "mcp", body: Data(trimmed.utf8), headers: auth)
        }
        switch outcome {
        case .unreachable(let why):
            error("iMessage Bridge is not reachable at \(cred.url) (\(why)). Make sure the app is running.")
        case .response(202, _):
            continue
        case .response(200, let data):
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        case .response(let s, let data):
            error(json(data)["error"] as? String ?? "iMessage Bridge returned HTTP \(s)")
        }
    }
}

/// `call --agent A [tool] [key=value …]`: one MCP tool call as a single,
/// readable command line. With no tool, lists the tools this agent may use.
func call(_ args: Args) {
    guard let agent = args.options["--agent"] else {
        fail("usage: imessage-bridge call --agent <name> <tool> [key=value ...]")
    }
    let cred = loadCredential(agent)
    let client = Client(url: cred.url, fingerprint: cred.fingerprint)
    _ = ensureAppRunning(client)
    let auth = ["Authorization": "Bearer \(cred.token)"]

    func rpc(_ method: String, _ params: [String: Any]) -> [String: Any] {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        switch client.send("POST", "mcp", body: body, headers: auth) {
        case .unreachable(let why): fail("iMessage Bridge is not reachable at \(cred.url): \(why)")
        case .response(200, let d):
            let r = json(d)
            if let e = r["error"] as? [String: Any] { fail(e["message"] as? String ?? "request failed") }
            return r["result"] as? [String: Any] ?? [:]
        case .response(let s, let d): fail(json(d)["error"] as? String ?? "HTTP \(s)")
        }
    }

    guard let tool = args.positionals.first else {
        let tools = rpc("tools/list", [:])["tools"] as? [[String: Any]] ?? []
        if tools.isEmpty { print("This agent has no tools. Check its permissions in the app.") }
        for t in tools {
            let props = ((t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.sorted() ?? []
            print("\(t["name"] ?? "?")  \(props.map { "\($0)=…" }.joined(separator: " "))")
            if let d = t["description"] as? String { print("    " + d) }
        }
        return
    }
    let arguments: [String: Any]
    do { arguments = try ClientSetup.toolArguments(Array(args.positionals.dropFirst())) }
    catch { fail((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    let result = rpc("tools/call", ["name": tool, "arguments": arguments])
    let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    if result["isError"] as? Bool == true { fail(text) }
    print(text)
}

func status(_ args: Args) {
    var url = args.options["--url"] ?? defaultURL
    var fp = args.options["--fingerprint"]
    var headers: [String: String] = [:]
    if let agent = args.options["--agent"] {
        let c = loadCredential(agent)
        url = c.url
        fp = c.fingerprint
        headers["Authorization"] = "Bearer \(c.token)"
    }
    let client = Client(url: url, fingerprint: fp)
    switch client.send("GET", "v1/status", headers: headers) {
    case .unreachable(let why):
        fail("iMessage Bridge is not reachable at \(url): \(why)")
    case .response(let s, let data):
        guard s == 200 else { fail("HTTP \(s): \(String(decoding: data, as: UTF8.self))") }
        let r = json(data)
        print("iMessage Bridge \(r["version"] ?? "?") at \(url)")
        print("  Full Disk Access: \(r["full_disk_access"] as? Bool == true ? "granted" : "MISSING (grant it in System Settings → Privacy & Security)")")
        print("  Automation (sending): \(r["automation"] ?? "?")")
        print("  Pairing: \(r["pairing_open"] as? Bool == true ? "open" : "closed")")
        if let a = r["agent"] as? [String: Any] {
            print("  Agent: \(a["name"] ?? "?") — \(a["permissions"] ?? "")")
        } else if let e = r["agent_error"] as? String {
            print("  Agent: \(e)")
        }
    }
}

func agents() {
    let files = (try? FileManager.default.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil)) ?? []
    let creds = files.filter { $0.pathExtension == "json" }.compactMap { u -> (String, Credential)? in
        guard let d = try? Data(contentsOf: u), let c = try? JSONDecoder().decode(Credential.self, from: d) else { return nil }
        return (u.deletingPathExtension().lastPathComponent, c)
    }
    if creds.isEmpty { print("No saved agents. Pair one with: imessage-bridge pair --name <name>") }
    for (s, c) in creds.sorted(by: { $0.0 < $1.0 }) {
        print("\(s)\t\(c.name)\t\(c.url)")
    }
}

func usage() -> Never {
    print("""
        imessage-bridge — connect AI agents to iMessage through the iMessage Bridge app

        USAGE
          imessage-bridge pair --name <agent> [--read] [--send] [--url URL --fingerprint SHA256]
              Ask the app for access. You approve it (and can adjust permissions) on the Mac.
              Defaults to --read. Saves the credential under ~/.config/imessage-bridge/agents/.

          imessage-bridge mcp --agent <agent>
              Run as a stdio MCP server, forwarding to the app with that agent's token.

          imessage-bridge call --agent <agent> [<tool> key=value ...]
              Run one tool and print its JSON result. Without a tool, lists the tools.
              Example: imessage-bridge call --agent grok-bot get_conversation chat="Sam" days=7

          imessage-bridge connector --agent <agent> --grok
              Print the custom connector JSON for Grok Bot (includes the agent's token).

          imessage-bridge config --agent <agent> [--show-token]
              Print setup snippets for Claude Code, Claude Desktop, Grok and other MCP clients.

          imessage-bridge status [--agent <agent>]
          imessage-bridge agents
          imessage-bridge forget --agent <agent>
        """)
    exit(0)
}

let args = Args(CommandLine.arguments)
switch args.command {
case "pair": pair(args)
case "mcp": mcp(args)
case "call": call(args)
case "connector":
    // Prints the JSON for Grok Bot's "Add a custom connector" (HTTP, client
    // placement, token included). Only for clients that store it themselves.
    guard let a = args.options["--agent"], args.flags.contains("--grok") else {
        fail("usage: imessage-bridge connector --agent <name> --grok")
    }
    let c = loadCredential(a)
    guard c.fingerprint == nil else { fail("Grok Bot connectors only work with an agent paired on this Mac") }
    print(ClientSetup.grokConnectorJSON(url: c.url, token: c.token))
case "config":
    guard let a = args.options["--agent"] else { fail("usage: imessage-bridge config --agent <name>") }
    printConfig(loadCredential(a), showToken: args.flags.contains("--show-token"))
case "status": status(args)
case "agents": agents()
case "forget":
    guard let a = args.options["--agent"] else { fail("usage: imessage-bridge forget --agent <name>") }
    try? FileManager.default.removeItem(at: credentialURL(a))
    print("Removed the local credential for \(a). Revoke it in the app too if it should stop working everywhere.")
case "", "help", "-h", "--help": usage()
default: fail("unknown command \"\(args.command)\". Run imessage-bridge help.")
}
