#!/bin/bash
# Build, sign, notarize and publish a versioned GitHub release.
#
#   scripts/release.sh 0.2.0            # release v0.2.0
#   scripts/release.sh 0.2.0 --draft    # create the GitHub release as a draft
#   scripts/release.sh --cask-only 0.2.0  # only (re)publish the Homebrew cask
#                                         # for an existing, published release
#
# What it does:
#   1. Checks: on main, clean tree, in sync with origin, tag is new, gh is
#      logged in, a Developer ID identity and notary credentials exist.
#   2. Sets CFBundleShortVersionString to the version and bumps CFBundleVersion,
#      and turns CHANGELOG.md's "Unreleased" section into "X.Y.Z - date".
#   3. Runs the tests, builds and signs the app (scripts/build.sh).
#   4. Notarizes the app and staples the ticket, then packs it into a DMG
#      (with an Applications shortcut), signs, notarizes and staples that too,
#      so it opens without Gatekeeper warnings after downloading.
#   5. Commits the version bump and changelog, creates an annotated tag vX.Y.Z, pushes both.
#   6. Signs the DMG for Sparkle and writes appcast.xml, then creates the
#      GitHub release with the DMG, its SHA-256 and the appcast. The release
#      notes, on GitHub and in the app's update window, are the version's
#      CHANGELOG.md section. Installed
#      apps read the appcast from the latest release to update themselves.
#   7. Publishes the Homebrew cask (packaging/homebrew/imessage-bridge.rb) to
#      the tap with the new version and checksum.
#
# One-time setup for notarization (an app-specific password from
# appleid.apple.com, stored in your keychain):
#   xcrun notarytool store-credentials imessage-bridge \
#       --apple-id you@example.com --team-id PMQU892978
# Use another profile name with NOTARY_PROFILE=name. The tap defaults to
# cmer/homebrew-tap; override with TAP=owner/repo.
#
# Sparkle update signing: the EdDSA private key lives in your login keychain
# (account "imessage-bridge"); its public key is SUPublicEDKey in Info.plist.
# Create it once on a new Mac by importing your backup:
#   build/sparkle-tools/bin/generate_keys --account imessage-bridge -f <backup file>
# (the tools are downloaded on first use). Without that key no app already
# installed will accept an update.
#
# Nothing is committed, tagged or pushed until the build and notarization
# succeed; on failure, the version change to Info.plist is undone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLIST=Resources/Info.plist
CHANGELOG=CHANGELOG.md
APP_NAME="iMessage Bridge"
APP="$ROOT/build/$APP_NAME.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-imessage-bridge}"
REMOTE="${REMOTE:-origin}"
TAP="${TAP:-cmer/homebrew-tap}"
CASK_TEMPLATE="$ROOT/packaging/homebrew/imessage-bridge.rb"
BRANCH=main
SPARKLE_VERSION=2.10.1      # keep in step with Package.swift
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SPARKLE_ACCOUNT=imessage-bridge
SPARKLE_TOOLS="$ROOT/build/sparkle-tools"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Sparkle's command-line tools (generate_keys, sign_update), from the release
# matching the framework the app embeds, checked against a pinned SHA-256.
sparkle_tool() {
    local tool="$1"; shift
    if [[ ! -x "$SPARKLE_TOOLS/bin/$tool" ]]; then
        local tmp
        tmp="$(mktemp -d)"
        curl -fsSL -o "$tmp/sparkle.tar.xz" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
        [[ "$(shasum -a 256 "$tmp/sparkle.tar.xz" | cut -d' ' -f1)" == "$SPARKLE_SHA256" ]] \
            || die "the Sparkle $SPARKLE_VERSION download doesn't match its pinned checksum"
        rm -rf "$SPARKLE_TOOLS"; mkdir -p "$SPARKLE_TOOLS"
        tar -xf "$tmp/sparkle.tar.xz" -C "$SPARKLE_TOOLS" bin
        rm -rf "$tmp"
    fi
    "$SPARKLE_TOOLS/bin/$tool" "$@"
}

# Write the cask for <version> <sha256> into the tap and push it.
publish_cask() {
    local version="$1" sha="$2" tmp cask readme
    step "Publishing the Homebrew cask to $TAP"
    tmp="$(mktemp -d)"
    gh repo clone "$TAP" "$tmp" -- --quiet --depth 1
    cask="$tmp/Casks/imessage-bridge.rb"
    readme="$tmp/README.md"
    mkdir -p "$tmp/Casks"
    # Drop the template's header comment (everything before the cask line).
    sed -e '/^cask /,$!d' -e "s/__VERSION__/$version/" -e "s/__SHA256__/$sha/" \
        "$CASK_TEMPLATE" > "$cask"
    if [[ -f "$readme" ]] && ! grep -q 'Casks/imessage-bridge.rb' "$readme"; then
        [[ -z "$(tail -c1 "$readme")" ]] || echo >> "$readme"
        echo '| [imessage-bridge](Casks/imessage-bridge.rb) | Gives AI agents controlled access to iMessage |' >> "$readme"
    fi
    git -C "$tmp" add -A
    if git -C "$tmp" diff --cached --quiet; then
        echo "    already up to date"
    else
        git -C "$tmp" commit --quiet -m "imessage-bridge $version"
        git -C "$tmp" push --quiet
        echo "    brew install --cask ${TAP%%/homebrew-*}/${TAP##*/homebrew-}/imessage-bridge"
    fi
    rm -rf "$tmp"
}

# ---- arguments
VERSION=""
DRAFT=()
CASK_ONLY=0
for a in "$@"; do
    case "$a" in
        --draft) DRAFT=(--draft) ;;
        --cask-only) CASK_ONLY=1 ;;
        -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $a" ;;
        *) [[ -z "$VERSION" ]] || die "only one version, please"; VERSION="${a#v}" ;;
    esac
done
[[ -n "$VERSION" ]] || die "usage: scripts/release.sh <version> [--draft]   (e.g. 0.2.0)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "version must look like 1.2.3 or 1.2.3-beta.1"
TAG="v$VERSION"
PRERELEASE=()
[[ "$VERSION" == *-* ]] && PRERELEASE=(--prerelease)

# ---- cask only: publish the cask for a release that's already on GitHub
if [[ $CASK_ONLY == 1 ]]; then
    command -v gh >/dev/null || die "GitHub CLI not found (brew install gh)"
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    [[ "$(gh release view "$TAG" --repo "$REPO" --json isDraft -q .isDraft 2>/dev/null)" == "false" ]] \
        || die "$TAG isn't a published release on $REPO (publish the draft first)"
    SHA="$(gh release download "$TAG" --repo "$REPO" --pattern '*.dmg.sha256' --output - | cut -d' ' -f1)"
    [[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "couldn't read the DMG checksum from $TAG"
    publish_cask "$VERSION" "$SHA"
    exit 0
fi

# ---- preflight
step "Checking"
command -v gh >/dev/null || die "GitHub CLI not found (brew install gh)"
gh auth status >/dev/null 2>&1 || die "GitHub CLI isn't logged in; run: gh auth login"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "switch to $BRANCH first"
[[ -z "$(git status --porcelain)" ]] || die "working tree isn't clean; commit or stash first"
git fetch --quiet --tags "$REMOTE"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$REMOTE/$BRANCH")" ]] \
    || die "$BRANCH isn't in sync with $REMOTE/$BRANCH; pull or push first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"

# The body of a CHANGELOG.md section ("Unreleased" or a version), blank lines trimmed.
changelog_section() {
    awk -v h="## $1" '
        index($0, h) == 1 && (length($0) == length(h) || substr($0, length(h) + 1, 1) == " ") { on = 1; next }
        on && /^## / { exit }
        on { print }
    ' "$CHANGELOG" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}
[[ -f "$CHANGELOG" ]] && grep -q '^## Unreleased$' "$CHANGELOG" || die "$CHANGELOG needs an \"## Unreleased\" section"
[[ -n "$(changelog_section Unreleased | tr -d '[:space:]')" ]] \
    || die "nothing under \"## Unreleased\" in $CHANGELOG; add this release's changes first"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity found; releases must be properly signed"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notary credentials named \"$NOTARY_PROFILE\"; see the setup notes at the top of this script"

[[ "$(gh api "repos/$TAP" --jq .permissions.push 2>/dev/null)" == "true" ]] \
    || die "can't push to the Homebrew tap $TAP (set TAP=owner/repo to use another)"

SPARKLE_KEY="$(sparkle_tool generate_keys -p --account "$SPARKLE_ACCOUNT" 2>/dev/null || true)"
[[ -n "$SPARKLE_KEY" ]] || die "no Sparkle signing key in your keychain (account $SPARKLE_ACCOUNT); see the setup notes at the top of this script"
[[ "$SPARKLE_KEY" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" ]] \
    || die "the Sparkle key in your keychain doesn't match SUPublicEDKey in $PLIST"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD=$((OLD_BUILD + 1))
echo "    $REPO: $OLD_VERSION ($OLD_BUILD) -> $VERSION ($BUILD)"
echo "    Signing as: $IDENTITY"

# ---- version bump (undone on failure until committed)
COMMITTED=0
restore() { [[ $COMMITTED == 1 ]] || git checkout --quiet -- "$PLIST" "$CHANGELOG"; }
trap restore EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
# "## Unreleased" stays at the top, empty, above the new version's section.
sed -i '' "s/^## Unreleased\$/## Unreleased\\
\\
## $VERSION - $(date +%Y-%m-%d)/" "$CHANGELOG"

# ---- test and build
step "Running tests"
# With only the Command Line Tools, swift-testing's macros need their plugin path.
TEST_ARGS=()
CLT_PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* && -d "$CLT_PLUGINS" ]]; then
    TEST_ARGS=(-Xswiftc -plugin-path -Xswiftc "$CLT_PLUGINS")
fi
swift test ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}

step "Building"
SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build.sh"

# ---- notarize
DIST="$ROOT/build/dist"
DMG="$DIST/iMessage-Bridge-$VERSION.dmg"
rm -rf "$DIST"; mkdir -p "$DIST"

step "Notarizing the app (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

step "Building the disk image"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

step "Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
SHA="$(cut -d' ' -f1 "$DMG.sha256")"
echo "    $DMG"
echo "    sha256 $SHA"

step "Signing the update for Sparkle"
# Prints: sparkle:edSignature="..." length="..."
ED_ATTRS="$(sparkle_tool sign_update --account "$SPARKLE_ACCOUNT" "$DMG")"
[[ "$ED_ATTRS" == *'sparkle:edSignature="'*'length="'* ]] || die "sign_update failed: $ED_ATTRS"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
# The update window shows this version's CHANGELOG.md section, rendered by Sparkle
# as markdown (Sparkle 2.9+, macOS 12+). A "]]>" in it would end the CDATA early,
# so it's split across two CDATA sections.
APPCAST_NOTES="$(changelog_section "$VERSION" | sed 's/]]>/]]]]><![CDATA[>/g')"
cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>iMessage Bridge</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>iMessage Bridge $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
$APPCAST_NOTES
]]></description>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")" type="application/octet-stream" $ED_ATTRS/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$DIST/appcast.xml"

# ---- commit, tag, push
step "Tagging $TAG"
git add "$PLIST" "$CHANGELOG"
git commit --quiet -m "Release $TAG"
COMMITTED=1
git tag -a "$TAG" -m "iMessage Bridge $VERSION"
git push --quiet "$REMOTE" "$BRANCH" "$TAG"

# ---- GitHub release
step "Creating GitHub release"
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$TAG^" 2>/dev/null || true)"   # app tags only, not prompt-guard-v*
NOTES="$DIST/notes.md"
{
    echo "## Install"
    echo
    echo "With Homebrew:"
    echo
    echo '```sh'
    echo 'brew install --cask cmer/tap/imessage-bridge'
    echo '```'
    echo
    echo "Or download **$(basename "$DMG")** below, open it and drag **iMessage Bridge** to Applications."
    echo "Then open the app and follow its Setup page: grant Full Disk Access, then pair an agent."
    echo
    echo "If you installed from the disk image, link the command-line tool once (Homebrew does this for you):"
    echo
    echo '```sh'
    echo 'mkdir -p ~/.local/bin && ln -sf "/Applications/iMessage Bridge.app/Contents/MacOS/imessage-bridge" ~/.local/bin/imessage-bridge'
    echo '```'
    echo
    echo "Signed with Developer ID and notarized by Apple. SHA-256: \`$SHA\`"
    echo
    echo "## Changes"
    echo
    # Demote the changelog's "### Added" etc. under "## Changes".
    changelog_section "$VERSION" | sed 's/^### /#### /'
    if [[ -n "$PREV_TAG" ]]; then
        echo
        echo "Full list of commits: https://github.com/$REPO/compare/$PREV_TAG...$TAG"
    fi
} > "$NOTES"

# Apps fetch releases/latest/download/appcast.xml, so a final release must be
# "latest" (prompt-guard-v* releases never are); drafts and prereleases aren't.
LATEST=()
[[ ${#DRAFT[@]} -eq 0 && ${#PRERELEASE[@]} -eq 0 ]] && LATEST=(--latest)
gh release create "$TAG" "$DMG" "$DMG.sha256" "$DIST/appcast.xml" \
    --repo "$REPO" --title "iMessage Bridge $VERSION" --notes-file "$NOTES" \
    --verify-tag ${DRAFT[@]+"${DRAFT[@]}"} ${PRERELEASE[@]+"${PRERELEASE[@]}"} ${LATEST[@]+"${LATEST[@]}"}

# ---- Homebrew cask
# Drafts and prereleases aren't public downloads (or shouldn't be the default),
# so the cask only moves for a final release.
if [[ ${#DRAFT[@]} -gt 0 || ${#PRERELEASE[@]} -gt 0 ]]; then
    step "Skipping the Homebrew cask (draft or prerelease)"
    echo "    Publish it later with: scripts/release.sh --cask-only $VERSION"
else
    publish_cask "$VERSION" "$SHA"
fi

step "Released $TAG"
gh release view "$TAG" --repo "$REPO" --json url -q .url
