import Foundation

/// Redaction and triage heuristics, ported from grokbot-imessage-skill (MIT).
public enum Redactor {
    private static let code = try! NSRegularExpression(
        pattern: #"(?:\b(?:code|verification|OTP|passcode|one[- ]time)\b[^0-9]{0,20}\b(\d{4,8})\b)|(?:\b(\d{4,8})\b[^0-9]{0,20}\b(?:code|verification|OTP|passcode)\b)"#,
        options: [.caseInsensitive])
    private static let card = try! NSRegularExpression(pattern: #"\b\d(?:[ -]?\d){12,18}\b"#)
    private static let ssn = try! NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#)

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var t = replace(code, in: text, with: "[REDACTED-2FA]")
        t = replace(card, in: t, with: "[REDACTED-CARD]")
        t = replace(ssn, in: t, with: "[REDACTED-SSN]")
        return t
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with tpl: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                    withTemplate: NSRegularExpression.escapedTemplate(for: tpl))
    }
}

public enum Triage {
    private static let automated = try! NSRegularExpression(pattern: [
        #"lyft:.*(requested|on their way|arrived|cancelled)"#,
        #"uber:.*(on|arriving|trip)"#,
        #"your .*verification code"#,
        #"your .*code is"#,
        #"verification code|one-time password|\botp\b"#,
        #"actblue|midterms|reelection|\bdonate\b|rush \$\d+"#,
        #"stop to quit|reply stop"#,
        #"error invalid number"#,
        #"delivered|out for delivery|package|shipment"#,
        #"check-in"#,
        #"bill is ready|statement is available"#,
        #"your appointment|appointment reminder"#,
    ].joined(separator: "|"), options: [.caseInsensitive])
    private static let shortCode = try! NSRegularExpression(pattern: #"^[+]?[0-9]{3,6}$"#)
    private static let reaction = try! NSRegularExpression(
        pattern: #"^(liked|loved|laughed at|emphasized|questioned|disliked|reacted|removed a)( a| an)? [“"'\x{FFFC}]"#,
        options: [.caseInsensitive])
    private static let acks: Set<String> = [
        "thx", "thanks", "ty", "ok", "okay", "k", "sure", "sounds good", "for sure",
        "cool", "nice", "great", "got it", "yep", "yup", "nope",
    ]

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func isAutomated(chatIdentifier: String, text: String) -> Bool {
        if matches(shortCode, chatIdentifier) || chatIdentifier.contains("rbm.goog") { return true }
        return !text.isEmpty && matches(automated, text)
    }

    public static func isLowSignal(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || matches(reaction, t) { return true }
        let stripped = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "!. "))
        return acks.contains(stripped)
    }
}
