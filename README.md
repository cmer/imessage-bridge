# iMessage Bridge

A macOS menu bar app that lets AI agents (Claude, Grok, ChatGPT, Cursor, …) read and send
your iMessages, with separate permissions for each agent.

It runs an [MCP](https://modelcontextprotocol.io) server on your Mac, so any MCP client can
connect without custom glue. Agents pair with a one-time approval on the Mac and get their own
token. You decide in the app what each one can do.

## How it works

```
 Agent (Claude Code, Grok…)                      iMessage Bridge.app (menu bar)
 ─────────────────────────                       ──────────────────────────────
 stdio MCP ──► imessage-bridge mcp ──HTTP──►  127.0.0.1:7542/mcp ──► chat.db (read-only)
                (adds the agent's token)          │                    AddressBook (read-only)
                                                  │  per-agent         Messages.app via
 HTTP MCP client ─────────────Bearer token──────► │  permissions       AppleScript (send)
                                                  │
 Other computer ──── TLS, pinned certificate ──► :7543 (off by default)
```

- **One signed app** reads `~/Library/Messages/chat.db` with SQLite and sends through
  AppleScript. Full Disk Access is granted to this app only. Agents never touch the
  database.
- **Pairing**: `imessage-bridge pair --name Grok --read --send` opens an approval window
  on the Mac showing a 6-digit code. You check the code, adjust permissions and approve.
  The agent receives a random token, and the app stores only its SHA-256 hash.
- **Per-agent permissions**: read, send, ask before every send, hide verification
  codes/card/SSN numbers, network access, and all conversations or only selected ones.
  Revoke any agent at any time.
- **Sending** shows a native dialog with the full message (Cancel is the default) unless
  you turn that off for an agent. Sends are capped at 30 per hour per agent either way.
- **Activity** lists every tool call by agent. Message text is never logged.

## Tools exposed over MCP

| Tool | Permission | What it does |
|---|---|---|
| `review_messages` | read | Triage recent threads into needs reply / low priority / automated |
| `list_chats` | read | Recent conversations with participants and contact names |
| `get_conversation` | read | One conversation by name, phone, email, group name or chat ID |
| `search_messages` | read | Text search, optionally within one conversation |
| `response_stats` | read | Your reply times in a conversation |
| `lookup_contact` | read | Phone numbers and emails for a contact |
| `send_message` | send | Send to one phone number or email (not groups) |

Agents only see the tools they're allowed to use. With "only selected conversations", every
tool, including contact lookup and sending, is limited to those chats.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Xcode
itself is not required.

```bash
./scripts/install.sh
```

This builds `iMessage Bridge.app`, installs it to `/Applications`, links the CLI at
`~/.local/bin/imessage-bridge`, and opens the app. Then, once:

1. **Full Disk Access**: on the app's Setup page, click *Open Full Disk Access Settings*
   and turn on iMessage Bridge. macOS only allows this by hand.
2. **Sending only**: click *Request Permission* next to "Control Messages".

An agent can do the rest. Point it at [AGENT_SETUP.md](AGENT_SETUP.md), or paste the
prompt shown on the Setup page.

### Signing

`scripts/build.sh` signs with the first *Developer ID Application* identity in your
keychain, or `$SIGN_IDENTITY` if set, and falls back to ad hoc signing. With a stable
Developer ID, the Full Disk Access grant survives rebuilds. With ad hoc signing, you have
to grant it again after every rebuild.

## Safety: recipients and prompt injection

Anyone who texts you can write instructions an agent might follow. The **Safety** page has
two independent layers:

- **Allowed recipients** (on by default). Sending to anyone not on the list always shows the
  confirmation dialog, even for agents allowed to send without asking. The dialog has an
  "Always allow sending to…" checkbox, and an optional toggle allows everyone in your
  contacts. This is deterministic: no message wording can get past it.
- **Prompt injection detection** (optional; needs a TypeSafe or OpenRouter API key, stored
  in the Keychain). Incoming messages are checked with TypeSafe's Jev model before an agent
  sees them. By default only senders not in your contacts are checked. A flagged message is
  hidden from the agent (or shown with a warning), and that agent must get your confirmation
  for every send over the next 30 minutes. Local checks run first and catch blatant cases and
  hidden Unicode "tag" text for free.

The Jev prompt (`Sources/BridgeCore/JevPrompt.swift`) is designed around Datadog Security
Labs' finding that a counterfeit policy embedded in the message can flip Jev's verdict.
Definitions live only in trusted instructions, any attempt to label or redefine the check
counts as evidence of an attack, and a separate question looks only for such attempts.
Detection still can't be perfect; treat it as an alarm and rely on the recipient list.

## Network access (optional)

Off by default. When turned on (Network page), the app also listens on port 7543 with TLS,
using a self-signed certificate generated on first use. Clients pin its SHA-256
fingerprint at pairing time, so no certificate authority is involved:

```bash
imessage-bridge pair --name "Laptop Claude" --read \
  --url https://your-mac.local:7543 --fingerprint C2:73:…:17:77
```

An agent also needs "Allow connections from other computers" enabled, so a token from
a local-only agent is useless from another machine. If you can, use Tailscale rather than
opening the port on shared Wi-Fi.

## CLI

```
imessage-bridge pair --name <agent> [--read] [--send] [--url URL --fingerprint FP]
imessage-bridge mcp --agent <agent>          # stdio MCP server for clients
imessage-bridge call --agent <agent> [tool key=value …]   # one tool call, no MCP client needed
imessage-bridge config --agent <agent>       # print client setup snippets
imessage-bridge status [--agent <agent>]
imessage-bridge agents | forget --agent <agent>
```

Credentials are stored in `~/.config/imessage-bridge/agents/<agent>.json` (mode 600).
App settings and agents are stored in `~/Library/Application Support/iMessage Bridge/`.

## Security notes

- The local server binds to 127.0.0.1 only. It rejects requests that carry an `Origin`
  header (web pages) or an unexpected `Host` header (DNS rebinding).
- Any program running as you can read the credential files, just as it can read your
  other dotfiles. The app is the boundary: tokens can be revoked, and each one is limited
  to what you granted.
- **Prompt injection is the main risk.** Anyone who texts you can write instructions an
  agent might follow. Keep "Ask me before every send" on unless you have a good reason.
- Messages an agent reads are sent to that agent's AI provider.

## Development

```bash
swift build          # debug build of all targets
swift test           # unit tests (Swift Testing)
./scripts/build.sh   # release .app in ./build
```

Layout: `Sources/BridgeCore` (database, contacts, decoding, validation),
`Sources/IMessageBridgeApp` (menu bar app, HTTP/MCP server, UI), `Sources/imessage-bridge`
(CLI).

## Credits

Message-body decoding, redaction and triage rules are adapted from
[grokbot-imessage-skill](https://github.com/jeffhuber/grokbot-imessage-skill) by Jeff Huber
(MIT). See [LICENSE](LICENSE).
