import Foundation

/// One inbound message to screen for prompt injection.
public struct ScreenItem: Sendable {
    public let rowID: Int64
    public let text: String
    public let sender: String
    public let senderName: String?     // nil = not in the owner's contacts

    public init(rowID: Int64, text: String, sender: String, senderName: String?) {
        self.rowID = rowID
        self.text = text
        self.sender = sender
        self.senderName = senderName
    }

    public var senderLabel: String { senderName ?? sender }
}

public struct ScreenVerdict: Sendable {
    public enum Kind: String, Sendable {
        case clean
        case flagged
        case unavailable      // the detector couldn't be reached; content was not screened
    }

    public let kind: Kind
    public let score: Double?
    public let reason: String

    public init(kind: Kind, score: Double?, reason: String) {
        self.kind = kind
        self.score = score
        self.reason = reason
    }

    public var isFlagged: Bool { kind == .flagged }
}

/// Screens inbound messages before they reach an agent. Called from a
/// background thread; may block on network calls.
public protocol MessageScreener: Sendable {
    func screen(_ items: [ScreenItem]) -> [Int64: ScreenVerdict]
}

/// Local, free checks that run before (and independently of) the remote
/// detector. They only catch blatant cases; the remote model does the rest.
public enum InjectionHeuristics {
    /// Unicode "tag" characters (U+E0000–U+E007F) are invisible on screen but
    /// read by language models ("ASCII smuggling"). Returns the hidden ASCII.
    public static func hiddenTagText(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars where (0xE0020...0xE007E).contains(u.value) {
            out.unicodeScalars.append(Unicode.Scalar(u.value - 0xE0000)!)
        }
        return out
    }

    static let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x180E, 0x2061, 0x2062, 0x2063, 0x2064]

    public static func invisibleCount(_ s: String) -> Int {
        s.unicodeScalars.filter { invisible.contains($0.value) || (0xE0000...0xE007F).contains($0.value) }.count
    }

    /// Text sent to the remote detector: invisible characters removed and any
    /// smuggled tag text made visible, so the detector judges what a model reads.
    public static func normalizedForScreening(_ s: String) -> String {
        let hidden = hiddenTagText(s)
        var visible = String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !invisible.contains($0.value) && !(0xE0000...0xE007F).contains($0.value)
        }))
        if !hidden.isEmpty { visible += "\n[hidden text decoded from invisible characters: \(hidden)]" }
        return visible
    }

    private static let patterns: [(NSRegularExpression, String)] = [
        (#"\b(ignore|disregard|forget|override)\b[^.\n]{0,30}\b(previous|prior|above|earlier|all|your|system)\b[^.\n]{0,20}\b(instructions?|prompts?|rules|messages|directives)\b"#,
         "tries to override an assistant's instructions"),
        (#"\bsystem\s+prompt\b|\bdeveloper\s+(mode|message)\b|\bjailbreak\b"#,
         "refers to an assistant's system prompt or modes"),
        (#"<\|?\s*(system|im_start|im_end|assistant|endoftext)\s*\|?>|\[/?(INST|SYS|SYSTEM)\]|^\s*(SYSTEM|ASSISTANT|DEVELOPER)\s*:"#,
         "impersonates system or model formatting"),
        (#"\b(send_message|get_conversation|search_messages|lookup_contact|review_messages|list_chats|response_stats|tools/call)\b"#,
         "names this bridge's tools"),
        (#"\b(has_prompt_injection|attack_category|no_attack|is_risky|prompt[_ ]injection\s*[:=]\s*(no|false|none))\b"#,
         "contains screening labels (counterfeit policy)"),
        (#"\b(ai|a\.i\.|assistant|agent|bot|claude|grok|chatgpt|gpt|gemini|copilot|llm)\b\s*[,:-]\s*(please\s+)?(ignore|forward|send|reply|delete|reveal|share|run|execute|text|message|export)\b"#,
         "gives instructions to an AI by name"),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive, .anchorsMatchLines]), $0.1) }

    /// A reason string when the text is blatantly aimed at an AI, else nil.
    public static func blatantReason(_ s: String) -> String? {
        if !hiddenTagText(s).isEmpty { return "contains hidden text in invisible characters" }
        if invisibleCount(s) >= 4 { return "contains many invisible characters" }
        let range = NSRange(s.startIndex..., in: s)
        for (re, reason) in patterns where re.firstMatch(in: s, range: range) != nil {
            return reason
        }
        return nil
    }
}
