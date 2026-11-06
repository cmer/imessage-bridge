import Foundation

public enum BridgeError: Error, LocalizedError {
    case invalid(String)
    case notFound(String)
    case forbidden(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m), .notFound(let m), .forbidden(let m), .failed(let m): return m
        }
    }
}

public enum Validate {
    public static let maxSendLength = 4000

    public static func number(_ v: Any?, name: String, default d: Double, min lo: Double, max hi: Double) throws -> Double {
        guard let v, !(v is NSNull) else { return d }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
            throw BridgeError.invalid("\(name) must be a number")
        }
        let x = n.doubleValue
        guard x.isFinite, x >= lo, x <= hi else {
            throw BridgeError.invalid("\(name) must be between \(fmt(lo)) and \(fmt(hi))")
        }
        return x
    }

    public static func int(_ v: Any?, name: String, default d: Int, min lo: Int, max hi: Int) throws -> Int {
        Int(try number(v, name: name, default: Double(d), min: Double(lo), max: Double(hi)))
    }

    public static func string(_ v: Any?, name: String, maxLength: Int = 200) throws -> String {
        guard let s = v as? String else { throw BridgeError.invalid("\(name) is required and must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw BridgeError.invalid("\(name) cannot be empty") }
        guard t.count <= maxLength else { throw BridgeError.invalid("\(name) is too long (max \(maxLength))") }
        return t
    }

    public static func optionalString(_ v: Any?, name: String, maxLength: Int = 200) throws -> String? {
        guard let v, !(v is NSNull) else { return nil }
        if let s = v as? String, s.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return try string(v, name: name, maxLength: maxLength)
    }

    /// Phone numbers and email addresses only; group chats are not sendable.
    public static func recipient(_ v: Any?) throws -> String {
        let id = try string(v, name: "to")
        if id.lowercased().hasPrefix("chat") {
            throw BridgeError.invalid("group chats are not supported for sending; use a phone number or email")
        }
        if id.contains("@") {
            let ok = id.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
            guard ok else { throw BridgeError.invalid("to must be a valid email address or phone number") }
            return id.lowercased()
        }
        let ok = id.range(of: #"^\+?[0-9 ().\-]{7,25}$"#, options: .regularExpression) != nil
        let digits = id.filter(\.isNumber)
        guard ok, digits.count >= 10 else {
            throw BridgeError.invalid("to must be a valid phone number (with area code) or email address")
        }
        return id
    }

    public static func sendText(_ v: Any?) throws -> String {
        guard let s = v as? String else { throw BridgeError.invalid("text must be a string") }
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.invalid("text cannot be empty")
        }
        guard s.count <= maxSendLength else {
            throw BridgeError.invalid("text is too long (\(s.count) characters; max \(maxSendLength))")
        }
        for scalar in s.unicodeScalars where scalar.value < 0x20 && !["\n", "\r", "\t"].contains(scalar) {
            throw BridgeError.invalid(String(format: "text contains a control character U+%04X", scalar.value))
        }
        return s
    }

    /// nil means auto: send into the existing chat, else pick by the recipient's history.
    public static func service(_ v: Any?) throws -> String? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String, ["iMessage", "SMS"].contains(s) else {
            throw BridgeError.invalid("service must be \"iMessage\" or \"SMS\"")
        }
        return s
    }

    /// Agent display names: 1–40 printable characters.
    public static func agentName(_ v: Any?) throws -> String {
        let s = try string(v, name: "name", maxLength: 40)
        for scalar in s.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
            throw BridgeError.invalid("name contains a control character")
        }
        return s
    }

    private static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}
