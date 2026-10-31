# Changelog

What changed in each release of iMessage Bridge, for the people who use it.
`scripts/release.sh` turns the Unreleased section into the new version's section
and uses it as the GitHub release notes.

## Unreleased

## 0.9.2 - 2026-10-31

### Changed
- The update window lists what changed in the new version, instead of showing a cramped
  GitHub page.

### Fixed
- A phone number in another country no longer passes for an allowed recipient, a contact
  or one of an agent's selected chats just because its last 10 digits match (for example
  +33 6 12 34 56 78 and +1 361-234-5678).
- Contacts saved without a country code are now read using your Mac's region, so local
  numbers like 06 12 34 56 78 in France show the contact's name.

## 0.9.1 - 2026-10-31

### Changed
- "Connect an agent" now comes right after macOS permissions on the Setup page.

## 0.9.0 - 2026-10-31

First release.

### Added
- Menu bar app and `imessage-bridge` CLI that give AI agents (Claude Code, Grok Bot and
  other MCP clients) controlled access to iMessage: read, search and send, with pairing
  you approve on the Mac.
- Per-agent permissions: read, send, ask before every send, hide verification codes and
  card numbers, network access, and access to all conversations or only selected ones.
- Recipient list: sending to anyone not on it always asks first, for every agent.
- Prompt-injection screening before an agent reads a message, in up to three layers:
  built-in patterns, Llama Prompt Guard 2 running on this Mac (a one-time download), and
  Jev (TypeSafe's model, with your API key). An agent that reads a flagged message needs
  your OK for every send for the next 30 minutes.
- "Don't ask again" in the send confirmation dialog turns off an agent's
  ask-before-every-send setting.
- Automatic updates: the app checks GitHub daily and installs new versions once the
  bridge has been idle for 10 minutes.
- Signed, notarized DMG and a Homebrew cask (`brew install --cask cmer/tap/imessage-bridge`).
