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
#   2. Sets CFBundleShortVersionString to the version and bumps CFBundleVersion.
#   3. Runs the tests, builds and signs the app (scripts/build.sh).
#   4. Notarizes the app and staples the ticket, then packs it into a DMG
#      (with an Applications shortcut), signs, notarizes and staples that too,
#      so it opens without Gatekeeper warnings after downloading.
#   5. Commits the version bump, creates an annotated tag vX.Y.Z, pushes both.
#   6. Creates the GitHub release with the DMG and its SHA-256.
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
# Nothing is committed, tagged or pushed until the build and notarization
# succeed; on failure, the version change to Info.plist is undone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLIST=Resources/Info.plist
APP_NAME="iMessage Bridge"
APP="$ROOT/build/$APP_NAME.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-imessage-bridge}"
REMOTE="${REMOTE:-origin}"
TAP="${TAP:-cmer/homebrew-tap}"
CASK_TEMPLATE="$ROOT/packaging/homebrew/imessage-bridge.rb"
BRANCH=main

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

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
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity found; releases must be properly signed"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notary credentials named \"$NOTARY_PROFILE\"; see the setup notes at the top of this script"

[[ "$(gh api "repos/$TAP" --jq .permissions.push 2>/dev/null)" == "true" ]] \
    || die "can't push to the Homebrew tap $TAP (set TAP=owner/repo to use another)"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD=$((OLD_BUILD + 1))
echo "    $REPO: $OLD_VERSION ($OLD_BUILD) -> $VERSION ($BUILD)"
echo "    Signing as: $IDENTITY"

# ---- version bump (undone on failure until committed)
COMMITTED=0
restore() { [[ $COMMITTED == 1 ]] || git checkout --quiet -- "$PLIST"; }
trap restore EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

# ---- test and build
step "Running tests"
swift test

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

# ---- commit, tag, push
step "Tagging $TAG"
git add "$PLIST"
git commit --quiet -m "Release $TAG"
COMMITTED=1
git tag -a "$TAG" -m "iMessage Bridge $VERSION"
git push --quiet "$REMOTE" "$BRANCH" "$TAG"

# ---- GitHub release
step "Creating GitHub release"
PREV_TAG="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
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
    if [[ -n "$PREV_TAG" ]]; then
        git log --no-merges --pretty='- %s' "$PREV_TAG..$TAG^" | grep -v '^- Release v' || true
    else
        git log --no-merges --pretty='- %s' "$TAG^" | grep -v '^- Release v' || true
    fi
} > "$NOTES"

gh release create "$TAG" "$DMG" "$DMG.sha256" \
    --repo "$REPO" --title "iMessage Bridge $VERSION" --notes-file "$NOTES" \
    --verify-tag ${DRAFT[@]+"${DRAFT[@]}"} ${PRERELEASE[@]+"${PRERELEASE[@]}"}

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
