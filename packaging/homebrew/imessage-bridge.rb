# Template for the cask in cmer/homebrew-tap. scripts/release.sh fills in the
# version and checksum and publishes it; edit this file, not the tap's copy.
cask "imessage-bridge" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/cmer/imessage-bridge/releases/download/v#{version}/iMessage-Bridge-#{version}.dmg"
  name "iMessage Bridge"
  desc "Menu bar app that gives AI agents controlled access to iMessage"
  homepage "https://github.com/cmer/imessage-bridge"

  auto_updates true
  depends_on arch:  :arm64
  depends_on macos: :sonoma

  app "iMessage Bridge.app"
  binary "#{appdir}/iMessage Bridge.app/Contents/MacOS/imessage-bridge"

  uninstall quit: "org.bloomworks.imessage-bridge"

  zap trash: [
    "~/.config/imessage-bridge",
    "~/Library/Application Support/iMessage Bridge",
    "~/Library/Preferences/org.bloomworks.imessage-bridge.plist",
  ]
end
