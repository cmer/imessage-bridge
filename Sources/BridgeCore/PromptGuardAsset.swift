import Foundation

/// The on-device model the app downloads, as published on GitHub by
/// scripts/publish-prompt-guard.sh, which rewrites this file. The app only
/// installs a download whose SHA-256 matches.
public enum PromptGuardAsset {
    public static let version = "1"
    public static let url = URL(string: "https://github.com/cmer/imessage-bridge/releases/download/prompt-guard-v1/Llama-Prompt-Guard-2-86M-coreml.zip")!
    public static let sha256 = "499877b45830d3cc492fdcd95ed6a3b287d40a4ba5ed65d3f6a872684ab82578"
    public static let byteCount: Int64 = 260491445

    /// False until a model has been published.
    public static var isPublished: Bool { !sha256.isEmpty }
}
