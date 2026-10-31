import CryptoKit
import Foundation
import Security

public enum Tokens {
    public static func random(bytes: Int = 32) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        precondition(rc == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(buf).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func newAgentToken() -> String { "imb_" + random(bytes: 32) }

    /// Six digits, shown in both the CLI and the approval window.
    public static func pairingCode() -> String {
        var n: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &n) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return String(format: "%06u", n % 1_000_000)
    }

    public static func sha256Hex(_ s: String) -> String {
        sha256Hex(Data(s.utf8))
    }

    public static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// "AB:CD:…" form used for certificate fingerprints.
    public static func fingerprint(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public static func normalizeFingerprint(_ s: String) -> String {
        s.uppercased().filter { $0.isHexDigit }
    }
}
