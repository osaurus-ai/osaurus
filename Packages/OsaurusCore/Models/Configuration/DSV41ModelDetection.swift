//
//  DSV41ModelDetection.swift
//  osaurus
//
//  DeepSeek-V4.1 detection for request controls, keyed off the installed
//  bundle's `config.json` `model_type` like prompt rendering is.
//

import Foundation

/// Whether a local model id is a DeepSeek-V4.1 bundle.
///
/// Prompt rendering picks the V4.1 contract from the bundle's `model_type`
/// (`DeepseekV4ChatFamily(modelType:)` in `SwiftTransformersTokenizerLoader`),
/// so the request controls (the `chat_template_kwargs` thinking switch and
/// V4.1's thinking-off precedence) must agree with it: a renamed V4.1 bundle
/// renders V4.1 prompts and must also get V4.1 controls. The installed
/// bundle's `model_type == "deepseek_v41"` decides; the name
/// (``ModelFamilyNames/isDSV41Family(_:)``) is the fallback when no local
/// bundle is found (not downloaded, remote ids).
enum DSV41ModelDetection {
    static let modelType = "deepseek_v41"

    /// Test seam: lowercased model id -> bundle `model_type`. When set, it
    /// replaces the disk lookup; an id missing from it has no local bundle.
    @TaskLocal static var bundleModelTypesForTests: [String: String]?

    private static let lock = NSLock()
    /// Resolved `model_type` per lowercased model id. Only found bundles are
    /// cached, so a model installed later is picked up on its next request.
    private nonisolated(unsafe) static var resolvedModelTypes: [String: String] = [:]

    static func isDSV41(modelId: String) -> Bool {
        if let bundleType = bundleModelType(forModelId: modelId) {
            return bundleType == modelType
        }
        return ModelFamilyNames.isDSV41Family(modelId)
    }

    /// The installed bundle's lowercased `model_type`, nil when the model has
    /// no local bundle or its config carries none.
    static func bundleModelType(forModelId modelId: String) -> String? {
        let key = modelId.lowercased()
        if let overrides = bundleModelTypesForTests {
            return overrides[key]?.lowercased()
        }
        lock.lock()
        let cached = resolvedModelTypes[key]
        lock.unlock()
        if let cached { return cached }

        guard let directory = LocalReasoningCapability.localDirectory(forModelId: modelId),
            let data = LocalReasoningCapability.readSmallConfigFile(
                directory.appendingPathComponent("config.json", isDirectory: false)),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawType = config["model_type"] as? String
        else { return nil }
        let resolved = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        resolvedModelTypes[key] = resolved
        lock.unlock()
        return resolved
    }

    /// Call when models are added or removed so the next lookup re-reads configs.
    static func invalidate() {
        lock.lock()
        resolvedModelTypes.removeAll()
        lock.unlock()
    }
}
