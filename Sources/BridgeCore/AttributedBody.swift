import Foundation

/// Decodes the `attributedBody` column of chat.db.
///
/// Newer macOS versions often leave `message.text` empty and store the body
/// as a typedstream-archived NSAttributedString. This is a byte-level port of
/// the decoder in jeffhuber/grokbot-imessage-skill (MIT), which pulls the
/// NSString payloads out without needing the Objective-C unarchiver.
public enum AttributedBody {
    private static let skipBytes: Set<UInt8> = [0x84, 0x94, 0x85, 0x95, 0x01, 0x86]
    private static let nsString = Array("NSString".utf8)
    private static let nsObject = Array("NSObject".utf8)
    private static let streamTyped = Array("streamtyped".utf8)

    public static func decode(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let bytes = [UInt8](data)
        guard find(streamTyped, in: Array(bytes.prefix(16)), from: 0) != nil else { return "" }

        var candidates: [String] = []
        var expectedNext: Int?
        var searchFrom = 0
        while let idx = find(nsString, in: bytes, from: searchFrom) {
            if let (text, end) = string(at: idx, in: bytes) {
                if let expectedNext, idx > expectedNext { break }
                if !text.isEmpty { candidates.append(text) }
                expectedNext = end
                searchFrom = max(idx + 1, end)
            } else {
                searchFrom = idx + nsString.count
            }
        }
        return candidates.joined()
    }

    static func string(at idx: Int, in b: [UInt8]) -> (String, Int)? {
        let n = b.count
        var p = idx + nsString.count + 1
        while p < n, skipBytes.contains(b[p]) { p += 1 }
        if p + 8 <= n, Array(b[p..<p + 8]) == nsObject {
            p += 8
            while p < n, skipBytes.contains(b[p]) { p += 1 }
        }
        if p < n, b[p] == 0x2B { p += 1 }
        guard p < n else { return nil }

        var length: Int
        var b0 = b[p]
        if b0 == 0x81 {
            guard p + 3 <= n else { return nil }
            length = Int(b[p + 1]) | Int(b[p + 2]) << 8
            p += 3
        } else if b0 == 0x82 {
            guard p + 5 <= n else { return nil }
            length = Int(b[p + 1]) | Int(b[p + 2]) << 8 | Int(b[p + 3]) << 16 | Int(b[p + 4]) << 24
            p += 5
        } else if b0 < 0x80 {
            length = Int(b0)
            p += 1
        } else {
            p += 1
            guard p < n else { return nil }
            b0 = b[p]
            if b0 == 0x81 {
                guard p + 3 <= n else { return nil }
                length = Int(b[p + 1]) | Int(b[p + 2]) << 8
                p += 3
            } else if b0 < 0x80 {
                length = Int(b0)
                p += 1
            } else {
                return nil
            }
        }
        guard length > 0, p + length <= n else { return nil }
        guard let s = String(bytes: b[p..<p + length], encoding: .utf8) else { return nil }
        return (s, p + length)
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, start <= hay.count - needle.count else { return nil }
        var i = start
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where hay[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}
