//
//  LocalGenerationDefaults.swift
//  osaurus
//
//  Reads sampling defaults from a locally-installed model bundle and
//  surfaces them (max_new_tokens / temperature / top_p / top_k / min_p /
//  repetition_penalty / do_sample) so osaurus can honor them when the
//  OpenAI-wire request omits the
//  corresponding field.
//
//  Two sources are consulted, primary → fallback:
//
//    1. `jang_config.json > chat > sampling_defaults` — present on JANG /
//       JANGTQ bundles that ship the newer chat-metadata schema (DSV4,
//       Kimi K2.6, newer Gemma-4 / Qwen-3.6 JANG snapshots). These are
//       authoritative for JANG converters — the DSV4
//       `convert_dsv4_jangtq.py` reads `inference/generate.py` defaults
//       directly and stamps them here, which may differ from the source
//       model's generic `generation_config.json` (e.g. DSV4 uses
//       temp=0.6, while upstream HF ships temp=1.0).
//
//    2. `generation_config.json` — Hugging Face's standard
//       sampling-defaults file, shipped with every instruction-tuned
//       checkpoint regardless of quantization format (base MLX, MXFP4,
//       JANG, JANGTQ, FP16, …). osaurus mirrors vmlx's
//       `GenerationConfigFile` sampling fields so the app and direct-engine
//       paths use the same bundle defaults.
//
//  Ignoring these served, e.g., Qwen 3.5 397B-A17B at 0.7 temperature when
//  its recipe specifies 0.6, Gemma-4 26B-A4B with top_k disabled when the
//  recipe specifies top_k=64, and (with the new JANG schema)
//  DSV4-Flash-JANGTQ at upstream's temp=1.0 rather than DeepSeek's tuned
//  temp=0.6 shipped in the JANG config.
//
//  Bundles that ship BOTH files get the JANG `chat.sampling_defaults`
//  applied first, with any fields the JANG config omits filled from
//  `generation_config.json`. Bundles that ship neither return `.empty`
//  and the caller falls back to vmlx's own `GenerateParameters` defaults
//  after request and server-runtime overrides.
//
//  We intentionally do NOT chase `jang_config.source_model.name` to
//  re-resolve from the source model's own config directory — that
//  indirection would couple cache invalidation between two caches, and
//  the JANG converter already stamps whatever defaults it wants honored
//  into `chat.sampling_defaults` directly.
//

import Foundation
import Darwin

enum LocalGenerationDefaults {

    struct Defaults: Sendable, Equatable {
        var maxTokens: Int?
        var temperature: Float?
        var topP: Float?
        var topK: Int?
        var minP: Float?
        var repetitionPenalty: Float?
        var doSample: Bool?

        static let empty = Defaults()
    }

    private static nonisolated let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Defaults] = [:]

    /// Resolve and cache the sampling defaults for `modelId`. The id may be
    /// either the short picker name or the full `ORG/REPO` identifier; both
    /// are supported via `ModelManager.findInstalledModel`.
    static func defaults(forModelId modelId: String) -> Defaults {
        let key = modelId.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolved = load(modelId: modelId)

        lock.lock()
        cache[key] = resolved
        lock.unlock()
        return resolved
    }

    /// Invalidate the cache. Call when models are added/removed so the next
    /// lookup re-reads the file from disk.
    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - File loading

    private static func load(modelId: String) -> Defaults {
        guard let dir = localDirectory(forModelId: modelId) else {
            return .empty
        }
        return load(fromDirectory: dir)
    }

    /// Read sampling defaults from an on-disk model directory. Merges two
    /// sources in priority order, primary → fallback:
    ///
    ///   1. `jang_config.json > chat > sampling_defaults` — authoritative
    ///      when present. JANG / JANGTQ converters (DSV4, Kimi K2.6,
    ///      newer Gemma-4 / Qwen-3.6 JANG snapshots) stamp
    ///      training-recipe defaults here that can differ from the
    ///      upstream HF `generation_config.json`. Per
    ///      `jang/jang-tools/dsv4_prune/convert_dsv4_jangtq.py`, DSV4's
    ///      chat.sampling_defaults carries `temperature: 0.6` from
    ///      `inference/generate.py`, while upstream HF ships `1.0`.
    ///
    ///   2. `generation_config.json` — HuggingFace standard, present on
    ///      every instruction-tuned checkpoint. Fills any field the JANG
    ///      config left unset.
    ///
    /// Exposed so integration tests can exercise the full filesystem path
    /// without needing `ModelManager.findInstalledModel` to resolve a real
    /// install. Returns `.empty` if neither file is present or all parses
    /// fail.
    static func load(fromDirectory dir: URL) -> Defaults {
        let jang = loadJangConfigDefaults(at: dir)
        let hf = loadHuggingFaceGenerationDefaults(at: dir)
        return merge(primary: jang, fallback: hf)
    }

    private static func loadJangConfigDefaults(at dir: URL) -> Defaults {
        let url = dir.appendingPathComponent("jang_config.json")
        guard let data = readSmallConfigFile(url) else {
            return .empty
        }
        return parseJangConfig(data: data)
    }

    private static func loadHuggingFaceGenerationDefaults(at dir: URL) -> Defaults {
        let url = dir.appendingPathComponent("generation_config.json")
        guard let data = readSmallConfigFile(url) else {
            return .empty
        }
        return parse(data: data)
    }

    private static func readSmallConfigFile(_ url: URL, maxBytes: Int = 1_048_576) -> Data? {
        let path = url.path
        return path.withCString { rawPath in
            let fd = Darwin.open(rawPath, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }

            var statBuffer = stat()
            guard Darwin.fstat(fd, &statBuffer) == 0,
                (statBuffer.st_mode & S_IFMT) == S_IFREG,
                statBuffer.st_size >= 0,
                statBuffer.st_size <= maxBytes
            else {
                return nil
            }

            var data = Data(count: Int(statBuffer.st_size))
            let count = data.count
            guard count > 0 else { return Data() }
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, count)
            }
            guard readCount == count else { return nil }
            return data
        }
    }

    private static func localDirectory(forModelId modelId: String) -> URL? {
        guard let found = ModelManager.findInstalledMLXModel(named: modelId) else {
            return nil
        }
        return found.localDirectory
    }

    // MARK: - Parsers

    /// Pure, testable JSON parse for HuggingFace `generation_config.json`.
    /// Extracted so unit tests can feed in bundled fixtures without touching
    /// the filesystem.
    static func parse(data: Data) -> Defaults {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        return extractSamplingFields(from: obj)
    }

    /// Pure, testable JSON parse for `jang_config.json`'s
    /// `chat.sampling_defaults` sub-object. The JANG schema (per
    /// `jang/jang-tools/dsv4_prune/convert_dsv4_jangtq.py`) places sampling
    /// defaults at a dotted path — everything else at the top level
    /// (quantization, source_model, crack_surgery, architecture, format,
    /// chat.reasoning mode tables, chat.tool_calling parser stamp, …) is
    /// ignored by this function. Those other fields belong to vmlx's model
    /// loader and tool-parser / reasoning-parser resolvers, not osaurus's
    /// sampling overlay.
    static func parseJangConfig(data: Data) -> Defaults {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let chat = root["chat"] as? [String: Any],
            let sampling = chat["sampling_defaults"] as? [String: Any]
        else {
            return .empty
        }
        return extractSamplingFields(from: sampling)
    }

    /// Merge two `Defaults` values field-by-field, preferring `primary` for
    /// any field it sets. Used to overlay `jang_config.json` over
    /// `generation_config.json` so a JANG bundle that sets only
    /// `temperature` gets its temperature plus whatever `top_p` / `top_k`
    /// the source model's HF config specifies.
    static func merge(primary: Defaults, fallback: Defaults) -> Defaults {
        var out = primary
        if out.maxTokens == nil { out.maxTokens = fallback.maxTokens }
        if out.temperature == nil { out.temperature = fallback.temperature }
        if out.topP == nil { out.topP = fallback.topP }
        if out.topK == nil { out.topK = fallback.topK }
        if out.minP == nil { out.minP = fallback.minP }
        if out.repetitionPenalty == nil { out.repetitionPenalty = fallback.repetitionPenalty }
        if out.doSample == nil { out.doSample = fallback.doSample }
        return out
    }

    private static func extractSamplingFields(from obj: [String: Any]) -> Defaults {
        var out = Defaults()
        if let maxTokens = readInt(obj["max_new_tokens"]) { out.maxTokens = maxTokens }
        if let t = readFloat(obj["temperature"]) { out.temperature = t }
        if let p = readFloat(obj["top_p"]) { out.topP = p }
        if let k = readInt(obj["top_k"]) { out.topK = k }
        if let minP = readFloat(obj["min_p"]) { out.minP = minP }
        if let rp = readFloat(obj["repetition_penalty"]) { out.repetitionPenalty = rp }
        if let doSample = readBool(obj["do_sample"]) { out.doSample = doSample }
        return out
    }

    /// JSON numbers land as `NSNumber` once bridged through `JSONSerialization`.
    /// Int/Double are interchangeable at the Obj-C layer but Swift's `as? Double`
    /// rejects `NSNumber` backed by an integer literal, so we funnel through
    /// the explicit helpers instead of a single conditional cast.
    private static func readFloat(_ any: Any?) -> Float? {
        if let n = any as? NSNumber { return n.floatValue }
        return nil
    }

    private static func readInt(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func readBool(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return nil
    }
}
