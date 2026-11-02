import CoreML
import Foundation

/// A local classifier that scores how likely a text is a prompt attack.
public protocol LocalInjectionClassifier: Sendable {
    /// Probability (0...1) that `text` is a prompt attack.
    func attackProbability(_ text: String) throws -> Double
}

/// Llama Prompt Guard 2 (86M), converted to Core ML by
/// scripts/convert_prompt_guard.py and downloaded by the app
/// (PromptGuardInstaller). Runs on this Mac; text never leaves it.
///
/// It catches explicit jailbreaks and attempts to override an assistant's
/// instructions. It doesn't look for polite requests aimed at an assistant or
/// counterfeit screening policies; the heuristics and Jev cover those.
///
/// The token embedding lookup happens here, from a memory-mapped int8 table
/// (embeddings.bin), and Core ML runs the transformer. See the conversion
/// script for why.
public final class PromptGuard: LocalInjectionClassifier, @unchecked Sendable {
    public static let modelName = "Llama-Prompt-Guard-2-86M"
    public static let directoryName = "PromptGuard"
    /// Files an installed model directory must contain.
    public static let requiredFiles = [modelName + ".mlmodelc", "embeddings.bin", "tokenizer.json"]

    /// The model is trained on windows of up to 512 tokens. Longer texts are
    /// scored in overlapping windows and the highest score wins.
    static let windowTokens = 510
    static let windowOverlap = 64
    static let maxWindows = 16

    public enum LoadError: Error, LocalizedError {
        case notInstalled
        case badModel(String)
        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "the on-device model isn't installed"
            case .badModel(let why): return "the on-device model couldn't be loaded: \(why)"
            }
        }
    }

    let model: MLModel
    let tokenizer: UnigramTokenizer
    let seqLength: Int
    let attackIndex: Int
    /// int8 rows (vocab x dim), then one little-endian float32 scale per row.
    let embeddings: Data
    let vocabSize: Int
    let embeddingDim: Int
    private let lock = NSLock()

    /// CPU only by default: on macOS 26.4 the GPU path aborts the process inside
    /// Metal's graph compiler ("MLIR pass manager failed") on the first score, and
    /// an 86M-parameter model over a few hundred tokens is fast enough on the CPU.
    public init(directory: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        do {
            model = try MLModel(contentsOf: directory.appendingPathComponent(PromptGuard.modelName + ".mlmodelc"),
                                configuration: config)
            tokenizer = try UnigramTokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
            embeddings = try Data(contentsOf: directory.appendingPathComponent("embeddings.bin"), options: .alwaysMapped)
        } catch {
            throw LoadError.badModel((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard tokenizer.padID == 0 else { throw LoadError.badModel("pad token isn't 0") }

        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        seqLength = meta["seq_length"].flatMap { Int($0) } ?? 512
        guard seqLength >= PromptGuard.windowTokens + 2 else { throw LoadError.badModel("sequence length \(seqLength)") }
        guard let shape = meta["embedding_shape"].flatMap({ try? JSONDecoder().decode([Int].self, from: Data($0.utf8)) }),
              shape.count == 2, shape[0] > 0, shape[1] > 0 else {
            throw LoadError.badModel("no embedding shape")
        }
        (vocabSize, embeddingDim) = (shape[0], shape[1])
        guard embeddings.count == vocabSize * embeddingDim + vocabSize * 4 else {
            throw LoadError.badModel("embeddings.bin is \(embeddings.count) bytes, expected \(vocabSize * embeddingDim + vocabSize * 4)")
        }

        // Prompt Guard 2 has two labels: 0 benign, 1 malicious. Prefer the
        // label names when the conversion recorded them.
        let labels = meta["id2label"].flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        attackIndex = labels.first { ["malicious", "jailbreak", "injection"].contains($0.value.lowercased()) }
            .flatMap { Int($0.key) } ?? 1
    }

    /// The installed model's directory: $IMESSAGE_BRIDGE_PROMPT_GUARD if set,
    /// else ~/Library/Application Support/iMessage Bridge/PromptGuard.
    public static var installDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["IMESSAGE_BRIDGE_PROMPT_GUARD"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("iMessage Bridge/\(directoryName)", isDirectory: true)
    }

    /// The model directory, if a complete model is installed.
    public static func locate() -> URL? {
        let dir = installDirectory
        let complete = requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return complete ? dir : nil
    }

    public func attackProbability(_ text: String) throws -> Double {
        let ids = tokenizer.encode(text)
        var best = 0.0
        for window in PromptGuard.windows(ids) {
            best = max(best, try score(window))
        }
        return best
    }

    static func windows(_ ids: [Int32]) -> [ArraySlice<Int32>] {
        guard ids.count > windowTokens else { return [ids[...]] }
        var out: [ArraySlice<Int32>] = []
        var start = 0
        while start < ids.count && out.count < maxWindows {
            let end = min(ids.count, start + windowTokens)
            out.append(ids[start..<end])
            if end == ids.count { break }
            start = end - windowOverlap
        }
        return out
    }

    func score(_ tokens: ArraySlice<Int32>) throws -> Double {
        let length = seqLength
        let dim = embeddingDim
        var window = [tokenizer.clsID] + tokens.prefix(length - 2) + [tokenizer.sepID]
        window += [Int32](repeating: tokenizer.padID, count: length - window.count)
        guard window.allSatisfy({ $0 >= 0 && Int($0) < vocabSize }) else { throw LoadError.badModel("token id out of range") }

        let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), NSNumber(value: dim)], dataType: .float32)
        let idp = ids.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let ep = embeds.dataPointer.bindMemory(to: Float.self, capacity: length * dim)
        embeddings.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let rows = raw.bindMemory(to: Int8.self)
            let scalesOffset = vocabSize * dim
            for (pos, id) in window.enumerated() {
                idp[pos] = id
                let row = Int(id)
                let scale = raw.loadUnaligned(fromByteOffset: scalesOffset + row * 4, as: UInt32.self)
                let s = Float(bitPattern: UInt32(littleEndian: scale))
                let src = row * dim
                let dst = pos * dim
                for j in 0..<dim { ep[dst + j] = Float(rows[src + j]) * s }
            }
        }

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "inputs_embeds": MLFeatureValue(multiArray: embeds),
        ])
        lock.lock()
        defer { lock.unlock() }
        let out = try model.prediction(from: features)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue, logits.count >= 2 else {
            throw LoadError.badModel("no logits in output")
        }
        let values = (0..<logits.count).map { logits[$0].doubleValue }
        let top = values.max()!
        let exps = values.map { exp($0 - top) }
        return exps[attackIndex] / exps.reduce(0, +)
    }
}

/// Loads Prompt Guard on first use and keeps it (or the load error) until
/// the model is installed again or removed.
public final class SharedPromptGuard: LocalInjectionClassifier, @unchecked Sendable {
    public static let shared = SharedPromptGuard()

    private let lock = NSLock()
    private var loaded: Result<PromptGuard, Error>?

    public var isInstalled: Bool { PromptGuard.locate() != nil }

    public func load() throws -> PromptGuard {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return try loaded.get() }
        // Not cached, so a model installed while the app runs is picked up.
        guard let dir = PromptGuard.locate() else { throw PromptGuard.LoadError.notInstalled }
        let result = Result<PromptGuard, Error> { try PromptGuard(directory: dir) }
        loaded = result
        return try result.get()
    }

    /// Drops the loaded model, so the next use loads what's on disk now.
    public func unload() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    public func attackProbability(_ text: String) throws -> Double {
        try load().attackProbability(text)
    }
}
