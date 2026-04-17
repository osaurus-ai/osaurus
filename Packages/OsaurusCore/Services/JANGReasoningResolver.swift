//
//  JANGReasoningResolver.swift
//  osaurus
//
//  Reads a local model's `jang_config.json` capabilities stamp (shipped by
//  the JANG / JANGTQ converter starting with vmlx-swift-lm c101739) and
//  resolves the correct reasoning parser + tool-call format via
//  `MLXLMCommon.ParserResolution`. Results are cached per-model so the
//  disk read happens once per load, not per token.
//
//  Scope: **JANG-stamped models only**. Non-JANG models (e.g. raw HF
//  checkpoints) still flow through osaurus's existing `<think>` tag
//  handling in `StreamingDeltaProcessor.parseAndRoute`. This keeps the
//  blast radius of the change small while letting vmlx's centralised
//  parser be the source of truth for every model the JANG converter
//  has stamped.
//

import Foundation
import MLXLMCommon

enum JANGReasoningResolver {

    /// Resolved parsers for one model plus the source osaurus picked them
    /// from — surfaced in logs so operators can diagnose why a given model
    /// renders reasoning one way vs another.
    struct Resolution: Sendable {
        /// vmlx-provided streaming reasoning parser. `nil` means the model
        /// family explicitly doesn't emit reasoning (Mistral 4, Gemma 4),
        /// or the stamp wasn't recognised. Callers should skip parsing
        /// when nil — do NOT substitute a default parser, because that
        /// would split `<think>` tags that legitimately belong in the
        /// answer (code samples, jinja templates, etc.).
        let reasoningParser: ReasoningParser?

        /// Resolved tool-call wire format. `nil` → no tool parsing (osaurus
        /// falls back to vmlx's `ModelConfiguration.toolCallFormat` default).
        let toolCallFormat: ToolCallFormat?

        /// `.jangStamped` = stamp in `jang_config.capabilities` resolved it;
        /// `.modelTypeHeuristic` = vmlx fell back to `config.json.model_type`;
        /// `.none` = neither yielded a parser.
        let reasoningSource: JangCapabilities.ResolutionSource
        let toolCallSource: JangCapabilities.ResolutionSource

        /// True if the model is stamped — osaurus uses this to gate whether
        /// to run the vmlx parser or defer to its existing in-house handler.
        var isStamped: Bool {
            reasoningSource == .jangStamped || toolCallSource == .jangStamped
        }
    }

    // Per-model cache. `nil` means "no jang_config.json / not stamped" —
    // stored so we don't re-read + re-decode on every session.
    private static let lock = NSLock()
    private static nonisolated(unsafe) var cache: [String: Resolution] = [:]

    /// Resolve once per model. Safe to call from any concurrency context.
    /// - Parameters:
    ///   - modelKey: stable identifier for the cache (osaurus uses the
    ///     `canonical name` string it hands to `ModelRuntime.loadContainer`).
    ///   - directory: on-disk model root, already symlink-resolved.
    static func resolve(modelKey: String, directory: URL) -> Resolution {
        let key = modelKey.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let resolution = computeResolution(directory: directory)
        lock.lock()
        cache[key] = resolution
        lock.unlock()
        return resolution
    }

    /// Convenience: resolve by display/picker name. Returns `nil` if the
    /// name doesn't map to an installed model (osaurus's existing
    /// ModelManager.findInstalledModel handles symlinks and case).
    /// Used by UI-layer code (ChatView / WorkSession) that has the model
    /// name but shouldn't need to know the on-disk directory layout.
    static func resolve(modelKey: String) -> Resolution? {
        guard !modelKey.isEmpty else { return nil }
        guard let match = ModelManager.findInstalledModel(named: modelKey) else {
            return nil
        }
        let parts = match.id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let directory = parts.reduce(base) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.resolvingSymlinksInPath()
        return resolve(modelKey: modelKey, directory: directory)
    }

    /// Invalidate for a specific model (called on download / delete).
    static func invalidate(modelKey: String) {
        let key = modelKey.lowercased()
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
    }

    /// Invalidate every cached resolution. Called from
    /// `ModelManager.invalidateLocalModelsCache` so adding, removing, or
    /// re-downloading any model picks up the freshly written jang_config.
    static func invalidateAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - Internals

    private static func computeResolution(directory: URL) -> Resolution {
        // Try to load jang_config.json via vmlx's canonical loader so any
        // future schema changes are absorbed without osaurus-side churn.
        let capabilities: JangCapabilities?
        let modelType: String?

        do {
            let jang = try JangLoader.loadConfig(at: directory)
            capabilities = jang.capabilities
        } catch {
            // No jang_config.json, or it's malformed. Not an error for
            // non-JANG models — fall through to the heuristic path.
            capabilities = nil
        }

        // `config.json.model_type` is always the heuristic anchor.
        modelType = Self.readModelType(at: directory)

        let (reasoningParser, rSource) = ParserResolution.reasoning(
            capabilities: capabilities,
            modelType: modelType
        )
        let (toolCallFormat, tSource) = ParserResolution.toolCall(
            capabilities: capabilities,
            modelType: modelType
        )

        return Resolution(
            reasoningParser: reasoningParser,
            toolCallFormat: toolCallFormat,
            reasoningSource: rSource,
            toolCallSource: tSource
        )
    }

    /// Thin probe of config.json — avoids decoding the whole HF config
    /// when all we need is model_type.
    private static func readModelType(at directory: URL) -> String? {
        let url = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelType = json["model_type"] as? String
        else {
            return nil
        }
        return modelType
    }
}
