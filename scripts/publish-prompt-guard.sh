#!/bin/bash
# Publish the on-device model built by scripts/build-prompt-guard.sh as a
# GitHub release, and point the app at it.
#
#   scripts/publish-prompt-guard.sh 1      # creates release prompt-guard-v1
#
# The release is not marked "latest", so app releases stay the latest. The
# script then rewrites Sources/BridgeCore/PromptGuardAsset.swift with the
# download URL, size and SHA-256; commit that, and the next app release
# offers this model. Apps that have an older model see "Update".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NAME=Llama-Prompt-Guard-2-86M
ZIP="build/prompt-guard/$NAME-coreml.zip"
ASSET_SWIFT=Sources/BridgeCore/PromptGuardAsset.swift

die() { echo "error: $*" >&2; exit 1; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+$ ]] || die "usage: scripts/publish-prompt-guard.sh <version number>, e.g. 1"
TAG="prompt-guard-v$VERSION"

[[ -f "$ZIP" && -f "$ZIP.sha256" ]] || die "$ZIP not found; run scripts/build-prompt-guard.sh first"
SHA="$(cat "$ZIP.sha256")"
[[ "$SHA" == "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" ]] || die "$ZIP doesn't match its .sha256; rebuild it"
SIZE="$(stat -f %z "$ZIP")"

command -v gh >/dev/null || die "GitHub CLI not found (brew install gh)"
gh auth status >/dev/null 2>&1 || die "GitHub CLI isn't logged in; run: gh auth login"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && die "release $TAG already exists on $REPO"

REVISION="$(unzip -p "$ZIP" manifest.json | python3 -c 'import json, sys; print(json.load(sys.stdin)["revision"])')"
NOTES="$(mktemp)"
cat > "$NOTES" <<TXT
[Llama Prompt Guard 2 (86M)](https://huggingface.co/meta-llama/Llama-Prompt-Guard-2-86M) by Meta, converted to Core ML for iMessage Bridge's on-device prompt-injection check. The app downloads this file itself; you don't need to.

- Source revision: \`$REVISION\`
- SHA-256: \`$SHA\`

Built with Llama. Llama 4 is licensed under the Llama 4 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved. The license, notice and Meta's Acceptable Use Policy are inside the zip.
TXT

echo "==> Creating release $TAG on $REPO"
gh release create "$TAG" "$ZIP" --repo "$REPO" --latest=false \
    --title "On-device model: Llama Prompt Guard 2 86M (Core ML) v$VERSION" --notes-file "$NOTES"
rm -f "$NOTES"

URL="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")"
echo "==> Checking the download"
[[ "$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)" == "$SHA" ]] || die "downloaded file doesn't match; check the release"

cat > "$ASSET_SWIFT" <<SWIFT
import Foundation

/// The on-device model the app downloads, as published on GitHub by
/// scripts/publish-prompt-guard.sh, which rewrites this file. The app only
/// installs a download whose SHA-256 matches.
public enum PromptGuardAsset {
    public static let version = "$VERSION"
    public static let url = URL(string: "$URL")!
    public static let sha256 = "$SHA"
    public static let byteCount: Int64 = $SIZE

    /// False until a model has been published.
    public static var isPublished: Bool { !sha256.isEmpty }
}
SWIFT

echo "==> Published $URL"
echo "    Updated $ASSET_SWIFT; commit it so the next app release uses this model."
