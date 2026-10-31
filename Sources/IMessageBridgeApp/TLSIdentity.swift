import BridgeCore
import Foundation
import Security

/// Self-signed certificate for the network listener. Clients pin its SHA-256
/// fingerprint at pairing time, so no certificate authority is involved.
enum TLSIdentityStore {
    static func loadOrCreate(in dir: URL) throws -> (SecIdentity, String) {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p12 = dir.appendingPathComponent("identity.p12")
        let passFile = dir.appendingPathComponent("identity.pass")
        if !fm.fileExists(atPath: p12.path) || !fm.fileExists(atPath: passFile.path) {
            try generate(p12: p12, passFile: passFile, dir: dir)
        }
        let pass = try String(contentsOf: passFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try load(p12: p12, password: pass)
    }

    static func regenerate(in dir: URL) throws -> (SecIdentity, String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("identity.p12"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("identity.pass"))
        return try loadOrCreate(in: dir)
    }

    private static func generate(p12: URL, passFile: URL, dir: URL) throws {
        let key = dir.appendingPathComponent("key.pem")
        let cert = dir.appendingPathComponent("cert.pem")
        defer {
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: cert)
        }
        let pass = Tokens.random(bytes: 24)
        try run(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
                 "-subj", "/CN=iMessage Bridge", "-keyout", key.path, "-out", cert.path])
        try run(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                 "-out", p12.path, "-passout", "pass:\(pass)", "-name", "iMessage Bridge"])
        try Data(pass.utf8).write(to: passFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw BridgeServerError("openssl \(args[0]) failed: \(msg)")
        }
    }

    private static func load(p12: URL, password: String) throws -> (SecIdentity, String) {
        let data = try Data(contentsOf: p12)
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let list = items as? [[String: Any]],
              let first = list.first,
              let anyIdentity = first[kSecImportItemIdentity as String] else {
            throw BridgeServerError("could not import TLS identity (OSStatus \(status))")
        }
        let identity = anyIdentity as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw BridgeServerError("TLS identity has no certificate") }
        let der = SecCertificateCopyData(cert) as Data
        return (identity, Tokens.fingerprint(der))
    }
}
