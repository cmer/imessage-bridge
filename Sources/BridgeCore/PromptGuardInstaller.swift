import CoreML
import CryptoKit
import Foundation

/// Downloads the on-device model from GitHub and installs it into
/// Application Support. Nothing is installed unless the download's SHA-256
/// matches the one built into the app, and the model loads and runs.
public final class PromptGuardInstaller: @unchecked Sendable {
    public enum Phase: Sendable, Equatable {
        case downloading(fraction: Double)
        case installing
    }

    public enum InstallError: Error, LocalizedError {
        case notPublished
        case http(Int)
        case checksumMismatch
        case incomplete(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .notPublished: return "No on-device model has been published for this version of the app."
            case .http(let code): return "The download failed (HTTP \(code))."
            case .checksumMismatch: return "The download didn't match the expected checksum, so it wasn't installed."
            case .incomplete(let what): return "The download is missing \(what)."
            case .cancelled: return "Download cancelled."
            }
        }
    }

    /// Recorded next to an installed model, to tell whether it's current.
    struct Receipt: Codable { let sha256: String }

    let url: URL
    let sha256: String
    let destination: URL
    let onPhase: @Sendable (Phase) -> Void
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    public init(url: URL = PromptGuardAsset.url, sha256: String = PromptGuardAsset.sha256,
                destination: URL = PromptGuard.installDirectory,
                onPhase: @escaping @Sendable (Phase) -> Void) {
        self.url = url
        self.sha256 = sha256.lowercased()
        self.destination = destination
        self.onPhase = onPhase
    }

    /// SHA-256 of the installed model's download, if one is installed.
    public static func installedSHA256(in dir: URL = PromptGuard.installDirectory) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("installed.json")) else { return nil }
        return (try? JSONDecoder().decode(Receipt.self, from: data))?.sha256
    }

    public static func remove(from dir: URL = PromptGuard.installDirectory) throws {
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    public func install() async throws {
        guard !sha256.isEmpty else { throw InstallError.notPublished }
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let work = parent.appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("model.zip")
        try await download(to: zip)
        try checkCancelled()
        onPhase(.installing)

        guard try Self.sha256(of: zip) == sha256 else { throw InstallError.checksumMismatch }

        let staged = work.appendingPathComponent("model", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path])
        try? fm.removeItem(at: zip)

        let package = staged.appendingPathComponent(PromptGuard.modelName + ".mlpackage")
        guard fm.fileExists(atPath: package.path) else { throw InstallError.incomplete(package.lastPathComponent) }
        let compiled = try await MLModel.compileModel(at: package)
        try fm.moveItem(at: compiled, to: staged.appendingPathComponent(PromptGuard.modelName + ".mlmodelc"))
        try fm.removeItem(at: package)
        for file in PromptGuard.requiredFiles where !fm.fileExists(atPath: staged.appendingPathComponent(file).path) {
            throw InstallError.incomplete(file)
        }
        try JSONEncoder().encode(Receipt(sha256: sha256)).write(to: staged.appendingPathComponent("installed.json"))

        // Make sure it loads and runs before replacing anything.
        _ = try PromptGuard(directory: staged).attackProbability("Hey! Are we still on for dinner at 7?")
        try checkCancelled()

        let old = work.appendingPathComponent("previous", isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: old) }
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: destination) }
            throw error
        }
    }

    func checkCancelled() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw InstallError.cancelled }
    }

    func download(to file: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error {
                    cont.resume(throwing: (error as? URLError)?.code == .cancelled ? InstallError.cancelled : error)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    cont.resume(throwing: InstallError.http(http.statusCode))
                    return
                }
                guard let tmp else {
                    cont.resume(throwing: InstallError.incomplete("the file"))
                    return
                }
                // The temporary file is deleted when this handler returns.
                do {
                    try FileManager.default.moveItem(at: tmp, to: file)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            let onPhase = self.onPhase
            lock.lock()
            self.task = task
            self.observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                onPhase(.downloading(fraction: progress.fractionCompleted))
            }
            let cancelledAlready = cancelled
            lock.unlock()
            onPhase(.downloading(fraction: 0))
            task.resume()
            if cancelledAlready { task.cancel() }
        }
        lock.withLock {
            observation = nil
            task = nil
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw InstallError.incomplete("a readable archive (\(msg.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
    }
}
