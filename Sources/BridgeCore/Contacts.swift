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

    /// Emails lowercase; phone numbers reduce to their last 10 digits.
    /// Short codes and unrecognized strings return "".
    public static func normalize(_ handle: String) -> String {
        let s = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if s.contains("@") { return s.lowercased() }
        let digits = s.filter(\.isASCII).filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : ""
    }

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
