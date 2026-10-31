import Foundation

/// A SentencePiece Unigram tokenizer read from a Hugging Face `tokenizer.json`,
/// covering what DeBERTa-v3 and mDeBERTa-v3 (and so Llama Prompt Guard 2) use:
/// a sequence of Replace / Unicode / Strip / Precompiled (SentencePiece
/// charsmap) normalizers, a Metaspace pre-tokenizer, and
/// Viterbi segmentation over the vocabulary. It mirrors the `tokenizers`
/// crate closely enough to produce the same ids; the conversion script writes
/// reference ids that the tests compare against.
public final class UnigramTokenizer: @unchecked Sendable {
    enum Normalizer {
        case replace(NSRegularExpression, template: String)
        case nfc, nfd, nfkc, nfkd
        case lowercase
        case strip(left: Bool, right: Bool)
        case precompiled(PrecompiledCharsMap)
    }

    enum PrependScheme: String { case always, first, never }

    let normalizers: [Normalizer]
    let replacement: Character
    let prependScheme: PrependScheme
    let splitWords: Bool
    let pieces: [String: (id: Int32, score: Double)]
    let maxPieceLength: Int
    let unkID: Int32
    let unkScore: Double
    /// Added tokens matched in the raw text before normalization, longest first.
    let specialTokens: [(text: String, id: Int32)]
    /// Added tokens matched in the text after normalization, longest first.
    let normalizedSpecialTokens: [(text: String, id: Int32)]

    public let clsID: Int32
    public let sepID: Int32
    public let padID: Int32

    public enum LoadError: Error, LocalizedError {
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let what): return "tokenizer.json: \(what)"
            }
        }
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any] else {
            throw LoadError.unsupported("not a tokenizer file")
        }
        guard model["type"] as? String == "Unigram", let vocab = model["vocab"] as? [[Any]] else {
            throw LoadError.unsupported("model type \(model["type"] ?? "?") (expected Unigram)")
        }
        if model["byte_fallback"] as? Bool == true { throw LoadError.unsupported("byte_fallback") }

        var pieces: [String: (Int32, Double)] = [:]
        pieces.reserveCapacity(vocab.count)
        var minScore = Double.infinity
        var maxLen = 0
        for (i, entry) in vocab.enumerated() {
            guard entry.count == 2, let piece = entry[0] as? String, let score = (entry[1] as? NSNumber)?.doubleValue else {
                throw LoadError.unsupported("vocab entry \(i)")
            }
            if pieces[piece] == nil { pieces[piece] = (Int32(i), score) }
            minScore = min(minScore, score)
            maxLen = max(maxLen, piece.unicodeScalars.count)
        }
        self.pieces = pieces
        self.maxPieceLength = maxLen
        guard let unk = (model["unk_id"] as? NSNumber)?.int32Value else { throw LoadError.unsupported("no unk_id") }
        self.unkID = unk
        self.unkScore = minScore - 10   // tokenizers' K_UNK_PENALTY

        self.normalizers = try UnigramTokenizer.parseNormalizer(root["normalizer"])

        var metaspace: [String: Any]?
        if let pre = root["pre_tokenizer"] as? [String: Any] {
            let list = pre["type"] as? String == "Sequence" ? (pre["pretokenizers"] as? [[String: Any]] ?? []) : [pre]
            for p in list {
                guard p["type"] as? String == "Metaspace" else {
                    throw LoadError.unsupported("pre-tokenizer \(p["type"] ?? "?")")
                }
                metaspace = p
            }
        }
        guard let ms = metaspace else { throw LoadError.unsupported("no Metaspace pre-tokenizer") }
        self.replacement = (ms["replacement"] as? String)?.first ?? "\u{2581}"
        if let scheme = ms["prepend_scheme"] as? String {
            guard let s = PrependScheme(rawValue: scheme) else { throw LoadError.unsupported("prepend_scheme \(scheme)") }
            self.prependScheme = s
        } else {
            self.prependScheme = (ms["add_prefix_space"] as? Bool ?? true) ? .always : .never
        }
        self.splitWords = ms["split"] as? Bool ?? true

        var specials: [(String, Int32)] = []
        var normalizedSpecials: [(String, Int32)] = []
        var byContent: [String: Int32] = [:]
        for t in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let content = t["content"] as? String, let id = (t["id"] as? NSNumber)?.int32Value else { continue }
            byContent[content] = id
            if t["single_word"] as? Bool == true || t["lstrip"] as? Bool == true || t["rstrip"] as? Bool == true {
                throw LoadError.unsupported("added token options for \(content)")
            }
            if t["normalized"] as? Bool == true {
                normalizedSpecials.append((content, id))
            } else {
                specials.append((content, id))
            }
        }
        self.specialTokens = specials.sorted { $0.0.count > $1.0.count }
        self.normalizedSpecialTokens = normalizedSpecials.sorted { $0.0.count > $1.0.count }

        func special(_ name: String) throws -> Int32 {
            if let pp = root["post_processor"] as? [String: Any],
               let st = pp["special_tokens"] as? [String: Any],
               let entry = st[name] as? [String: Any],
               let id = (entry["ids"] as? [NSNumber])?.first?.int32Value {
                return id
            }
            if let id = byContent[name] { return id }
            throw LoadError.unsupported("no \(name) token")
        }
        self.clsID = try special("[CLS]")
        self.sepID = try special("[SEP]")
        self.padID = try special("[PAD]")
    }

    static func parseNormalizer(_ any: Any?) throws -> [Normalizer] {
        guard let n = any as? [String: Any], let type = n["type"] as? String else { return [] }
        switch type {
        case "Sequence":
            return try (n["normalizers"] as? [Any] ?? []).flatMap { try parseNormalizer($0) }
        case "Replace":
            guard let pattern = n["pattern"] as? [String: Any], let content = n["content"] as? String else {
                throw LoadError.unsupported("Replace normalizer")
            }
            let re: NSRegularExpression
            if let regex = pattern["Regex"] as? String {
                re = try NSRegularExpression(pattern: regex)
            } else if let string = pattern["String"] as? String {
                re = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: string))
            } else {
                throw LoadError.unsupported("Replace pattern")
            }
            return [.replace(re, template: NSRegularExpression.escapedTemplate(for: content))]
        case "NFC": return [.nfc]
        case "NFD": return [.nfd]
        case "NFKC": return [.nfkc]
        case "NFKD": return [.nfkd]
        case "Lowercase": return [.lowercase]
        case "Precompiled":
            guard let b64 = n["precompiled_charsmap"] as? String, let data = Data(base64Encoded: b64) else {
                throw LoadError.unsupported("Precompiled charsmap")
            }
            return [.precompiled(try PrecompiledCharsMap(data))]
        case "Strip":
            return [.strip(left: n["strip_left"] as? Bool ?? false, right: n["strip_right"] as? Bool ?? false)]
        default:
            throw LoadError.unsupported("normalizer \(type)")
        }
    }

    // MARK: Encoding

    /// Token ids for `text`, without [CLS]/[SEP].
    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        var first = true
        for segment in split(text, on: specialTokens) {
            switch segment {
            case .special(let id):
                ids.append(id)
                first = false
            case .text(let raw):
                let normalized = normalize(raw)
                for part in split(normalized, on: normalizedSpecialTokens) {
                    switch part {
                    case .special(let id):
                        ids.append(id)
                    case .text(let t):
                        if t.isEmpty { continue }
                        for word in preTokenize(t, isFirst: first) {
                            ids.append(contentsOf: viterbi(Array(word.unicodeScalars)))
                        }
                    }
                    first = false
                }
            }
        }
        return ids
    }

    enum Segment { case text(String), special(Int32) }

    func split(_ text: String, on specialTokens: [(text: String, id: Int32)]) -> [Segment] {
        guard !specialTokens.isEmpty else { return [.text(text)] }
        var out: [Segment] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var earliest: (Range<Substring.Index>, Int32)?
            for (token, id) in specialTokens {
                if let r = rest.range(of: token, options: .literal),
                   earliest == nil || r.lowerBound < earliest!.0.lowerBound {
                    earliest = (r, id)
                }
            }
            guard let (range, id) = earliest else { break }
            if range.lowerBound > rest.startIndex { out.append(.text(String(rest[..<range.lowerBound]))) }
            out.append(.special(id))
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }

    func normalize(_ text: String) -> String {
        var s = text
        for n in normalizers {
            switch n {
            case .replace(let re, let template):
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
            case .nfc: s = s.precomposedStringWithCanonicalMapping
            case .nfd: s = s.decomposedStringWithCanonicalMapping
            case .nfkc: s = s.precomposedStringWithCompatibilityMapping
            case .nfkd: s = s.decomposedStringWithCompatibilityMapping
            case .lowercase: s = s.lowercased()
            case .strip(let left, let right):
                var scalars = Substring.UnicodeScalarView(s.unicodeScalars)
                if left { while let c = scalars.first, c.properties.isWhitespace { scalars.removeFirst() } }
                if right { while let c = scalars.last, c.properties.isWhitespace { scalars.removeLast() } }
                s = String(scalars)
            case .precompiled(let map):
                s = map.normalize(s)
            }
        }
        return s
    }

    /// Metaspace: spaces become ▁, a leading ▁ is added, and the text is split
    /// before every ▁.
    func preTokenize(_ text: String, isFirst: Bool) -> [String] {
        let r = String(replacement)
        var s = text.replacingOccurrences(of: " ", with: r)
        let prepend = prependScheme == .always || (prependScheme == .first && isFirst)
        if prepend && !s.hasPrefix(r) { s = r + s }
        guard splitWords else { return [s] }
        var words: [String] = []
        var current = String.UnicodeScalarView()
        let mark = replacement.unicodeScalars.first!
        for u in s.unicodeScalars {
            if u == mark && !current.isEmpty {
                words.append(String(current))
                current = String.UnicodeScalarView()
            }
            current.append(u)
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// Best-scoring segmentation of one word. A position no single-character
    /// piece covers becomes [UNK]; adjacent unknowns are fused into one.
    func viterbi(_ chars: [Unicode.Scalar]) -> [Int32] {
        let n = chars.count
        guard n > 0 else { return [] }
        // best[i]: highest score of a segmentation of chars[0..<i], the start
        // of its last piece and that piece's id.
        var score = [Double](repeating: -.infinity, count: n + 1)
        var start = [Int](repeating: -1, count: n + 1)
        var piece = [Int32](repeating: 0, count: n + 1)
        score[0] = 0
        for i in 0..<n where start[i] >= 0 || i == 0 {
            var hasSingle = false
            var candidate = String.UnicodeScalarView()
            for j in i..<min(n, i + maxPieceLength) {
                candidate.append(chars[j])
                guard let p = pieces[String(candidate)] else { continue }
                if j == i { hasSingle = true }
                let s = score[i] + p.score
                if start[j + 1] < 0 || s > score[j + 1] {
                    score[j + 1] = s
                    start[j + 1] = i
                    piece[j + 1] = p.id
                }
            }
            if !hasSingle {
                let s = score[i] + unkScore
                if start[i + 1] < 0 || s > score[i + 1] {
                    score[i + 1] = s
                    start[i + 1] = i
                    piece[i + 1] = unkID
                }
            }
        }
        var ids: [Int32] = []
        var end = n
        while end > 0 {
            let id = piece[end]
            if !(id == unkID && ids.last == unkID) { ids.append(id) }
            end = start[end]
        }
        return ids.reversed()
    }
}

/// SentencePiece's precompiled normalization map (`precompiled_charsmap`): a
/// darts-clone double-array trie over UTF-8 byte strings, plus a blob of
/// NUL-terminated replacements. Mirrors the `spm_precompiled` crate that
/// Hugging Face `tokenizers` uses, quirks included: each grapheme shorter than
/// 6 bytes is looked up whole (by its shortest matching prefix), otherwise
/// each scalar is looked up on its own.
struct PrecompiledCharsMap {
    let trie: [UInt32]
    let replacements: [UInt8]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw UnigramTokenizer.LoadError.unsupported("Precompiled charsmap size") }
        let trieSize = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        guard trieSize % 4 == 0, 4 + trieSize <= bytes.count else {
            throw UnigramTokenizer.LoadError.unsupported("Precompiled charsmap size")
        }
        var trie = [UInt32](repeating: 0, count: trieSize / 4)
        for i in 0..<trie.count {
            let o = 4 + i * 4
            trie[i] = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        self.trie = trie
        self.replacements = Array(bytes[(4 + trieSize)...])
    }

    func normalize(_ s: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            let grapheme = Array(String(ch).utf8)
            if grapheme.count < 6, let r = transform(grapheme) {
                out += r
                continue
            }
            for u in ch.unicodeScalars {
                let part = Array(String(u).utf8)
                out += transform(part) ?? part
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The replacement for the shortest prefix of `key` in the trie.
    func transform(_ key: [UInt8]) -> [UInt8]? {
        guard let index = firstPrefixValue(key), index >= 0, index < replacements.count else { return nil }
        var end = index
        while end < replacements.count && replacements[end] != 0 { end += 1 }
        let r = Array(replacements[index..<end])
        return String(validatingUTF8: r.map { CChar(bitPattern: $0) } + [0]) == nil ? nil : r
    }

    func firstPrefixValue(_ key: [UInt8]) -> Int? {
        guard !trie.isEmpty else { return nil }
        func offset(_ u: UInt32) -> Int { Int((u >> 10) << ((u & (1 << 9)) >> 6)) }
        func label(_ u: UInt32) -> UInt32 { u & (0x8000_0000 | 0xFF) }
        func hasLeaf(_ u: UInt32) -> Bool { (u >> 8) & 1 == 1 }
        var pos = offset(trie[0])
        for c in key {
            if c == 0 { break }
            pos ^= Int(c)
            guard pos < trie.count else { return nil }
            let unit = trie[pos]
            guard label(unit) == UInt32(c) else { return nil }
            pos ^= offset(unit)
            guard pos < trie.count else { return nil }
            if hasLeaf(unit) { return Int(trie[pos] & 0x7FFF_FFFF) }
        }
        return nil
    }
}
