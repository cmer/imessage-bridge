import Foundation

public struct ContactEntry: Sendable {
    public let name: String
    public let handles: [String]
}

/// Reads the local AddressBook databases (needs Full Disk Access).
public struct ContactBook: Sendable {
    public private(set) var entries: [ContactEntry] = []
    private var nameByHandle: [String: String] = [:]

    public init(entries: [ContactEntry]) {
        // Merge duplicate cards with the same name (e.g. iCloud + local copies).
        var merged: [String: (name: String, handles: [String])] = [:]
        var order: [String] = []
        for e in entries {
            let key = e.name.lowercased()
            if merged[key] == nil {
                merged[key] = (e.name, [])
                order.append(key)
            }
            for h in e.handles where !merged[key]!.handles.contains(h) {
                merged[key]!.handles.append(h)
            }
        }
        self.entries = order.map { ContactEntry(name: merged[$0]!.name, handles: merged[$0]!.handles) }
        for e in self.entries {
            for h in e.handles {
                let k = ContactBook.normalize(h)
                if !k.isEmpty, nameByHandle[k] == nil { nameByHandle[k] = e.name }
            }
        }
    }

    /// The key handles are compared by. Emails lowercase; phone numbers become their full
    /// international digits, country code included ("+1 (555) 123-4567" → "15551234567"),
    /// so numbers in different countries never share a key. A number written without a
    /// country code is read as this Mac's region would dial it. Short codes, group chat ids
    /// and anything else return "", which matches nothing.
    public static func normalize(_ handle: String) -> String {
        normalize(handle, region: currentRegion)
    }

    static let currentRegion = Locale.current.region?.identifier

    public static func normalize(_ handle: String, region: String?) -> String {
        let s = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("@") { return s.lowercased() }
        if s.contains(where: \.isLetter) { return "" }
        let digits = Substring(s.filter { $0.isASCII && $0.isNumber })
        let minDigits = 7  // shorter than any full number; short codes stay out
        if s.hasPrefix("+") { return digits.count >= minDigits ? String(digits) : "" }

        // No country code: interpret it with the region's dialing plan, or give up.
        guard let region, let plan = dialPlans[region] else { return "" }
        if digits.hasPrefix(plan.exit) {
            let intl = digits.dropFirst(plan.exit.count)
            return intl.count >= minDigits ? String(intl) : ""
        }
        if plan.code == "1" {
            let n = digits.count == 11 && digits.hasPrefix("1") ? digits.dropFirst() : digits
            guard n.count == 10, let first = n.first, first != "0", first != "1" else { return "" }
            return "1" + n
        }
        let national = !plan.trunk.isEmpty && digits.hasPrefix(plan.trunk) ? digits.dropFirst(plan.trunk.count) : digits
        return national.count >= minDigits ? plan.code + national : ""
    }

    private struct DialPlan {
        let code: String   // country calling code
        let trunk: String  // domestic prefix dropped before the code is added ("0" in 07700 900123)
        let exit: String   // prefix for dialing abroad
    }

    /// Regions whose dialing plan is known. A number without a country code from any other
    /// region doesn't normalize, so it matches nothing rather than the wrong country.
    private static let dialPlans: [String: DialPlan] = {
        var plans: [String: DialPlan] = [:]
        let nanp = "US CA PR VI GU AS MP BS BB AI AG VG KY BM GD TC MS SX LC DM VC DO TT KN JM"
        for r in nanp.split(separator: " ") { plans[String(r)] = DialPlan(code: "1", trunk: "", exit: "011") }
        // region:code:trunk
        let others = """
            GB:44:0 IE:353:0 FR:33:0 DE:49:0 AT:43:0 CH:41:0 NL:31:0 BE:32:0 LU:352: \
            IT:39: SM:378: VA:39: ES:34: PT:351: GR:30: DK:45: NO:47: SE:46:0 FI:358:0 IS:354: \
            PL:48: CZ:420: SK:421:0 HU:36:06 RO:40:0 BG:359:0 HR:385:0 SI:386:0 RS:381:0 \
            UA:380:0 RU:7:8 KZ:7:8 BY:375:8 LV:371: EE:372: TR:90:0 IL:972:0 AE:971:0 SA:966:0 \
            EG:20:0 ZA:27:0 NG:234:0 KE:254:0 MA:212:0 IN:91:0 PK:92:0 BD:880:0 CN:86:0 \
            HK:852: MO:853: TW:886:0 JP:81:0 KR:82:0 SG:65: MY:60:0 TH:66:0 VN:84:0 PH:63:0 \
            ID:62:0 AU:61:0 NZ:64:0 MX:52: BR:55:0 AR:54:0
            """
        for entry in others.split(separator: " ") {
            let f = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            plans[f[0]] = DialPlan(code: f[1], trunk: f[2], exit: "00")
        }
        return plans
    }()

    public func name(for handle: String) -> String? {
        let k = ContactBook.normalize(handle)
        return k.isEmpty ? nil : nameByHandle[k]
    }

    /// Contacts whose name or one of whose handles contains `query`.
    public func search(_ query: String) -> [ContactEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let norm = ContactBook.normalize(q)
        return entries.filter { e in
            if e.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            if !norm.isEmpty { return e.handles.contains { ContactBook.normalize($0) == norm } }
            return false
        }
    }

    public static func load() -> ContactBook {
        let base = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        var paths: [String] = []
        let sources = base + "/Sources"
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: sources) {
            for d in dirs {
                let p = "\(sources)/\(d)/AddressBook-v22.abcddb"
                if FileManager.default.fileExists(atPath: p) { paths.append(p) }
            }
        }
        let root = base + "/AddressBook-v22.abcddb"
        if FileManager.default.fileExists(atPath: root) { paths.append(root) }

        var all: [ContactEntry] = []
        for path in paths {
            guard let db = try? SQLiteDB(path: path) else { continue }
            var names: [Int64: String] = [:]
            let recordRows = (try? db.query("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD"))
                ?? (try? db.query("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, NULL FROM ZABCDRECORD"))
                ?? []
            for r in recordRows {
                let person = [r[1].string, r[2].string]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let name = person.isEmpty ? r[3].string.trimmingCharacters(in: .whitespaces) : person
                if !name.isEmpty { names[r[0].int64] = name }
            }
            var handles: [Int64: [String]] = [:]
            for r in (try? db.query("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER")) ?? [] {
                let h = r[1].string
                if !h.isEmpty { handles[r[0].int64, default: []].append(h) }
            }
            for r in (try? db.query("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS")) ?? [] {
                let h = r[1].string
                if !h.isEmpty { handles[r[0].int64, default: []].append(h) }
            }
            for (pk, name) in names {
                if let hs = handles[pk], !hs.isEmpty {
                    all.append(ContactEntry(name: name, handles: hs))
                }
            }
        }
        all.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ContactBook(entries: all)
    }
}
