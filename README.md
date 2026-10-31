# iMessage Bridge

A Mac menu bar app that gives AI agents like Claude, Grok and Cursor access to your
iMessages. You approve each agent and decide what it can do.

## What it does

Ask your agent which messages need a reply, catch up on a group chat, find what someone
said last month, or draft and send a text. The agent talks to the app, and the app reads
your Messages history and sends through Messages.app. The agent never touches your
Messages database directly.

- **You approve every agent.** A new agent shows up on your Mac with a 6-digit code.
  Nothing is shared until you click Approve.
- **Each agent gets its own rules.** Read only, or read and send. Limit it to a few
  conversations. Revoke it any time.
- **You confirm every send.** By default, each outgoing message pops up on your Mac for you
  to check first.
- **Suspicious messages are filtered.** Texts that try to give your agent instructions can
  be caught and hidden before it reads them.

## Install

Requires macOS 14 or later. Takes about five minutes.

1. **Install the app.** Either way works:

   - **Download:** get the `.dmg` from the
     [latest release](https://github.com/cmer/imessage-bridge/releases/latest), open it
     and drag **iMessage Bridge** to Applications.
   - **Homebrew:**

     ```bash
     brew install --cask cmer/tap/imessage-bridge
     ```

   Open the app. It lives in your menu bar (the two speech bubbles).

2. **Grant Full Disk Access.** On the Setup page, click *Open Full Disk Access Settings*
   and turn on **iMessage Bridge**. If you want agents to send messages, also click
   *Request Permission* next to "Control Messages".

3. **Connect your agent.** Click *Copy* next to the prompt on the Setup page and paste it
   into your agent (Claude Code, Grok Bot, or any agent that can run commands on your Mac).
   It sets itself up and asks whether it should be able to send messages or only read
   them. When the approval window appears, check that its code matches the one your agent
   shows you, then click *Approve*.

4. **Turn on message screening (recommended).** Anyone who texts you can write
   instructions your agent might follow. Screening checks incoming messages with
   TypeSafe's Jev model and hides suspicious ones from your agent. Get an API key from
   [TypeSafe](https://typesafe.ai), paste it on the app's Safety page and turn on *Check
   incoming messages for prompt injection*. While you're there, add the people your agent
   may text without asking you first.

That's it. Ask your agent "Which of my messages need a reply?" to try it.

## Advanced

Manual setup, client configuration and everything else. The same material is on the
website's Advanced setup page (`docs/advanced.html`).

### How it works

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

The app runs an [MCP](https://modelcontextprotocol.io) server. It reads
`~/Library/Messages/chat.db` with SQLite and sends through AppleScript. Full Disk Access is
granted to this app only, so agents only see what the app hands them.

To have an agent do the whole install, point it at [AGENT_SETUP.md](AGENT_SETUP.md).

### Pairing by hand

```bash
imessage-bridge pair --name "Claude Code" --read            # read only
imessage-bridge pair --name "Grok Bot" --read --send        # read and send
```

The command waits while an approval window on the Mac shows a 6-digit code. Check the
code, adjust permissions if you like, and approve. The agent gets a random token; the app
stores only its SHA-256 hash. When pairing finishes, the command prints setup snippets.

### Connecting MCP clients

Each agent's page in the app has buttons to copy its setup, and
`imessage-bridge config --agent <name>` prints it any time.

- **Claude Code:**

  ```bash
  claude mcp add imessage --scope user -- ~/.local/bin/imessage-bridge mcp --agent claude-code
  ```

- **Claude Desktop, Cursor and other local MCP clients:** add a stdio MCP server with
  command `~/.local/bin/imessage-bridge` and args `["mcp", "--agent", "<name>"]`.

- **Grok Bot:** adds its own custom connector right after pairing, using the JSON from
  `imessage-bridge connector --agent grok-bot --grok`, so there's nothing to paste. If it
  didn't, click *Copy Grok Bot Connector* on the agent's page, then in Grok Bot choose
  *Add a custom connector* and paste. Don't use a command-style (stdio) connector: Grok
  runs those on xAI's servers, which can't reach your Mac. If the connector shows an
  error, delete it. Grok Bot can still use the bridge by running one-line commands you
  approve:

  ```sh
  imessage-bridge call --agent grok-bot review_messages days=2
  ```

### Agent permissions

Each agent's page sets: read, send, ask before every send (a native dialog with the full
message, Don't Send as the default), hide verification codes/card/SSN numbers, network access,
and all conversations or only selected ones. With "only selected conversations", every
tool, including contact lookup and sending, is limited to those chats. Sends are capped at
30 per hour per agent. The Activity page lists every tool call by agent; message text is
never logged.

### MCP tools

| Tool | Permission | What it does |
|---|---|---|
| `review_messages` | read | Triage recent threads into needs reply / low priority / automated |
| `list_chats` | read | Recent conversations with participants and contact names |
| `get_conversation` | read | One conversation by name, phone, email, group name or chat ID |
| `search_messages` | read | Text search, optionally within one conversation |
| `response_stats` | read | Your reply times in a conversation |
| `lookup_contact` | read | Phone numbers and emails for a contact |
| `send_message` | send | Send to one phone number or email (not groups) |

Agents only see the tools they're allowed to use.

### Safety settings

The **Safety** page has two independent layers against prompt injection:

- **Allowed recipients** (on by default). Sending to anyone not on the list always shows the
  confirmation dialog, even for agents allowed to send without asking. The dialog has an
  "Always allow sending to…" checkbox, and an optional toggle allows everyone in your
  contacts. This is deterministic: no message wording can get past it.
- **Prompt injection detection** (needs a [TypeSafe](https://typesafe.ai) or
  [OpenRouter](https://openrouter.ai) API key, stored in the Keychain). Incoming messages
  are checked with TypeSafe's Jev model before an agent sees them. By default only senders
  not in your contacts are checked. A flagged message is hidden from the agent (or shown
  with a warning), and that agent must get your confirmation for every send over the next
  30 minutes. Local checks run first and catch blatant cases and hidden Unicode "tag" text
  for free. Sensitivity and model are adjustable, and with OpenRouter you can require
  providers that don't store or train on messages.

The Jev prompt (`Sources/BridgeCore/JevPrompt.swift`) is designed around Datadog Security
Labs' finding that a counterfeit policy embedded in the message can flip Jev's verdict.
Definitions live only in trusted instructions, any attempt to label or redefine the check
counts as evidence of an attack, and a separate question looks only for such attempts.
Detection still can't be perfect; treat it as an alarm and rely on the recipient list.

### Network access

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

### CLI

```
imessage-bridge pair --name <agent> [--read] [--send] [--url URL --fingerprint FP]
imessage-bridge mcp --agent <agent>          # stdio MCP server for clients
imessage-bridge call --agent <agent> [tool key=value …]   # one tool call, no MCP client needed
imessage-bridge config --agent <agent>       # print client setup snippets
imessage-bridge connector --agent <agent> --grok   # Grok Bot custom connector JSON
imessage-bridge status [--agent <agent>]
imessage-bridge agents | forget --agent <agent>
```

### Building from source

You need the Xcode Command Line Tools (`xcode-select --install`); Xcode itself isn't
needed.

```bash
git clone https://github.com/cmer/imessage-bridge.git
cd imessage-bridge
./scripts/install.sh
```

`install.sh` builds and signs the app, installs it to `/Applications/iMessage Bridge.app`,
links the CLI at `~/.local/bin/imessage-bridge` and opens the app.

### Signing

`scripts/build.sh` signs with the first *Developer ID Application* identity in your
keychain, or `$SIGN_IDENTITY` if set, and falls back to ad hoc signing. With a stable
Developer ID, the Full Disk Access grant survives rebuilds. With ad hoc signing, you have
to grant it again after every rebuild.

### Files, updating, uninstalling

Credentials are stored in `~/.config/imessage-bridge/agents/<agent>.json` (mode 600).
App settings and agents are stored in `~/Library/Application Support/iMessage Bridge/`.
API keys are stored in the Keychain.

To update, download the latest release and replace the app, or run
`brew upgrade --cask imessage-bridge`. From source, run `git pull && ./scripts/install.sh`.

To uninstall, quit the app from the menu bar and delete `/Applications/iMessage Bridge.app`
(or run `brew uninstall --cask imessage-bridge`), then `~/.config/imessage-bridge`,
`~/Library/Application Support/iMessage Bridge` and, if you built from source,
`~/.local/bin/imessage-bridge`.

### Security notes

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
(CLI), `docs/` (website).

## Credits

Message-body decoding, redaction and triage rules are adapted from
[grokbot-imessage-skill](https://github.com/jeffhuber/grokbot-imessage-skill) by Jeff Huber
(MIT). See [LICENSE](LICENSE).
