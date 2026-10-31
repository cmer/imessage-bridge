import Foundation

/// The on-device model the app downloads, as published on GitHub by
/// scripts/publish-prompt-guard.sh, which rewrites this file. The app only
/// installs a download whose SHA-256 matches.
public enum PromptGuardAsset {
    public static let version = ""
    public static let url = URL(string: "https://github.com/cmer/imessage-bridge/releases/download/prompt-guard-v0/Llama-Prompt-Guard-2-86M-coreml.zip")!
    public static let sha256 = ""
    public static let byteCount: Int64 = 0

    /// False until a model has been published.
    public static var isPublished: Bool { !sha256.isEmpty }
}
