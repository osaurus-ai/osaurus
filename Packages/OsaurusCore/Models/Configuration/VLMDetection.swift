//
//  VLMDetection.swift
//  osaurus
//
//  Single source of truth for Vision Language Model detection.
//  Delegates to VLMTypeRegistry from vmlx-swift for architecture-based
//  detection, and checks vision_config in config.json for downloaded models.
//

import Foundation
import MLXVLM

enum VLMDetection {
    // MARK: - Memoization

    // `isVLM(at:)` / `isVLM(modelId:)` are read from view bodies (e.g.
    // `ModelRowView.modelTypeBadge` via `MLXModel.isVLM`) on every SwiftUI body
    // evaluation, and each call reads + parses config.json from disk — synchronous
    // I/O that hangs the UI when it runs per row per body eval. Verdicts are pure
    // functions of the on-disk model, so they're cached and dropped on
    // `.localModelsChanged` to stay in sync with downloads and deletions.
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var verdictCache: [String: Bool] = [:]
    private nonisolated(unsafe) static var didInstallObserver = false

    private static func cachedVerdict(_ key: String, compute: () -> Bool) -> Bool {
        ensureCacheObserverInstalled()
        cacheLock.lock()
        if let cached = verdictCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = compute()

        cacheLock.lock()
        verdictCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func ensureCacheObserverInstalled() {
        cacheLock.lock()
        let already = didInstallObserver
        didInstallObserver = true
        cacheLock.unlock()
        if already { return }

        NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: nil
        ) { _ in
            VLMDetection.cacheLock.lock()
            VLMDetection.verdictCache.removeAll(keepingCapacity: true)
            VLMDetection.cacheLock.unlock()
        }
    }

    /// Check if a downloaded model at the given directory is a VLM.
    /// Mirrors vMLX's factory dispatch: Nemotron Omni bundles are identified by
    /// `config_omni.json` because their primary `config.json` deliberately
    /// describes only the inner text decoder (`model_type: nemotron_h`). Other
    /// families use `vision_config` presence to disambiguate model types
    /// registered in both LLM and VLM factories (for example Gemma4).
    static func isVLM(at directory: URL) -> Bool {
        cachedVerdict("dir:\(directory.path)") {
            let omniSidecar = directory.appendingPathComponent("config_omni.json")
            if FileManager.default.fileExists(atPath: omniSidecar.path) {
                return true
            }
            guard let json = readConfigJSON(at: directory) else { return false }
            return json["vision_config"] != nil
        }
    }

    /// Check if a model_type string is a known VLM architecture.
    static func isVLM(modelType: String) -> Bool {
        let trimmed = modelType.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard normalized != "zaya" else { return false }
        if normalized == "diffusion_gemma" { return true }
        return VLMTypeRegistry.supportedModelTypes.contains(trimmed)
            || VLMTypeRegistry.supportedModelTypes.contains(normalized)
    }

    /// Best-effort check for a model by its Hugging Face repo ID.
    /// Returns false if the model is not downloaded locally.
    static func isVLM(modelId: String) -> Bool {
        if ModelFamilyNames.isNemotronThinkingFamily(modelId)
            && !ModelFamilyNames.isNemotronOmniFamily(modelId)
        {
            return false
        }
        if ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(modelId) {
            return false
        }
        return cachedVerdict("id:\(modelId)") {
            guard let dir = findLocalModelDirectory(forModelId: modelId) else { return false }
            return isVLM(at: dir)
        }
    }

    /// Read model_type from a model's local config.json.
    static func readModelType(at directory: URL) -> String? {
        readConfigJSON(at: directory)?["model_type"] as? String
    }

    // MARK: - Private

    private static func readConfigJSON(at directory: URL) -> [String: Any]? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func findLocalModelDirectory(forModelId id: String) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
        else { return nil }
        return url
    }
}
