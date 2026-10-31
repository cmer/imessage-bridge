#!/bin/bash
# Build, install to /Applications, link the CLI into ~/.local/bin, and launch.
# Safe to re-run: replaces the app but keeps your agents and settings
# (stored in ~/Library/Application Support/iMessage Bridge).
set -euo pipefail

if [[ "$EUID" -eq 0 ]]; then
    echo "Run as your normal user, not with sudo." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="iMessage Bridge"
DEST_DIR="${INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/$APP_NAME.app"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

"$ROOT/scripts/build.sh"

if pgrep -xq "$APP_NAME"; then
    echo "==> Quitting the running app"
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || pkill -x "$APP_NAME" || true
    for _ in {1..20}; do pgrep -xq "$APP_NAME" || break; sleep 0.25; done
fi

echo "==> Installing to $DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$ROOT/build/$APP_NAME.app" "$DEST"

mkdir -p "$BIN_DIR"
ln -sf "$DEST/Contents/MacOS/imessage-bridge" "$BIN_DIR/imessage-bridge"
echo "==> CLI linked at $BIN_DIR/imessage-bridge"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "    (note: $BIN_DIR is not on your PATH)";;
esac

echo "==> Launching"
open "$DEST"

cat <<EOF

Installed. Remaining one-time steps, done by you in System Settings
(macOS doesn't let any script grant these):

  1. Full Disk Access: the app's Setup page has a button that opens the right
     pane. Turn on "$APP_NAME" (or add it with + from $DEST_DIR).
  2. Sending only: click "Request Permission" next to "Control Messages".

Then pair an agent:
  imessage-bridge pair --name "Claude" --read
EOF
