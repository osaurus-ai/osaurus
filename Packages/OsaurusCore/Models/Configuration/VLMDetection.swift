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
    /// Actual installed evidence, shared with send/preflight and API metadata.
    static func isVLM(at directory: URL) -> Bool {
        LocalVisionEvidence.inspect(directory).hasVision
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
        guard let directory = localDirectory(forModelId: modelId) else { return false }
        return isVLM(at: directory)
    }

    /// Read model_type from a model's local config.json.
    static func readModelType(at directory: URL) -> String? {
        readConfigJSON(at: directory)?["model_type"] as? String
    }

    // MARK: - Private

    private static func readConfigJSON(at directory: URL) -> [String: Any]? {
        // The hint matters: without `isDirectory`, NSURL stats the filesystem
        // (getattrlist) to decide whether to append a trailing slash — extra
        // synchronous I/O on a path that runs from view bodies on cache miss.
        let configURL = directory.appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func localDirectory(forModelId id: String) -> URL? {
        if let directory = ExternalModelLocator.path(forId: id) { return directory }
        if let model = ModelManager.findInstalledMLXModelFromCache(named: id) {
            return model.localDirectory
        }
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        guard
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("config.json", isDirectory: false).path)
        else { return nil }
        return url
    }
}
