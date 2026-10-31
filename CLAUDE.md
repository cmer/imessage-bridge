# iMessage Bridge

## Changelog

`CHANGELOG.md` lists what changed in each release, written for people who use the app.
Keep it current as you work:

- When a change affects users (a feature, a fix, changed behavior or wording they'd
  notice, a new requirement), add a line under `## Unreleased` in the same commit.
  Group lines under `### Added`, `### Changed`, `### Fixed` or `### Removed`, in that
  order, creating the heading if it's missing.
- One line per change, in plain language, saying what the user sees, not how the code
  does it. "The send dialog can turn off Ask me before every send", not "Add stopAsking to
  Confirmation".
- Skip changes users can't see: refactors, tests, build scripts, docs-only edits.
- If a later change revises something already under Unreleased, edit that line instead
  of adding another.
- Never edit a released version's section, except to fix a mistake in it.

Releasing (`scripts/release.sh`, see `.claude/skills/release/SKILL.md`) stops if
Unreleased is empty. Otherwise it renames the section to `## X.Y.Z - YYYY-MM-DD`, starts
a new empty `## Unreleased` above it, commits it with the version bump, and uses the
section as the GitHub release notes. Don't make those edits by hand.

## Build and test

- `scripts/install.sh` builds, signs, installs to /Applications and relaunches the app.
- Only the Command Line Tools are installed (no Xcode), so tests need the
  swift-testing plugin path:
  `swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
- SwiftUI's `@State` macro isn't available with the Command Line Tools; keep view state
  in an `ObservableObject` (`@StateObject`, `@Published`). UI conventions are in
  `.interface-design/system.md`.
- After visual changes, regenerate the website screenshots with
  `"$(swift build -c release --show-bin-path)/IMessageBridgeApp" --screenshots <dir>` and
  copy the ones that changed into `docs/images`.
