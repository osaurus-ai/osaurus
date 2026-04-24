//
//  LocalGenerationDefaults.swift
//  osaurus
//
//  Reads `generation_config.json` from a locally-installed model bundle and
//  surfaces the sampling defaults (temperature / top_p / top_k / repetition_
//  penalty) so osaurus can honor them when the OpenAI-wire request omits
//  the corresponding field.
//
//  Hugging Face ships these defaults alongside every instruction-tuned
//  checkpoint. Ignoring them serves, e.g., Qwen 3.5 397B-A17B at 0.7
//  temperature when its training recipe specifies 0.6, or Gemma-4 26B-A4B
//  with top_k disabled when the recipe specifies top_k=64. vmlx's
//  `GenerationConfigFile` (Libraries/MLXLMCommon/GenerationConfigFile.swift)
//  only decodes `eos_token_id` from this file, so reading sampling fields
//  is osaurus's job.
//
//  JANG / JANGTQ bundles that ship a `generation_config.json` are read like
//  any other model. Bundles that don't ship one (some JANG snapshots) fall
//  back to vmlx defaults (the caller supplies those) — we do NOT chase
//  `jang_config.source_model.name` to re-resolve here; that's an
//  indirection LocalReasoningCapability already does for chat templates
//  and would couple cache invalidation between the two caches.
//

import Foundation

enum LocalGenerationDefaults {

    struct Defaults: Sendable, Equatable {
        var temperature: Float?
        var topP: Float?
        var topK: Int?
        var repetitionPenalty: Float?

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

    /// Read `generation_config.json` from an on-disk model directory. Exposed
    /// so integration tests can exercise the full filesystem path without
    /// needing `ModelManager.findInstalledModel` to resolve a real install.
    /// Returns `.empty` if the file is missing, unreadable, or malformed.
    static func load(fromDirectory dir: URL) -> Defaults {
        let url = dir.appendingPathComponent("generation_config.json")
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return .empty
        }
        return parse(data: data)
    }

    private static func localDirectory(forModelId modelId: String) -> URL? {
        guard let found = ModelManager.findInstalledModel(named: modelId) else {
            return nil
        }
        let parts = found.id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        return parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Pure, testable JSON parse. Extracted so unit tests can feed in
    /// bundled fixtures without touching the filesystem.
    static func parse(data: Data) -> Defaults {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        var out = Defaults()
        if let t = readFloat(obj["temperature"]) { out.temperature = t }
        if let p = readFloat(obj["top_p"]) { out.topP = p }
        if let k = readInt(obj["top_k"]) { out.topK = k }
        if let rp = readFloat(obj["repetition_penalty"]) { out.repetitionPenalty = rp }
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
}
