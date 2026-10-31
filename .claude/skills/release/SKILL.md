---
name: release
description: Cut a tagged, signed, notarized GitHub release of iMessage Bridge with scripts/release.sh. Use when the user asks to release, ship, tag or publish a version (e.g. "release 0.2.0", "cut a patch release", "/release minor").
---

# Release iMessage Bridge

`scripts/release.sh <version> [--draft]` does the work: it bumps the version in
`Resources/Info.plist`, runs the tests, builds and signs with Developer ID,
notarizes and staples the app, packs it into a notarized DMG, commits "Release
vX.Y.Z", tags, pushes, creates the GitHub release with the DMG and its SHA-256,
and publishes the Homebrew cask to `cmer/homebrew-tap` (from
`packaging/homebrew/imessage-bridge.rb`). Your job is to pick the
version, get the repo ready, run it, and report.

## 1. Pick the version

- Current version: `git describe --tags --abbrev=0` (no tags yet means the first
  release; use the `CFBundleShortVersionString` in `Resources/Info.plist`, 0.1.0).
- If the user named a version, use it. If they said `major`, `minor` or `patch`,
  bump the latest tag accordingly. If they said nothing, read
  `git log <last tag>..HEAD --oneline` and propose patch for fixes only, minor
  for new features, then confirm with the user before going on.
- A suffix like `0.3.0-beta.1` becomes a GitHub prerelease.

## 2. Get the repo ready

The script refuses to run unless all of these hold. Check them first and fix
what you can:

- On `main`, in sync with `origin/main`.
- Clean working tree. If there are uncommitted changes, show the user
  `git status --short` and ask whether to commit them as part of the release.
  Don't commit or push without that yes.
- `gh auth status` succeeds. If not, ask the user to run `! gh auth login`.
- `gh` can push to `cmer/homebrew-tap` (the script checks this too).
- Notary credentials exist: `xcrun notarytool history --keychain-profile imessage-bridge`.
  If not, ask the user to run
  `! xcrun notarytool store-credentials imessage-bridge --apple-id <Apple ID> --team-id PMQU892978`
  (needs an app-specific password from appleid.apple.com).
- The Sparkle update-signing key is in the keychain and matches Info.plist
  (the script checks this too): `build/sparkle-tools/bin/generate_keys -p --account imessage-bridge`
  should print the `SUPublicEDKey` from `Resources/Info.plist` (the tools download on the
  script's first run). If it's missing on this Mac, ask the user to import their backup:
  `! build/sparkle-tools/bin/generate_keys --account imessage-bridge -f <backup file>`.
  Never generate a new key: installed apps would reject every update signed with it.

## 3. Run it

Releasing publishes a public download and pushes a tag, so confirm the exact
version with the user first (once is enough, including when they named it).

```sh
scripts/release.sh <version>            # add --draft to review on GitHub first
```

Run it in the background with a long timeout: it notarizes twice (app, then
DMG), usually a few minutes each. Don't pass `--force`-style workarounds or skip notarization.

## 4. Afterwards

- Report the release URL the script prints, the version and the SHA-256.
- Check the update feed: `curl -sL https://github.com/cmer/imessage-bridge/releases/latest/download/appcast.xml`
  should show the new version (drafts and prereleases don't move it).
- A `--draft` or prerelease doesn't update the cask. Once the user publishes the
  draft on GitHub, run `scripts/release.sh --cask-only <version>`.
- Reinstall locally so /Applications matches the release: `scripts/install.sh`.
- If the script failed before "Tagging", nothing was committed or pushed and
  Info.plist was restored; fix the cause and run it again. If it failed after
  the push (at "Creating GitHub release"), the tag already exists on GitHub:
  finish with `gh release create v<version> build/dist/*.dmg build/dist/*.sha256
  --verify-tag --title "iMessage Bridge <version>" --notes-file build/dist/notes.md`
  instead of rerunning the script, then `scripts/release.sh --cask-only <version>`.
  If only the cask step failed, run `scripts/release.sh --cask-only <version>`.
