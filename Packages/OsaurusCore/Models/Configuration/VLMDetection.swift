//
//  VLMDetection.swift
//  osaurus
//
//  Single source of truth for Vision Language Model detection.
//  Delegates to VLMTypeRegistry from mlx-swift-lm for architecture-based
//  detection, and checks vision_config in config.json for downloaded models.
//

import Foundation
import MLXVLM

enum VLMDetection {
    /// Check if a downloaded model at the given directory is a VLM.
    /// Uses vision_config key presence in config.json as the definitive signal,
    /// disambiguating model types registered in both LLM and VLM factories
    /// (e.g. gemma4 has both text-only and vision variants).
    static func isVLM(at directory: URL) -> Bool {
        guard let json = readConfigJSON(at: directory) else { return false }
        return json["vision_config"] != nil
    }

    /// Check if a model_type string is a known VLM architecture.
    static func isVLM(modelType: String) -> Bool {
        VLMTypeRegistry.supportedModelTypes.contains(modelType)
    }

    /// Best-effort check for a model by its Hugging Face repo ID.
    /// Returns false if the model is not downloaded locally.
    static func isVLM(modelId: String) -> Bool {
        guard let dir = findLocalModelDirectory(forModelId: modelId) else { return false }
        return isVLM(at: dir)
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
