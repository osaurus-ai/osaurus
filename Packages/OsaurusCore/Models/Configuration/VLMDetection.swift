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
    nonisolated static func isVLM(at directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["vision_config"] != nil
    }

    /// Check if a model_type string is a known VLM architecture.
    /// Uses VLMTypeRegistry from mlx-swift-lm as the source of truth.
    nonisolated static func isVLM(modelType: String) -> Bool {
        VLMTypeRegistry.supportedModelTypes.contains(modelType)
    }

    /// Best-effort check for a model by its Hugging Face repo ID.
    /// Reads config.json from the local model directory if downloaded.
    nonisolated static func isVLM(modelId: String) -> Bool {
        guard let dir = findLocalModelDirectory(forModelId: modelId) else { return false }
        return isVLM(at: dir)
    }

    /// Read model_type from a model's local config.json.
    nonisolated static func readModelType(at directory: URL) -> String? {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["model_type"] as? String
    }

    nonisolated private static func findLocalModelDirectory(forModelId id: String) -> URL? {
        let parts = id.split(separator: "/").map(String.init)
        let base = DirectoryPickerService.effectiveModelsDirectory()
        let url = parts.reduce(base) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("config.json").path) {
            return url
        }
        return nil
    }
}
