import Foundation

/// Read-only inventory for model-independent media qualification. Discovery is
/// the app's installed-model scan; no weights are loaded and names do not grant
/// capability. Keep rejected declarations visible instead of filtering them out.
public enum InstalledVisionEvaluation {
    public struct DiscoverySource: Codable, Sendable {
        public let root: String
        public let source: String
        public let discoveredCount: Int
        public let skipped: [RejectedBundle]
    }

    public struct RejectedBundle: Codable, Sendable {
        public let directory: String
        public let reason: String
        public let detail: String
    }

    public struct Bundle: Codable, Sendable {
        public let modelID: String
        public let directory: String
        public let modelType: String
        public let declaresVision: Bool
        public let supportsImage: Bool
        public let reason: String
        public let tensorCount: Int
    }

    public static func inventory() async -> [Bundle] {
        await ModelManager.awaitLocalModelsCacheReadyForDispatch()
        return await Task.detached(priority: .utility) {
            // Discovery's UI snapshot is intentionally nonblocking. Qualification
            // must wait for the external registry and its model memo to finish.
            _ = ExternalModelLocator.rescan()
            var seen = Set<String>()
            return ModelManager.discoverLocalModels().compactMap { model -> Bundle? in
                let directory = model.localDirectory.resolvingSymlinksInPath()
                guard seen.insert(directory.path).inserted else { return nil }
                return inspect(directory: directory, modelID: model.id)
            }.sorted { $0.modelID < $1.modelID }
        }.value
    }

    public static func inspect(modelID: String) -> Bundle? {
        guard let directory = VLMDetection.localDirectory(forModelId: modelID) else { return nil }
        return inspect(directory: directory, modelID: modelID)
    }

    /// Preserve scanner exclusions too: missing tokenizer/config/weights must
    /// not disappear from an audit merely because runtime routing rejects them.
    public static func discoverySources() -> [DiscoverySource] {
        (ExternalModelLocator.lastScanReport()?.sources ?? []).map { source in
            DiscoverySource(root: source.rootPath, source: source.source.rawValue,
                discoveredCount: source.discovered.count,
                skipped: source.skipped.map {
                    RejectedBundle(directory: $0.path, reason: $0.reason.rawValue, detail: $0.detail)
                })
        }
    }

    public static func inspect(directory: URL, modelID: String) -> Bundle {
        let evidence = LocalVisionEvidence.inspect(directory, refresh: true)
        let declaresVision = ["config.json", "config_omni.json"].contains { file in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return ["vision_config", "vision_tokenizer_config"].contains { key in
                (object[key] as? [String: Any]).map { !$0.isEmpty } ?? false
            }
        }
        return Bundle(modelID: modelID, directory: directory.path,
                      modelType: evidence.modelType, declaresVision: declaresVision,
                      supportsImage: evidence.hasVision, reason: evidence.reason,
                      tensorCount: evidence.tensorNames.count)
    }
}
