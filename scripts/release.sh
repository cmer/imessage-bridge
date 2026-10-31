#!/bin/bash
# Build, sign, notarize and publish a versioned GitHub release.
#
#   scripts/release.sh 0.2.0            # release v0.2.0
#   scripts/release.sh 0.2.0 --draft    # create the GitHub release as a draft
#
# What it does:
#   1. Checks: on main, clean tree, in sync with origin, tag is new, gh is
#      logged in, a Developer ID identity and notary credentials exist.
#   2. Sets CFBundleShortVersionString to the version and bumps CFBundleVersion.
#   3. Runs the tests, builds and signs the app (scripts/build.sh).
#   4. Notarizes it with Apple and staples the ticket, so it opens without
#      Gatekeeper warnings after downloading.
#   5. Commits the version bump, creates an annotated tag vX.Y.Z, pushes both.
#   6. Creates the GitHub release with the zipped app and its SHA-256.
#
# One-time setup for notarization (an app-specific password from
# appleid.apple.com, stored in your keychain):
#   xcrun notarytool store-credentials imessage-bridge \
#       --apple-id you@example.com --team-id PMQU892978
# Use another profile name with NOTARY_PROFILE=name.
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
BRANCH=main

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# ---- arguments
VERSION=""
DRAFT=()
for a in "$@"; do
    case "$a" in
        --draft) DRAFT=(--draft) ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $a" ;;
        *) [[ -z "$VERSION" ]] || die "only one version, please"; VERSION="${a#v}" ;;
    esac
done
[[ -n "$VERSION" ]] || die "usage: scripts/release.sh <version> [--draft]   (e.g. 0.2.0)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "version must look like 1.2.3 or 1.2.3-beta.1"
TAG="v$VERSION"
PRERELEASE=()
[[ "$VERSION" == *-* ]] && PRERELEASE=(--prerelease)

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
ZIP="$DIST/iMessage-Bridge-$VERSION.zip"
rm -rf "$DIST"; mkdir -p "$DIST"

step "Notarizing (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

step "Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
SHA="$(cut -d' ' -f1 "$ZIP.sha256")"
echo "    $ZIP"
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
    echo "1. Download **$(basename "$ZIP")** below and unzip it."
    echo "2. Move **iMessage Bridge.app** to **/Applications** and open it."
    echo "3. Follow the Setup page: grant Full Disk Access, then pair an agent."
    echo
    echo "To use the command-line tool from agents, link it once:"
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

gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
    --repo "$REPO" --title "iMessage Bridge $VERSION" --notes-file "$NOTES" \
    --verify-tag "${DRAFT[@]}" "${PRERELEASE[@]}"

step "Released $TAG"
gh release view "$TAG" --repo "$REPO" --json url -q .url
