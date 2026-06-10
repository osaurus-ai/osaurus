//
//  ModelCompatibilityDiagnostics.swift
//  osaurus
//
//  User-visible diagnostics for local model discovery and runtime readiness.
//  This is intentionally host-side only: it explains what Osaurus can prove
//  from catalog metadata and local bundle files without rewriting model_type
//  values or pretending vmlx supports an architecture it does not.
//

import Foundation

enum ModelCompatibilityDiagnostics {
    struct Report: Equatable {
        let modelId: String
        let source: SourceStatus
        let localBundle: LocalBundleStatus
        let runtime: RuntimeStatus
        let benchmark: BenchmarkStatus
        let featureHooks: [FeatureHook]

        var primaryTitle: String { runtime.title }
        var primaryDetail: String { runtime.detail }
    }

    struct SourceStatus: Equatable {
        enum Kind: String {
            case catalog
            case osaurusLocal
            case external
        }

        let kind: Kind
        let title: String
        let detail: String?
    }

    struct LocalBundleStatus: Equatable {
        enum Kind: String {
            case notDownloaded
            case available
            case incomplete
        }

        let kind: Kind
        let title: String
        let detail: String?
        let path: String?
        let config: ConfigSummary?
    }

    struct ConfigSummary: Equatable {
        let modelType: String?
        let textModelType: String?
        let architectures: [String]
        let hasVisionConfig: Bool
        let hasJANGConfig: Bool
        let hasJANGTQSidecar: Bool

        var displayModelType: String? {
            modelType ?? textModelType
        }
    }

    struct RuntimeStatus: Equatable {
        enum Kind: String {
            case ready
            case blocked
            case needsDownload
            case unproven
        }

        enum ReasonCode: String {
            case catalogReady
            case localBundleReady
            case externalBundleUnproven
            case needsDownload
            case incompleteBundle
            case unsupportedHunyuanDense
            case unsupportedLongCat
        }

        let kind: Kind
        let reason: ReasonCode
        let title: String
        let detail: String
    }

    struct BenchmarkStatus: Equatable {
        enum Kind: String {
            case notApplicable
            case missingProof
        }

        let kind: Kind
        let title: String
        let detail: String
    }

    struct FeatureHook: Equatable, Identifiable {
        enum Code: String {
            case dflashSpeculativeDecoding
            case tensorParallelism
        }

        let code: Code
        let title: String
        let detail: String
        let issue: Int

        var id: String { code.rawValue }
    }

    static func report(for model: MLXModel) -> Report {
        report(
            modelId: model.id,
            modelName: model.name,
            modelTypeHint: model.modelType,
            bundleURL: model.isDownloaded ? model.localDirectory : nil,
            externalSource: model.externalSource
        )
    }

    static func report(
        modelId: String,
        modelName: String,
        modelTypeHint: String?,
        bundleURL: URL?,
        externalSource: String?
    ) -> Report {
        let source = sourceStatus(
            isLocal: bundleURL != nil,
            externalSource: externalSource
        )
        let localBundle = localBundleStatus(bundleURL: bundleURL)
        let config = localBundle.config
        let runtime = runtimeStatus(
            modelId: modelId,
            modelName: modelName,
            modelTypeHint: modelTypeHint,
            source: source,
            localBundle: localBundle,
            config: config
        )
        let benchmark = benchmarkStatus(runtime: runtime, localBundle: localBundle)
        return Report(
            modelId: modelId,
            source: source,
            localBundle: localBundle,
            runtime: runtime,
            benchmark: benchmark,
            featureHooks: runtime.kind == .blocked ? [] : futureHooks(for: localBundle)
        )
    }

    private static func sourceStatus(isLocal: Bool, externalSource: String?) -> SourceStatus {
        if let externalSource {
            return SourceStatus(
                kind: .external,
                title: externalSource,
                detail: L("Referenced in place; Osaurus does not copy or mutate this bundle.")
            )
        }
        if isLocal {
            return SourceStatus(
                kind: .osaurusLocal,
                title: L("Osaurus local models"),
                detail: L("Stored under the configured Osaurus model directory.")
            )
        }
        return SourceStatus(
            kind: .catalog,
            title: L("Catalog"),
            detail: L("Download or import the bundle before local runtime proof is possible.")
        )
    }

    private static func localBundleStatus(bundleURL: URL?) -> LocalBundleStatus {
        guard let bundleURL else {
            return LocalBundleStatus(
                kind: .notDownloaded,
                title: L("Not local"),
                detail: L("No local bundle is selected for this catalog entry."),
                path: nil,
                config: nil
            )
        }

        let config = readConfigSummary(at: bundleURL)
        let validation = ExternalModelLocator.bundleDiagnostic(
            at: bundleURL,
            root: bundleURL,
            enforceSymlinkContainment: false
        )
        if validation.isValid {
            return LocalBundleStatus(
                kind: .available,
                title: L("Bundle complete"),
                detail: L("config.json, tokenizer assets, and safetensors weights are present."),
                path: bundleURL.path,
                config: config
            )
        }

        return LocalBundleStatus(
            kind: .incomplete,
            title: validation.reason?.title ?? L("Bundle incomplete"),
            detail: validation.detail,
            path: bundleURL.path,
            config: config
        )
    }

    private static func runtimeStatus(
        modelId: String,
        modelName: String,
        modelTypeHint: String?,
        source: SourceStatus,
        localBundle: LocalBundleStatus,
        config: ConfigSummary?
    ) -> RuntimeStatus {
        if let blocker = unsupportedFamilyStatus(
            modelId: modelId,
            modelName: modelName,
            modelTypeHint: modelTypeHint,
            config: config
        ) {
            return blocker
        }

        switch localBundle.kind {
        case .notDownloaded:
            return RuntimeStatus(
                kind: .needsDownload,
                reason: .needsDownload,
                title: L("Download required"),
                detail: L("Osaurus cannot prove runtime behavior until the model bundle is local.")
            )
        case .incomplete:
            return RuntimeStatus(
                kind: .blocked,
                reason: .incompleteBundle,
                title: L("Bundle is incomplete"),
                detail: localBundle.detail ?? L("The local directory does not have the required MLX files.")
            )
        case .available:
            if source.kind == .external {
                return RuntimeStatus(
                    kind: .unproven,
                    reason: .externalBundleUnproven,
                    title: L("External bundle discovered"),
                    detail:
                        L(
                            "The files look loadable, but this specific cache-backed bundle still needs a real generation proof before it should be called validated."
                        )
                )
            }
            return RuntimeStatus(
                kind: .ready,
                reason: .localBundleReady,
                title: L("Local bundle ready"),
                detail:
                    L(
                        "The bundle has the required local files. Runtime quality still depends on model-family support and live generation proof."
                    )
            )
        }
    }

    private static func unsupportedFamilyStatus(
        modelId: String,
        modelName: String,
        modelTypeHint: String?,
        config: ConfigSummary?
    ) -> RuntimeStatus? {
        let modelTypes = [
            modelTypeHint,
            config?.modelType,
            config?.textModelType,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let architectures = config?.architectures.map { $0.lowercased() } ?? []
        let names = [modelId, modelName].map { $0.lowercased() }

        let isHunyuanDense =
            modelTypes.contains("hunyuan_v1_dense")
            || architectures.contains(where: { $0.contains("hunyuan_dense") })
            || architectures.contains(where: { $0.contains("hunyuan") && $0.contains("dense") })
        if isHunyuanDense {
            return RuntimeStatus(
                kind: .blocked,
                reason: .unsupportedHunyuanDense,
                title: L("Unsupported Hunyuan Dense"),
                detail:
                    L(
                        "Unsupported local model type: hunyuan_v1_dense. Osaurus needs vmlx Hunyuan Dense support before this model can run locally."
                    )
            )
        }

        let isLongCat =
            modelTypes.contains(where: { $0.contains("longcat") })
            || architectures.contains(where: { $0.contains("longcat") })
            || names.contains(where: { $0.contains("longcat") })
        if isLongCat {
            return RuntimeStatus(
                kind: .blocked,
                reason: .unsupportedLongCat,
                title: L("Unsupported LongCat family"),
                detail:
                    L(
                        "LongCat local bundles require native vmlx architecture, processor, cache, and media-path support before Osaurus should offer them as runnable."
                    )
            )
        }

        return nil
    }

    private static func benchmarkStatus(
        runtime: RuntimeStatus,
        localBundle: LocalBundleStatus
    ) -> BenchmarkStatus {
        guard localBundle.kind != .notDownloaded else {
            return BenchmarkStatus(
                kind: .notApplicable,
                title: L("No local proof"),
                detail: L("Download or import first, then run a generation proof with token/s.")
            )
        }

        switch runtime.kind {
        case .blocked:
            return BenchmarkStatus(
                kind: .notApplicable,
                title: L("Blocked"),
                detail: L("Benchmark proof is not meaningful until the runtime blocker is resolved.")
            )
        case .ready, .unproven, .needsDownload:
            return BenchmarkStatus(
                kind: .missingProof,
                title: L("Proof missing"),
                detail:
                    L(
                        "No local benchmark proof is recorded here yet. A passing row needs visible output, token/s, RAM status, cancellation, and cache evidence."
                    )
            )
        }
    }

    private static func futureHooks(for localBundle: LocalBundleStatus) -> [FeatureHook] {
        guard localBundle.kind != .notDownloaded else { return [] }
        return [
            FeatureHook(
                code: .dflashSpeculativeDecoding,
                title: L("DFlash speculative decoding"),
                detail:
                    L("Not enabled for local generation yet; needs target/draft validation and benchmark evidence."),
                issue: 1065
            ),
            FeatureHook(
                code: .tensorParallelism,
                title: L("Tensor parallelism"),
                detail:
                    L(
                        "Not enabled in the local runtime; requires an explicit distributed-runtime design and artifact integrity checks."
                    ),
                issue: 833
            ),
        ]
    }

    private static func readConfigSummary(at bundleURL: URL) -> ConfigSummary? {
        let configURL = bundleURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let textConfig = object["text_config"] as? [String: Any]
        let architectures =
            (object["architectures"] as? [Any])?
            .compactMap { $0 as? String } ?? []
        return ConfigSummary(
            modelType: stringValue(object["model_type"]),
            textModelType: stringValue(textConfig?["model_type"]),
            architectures: architectures,
            hasVisionConfig: object["vision_config"] != nil,
            hasJANGConfig: FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("jang_config.json").path
            ),
            hasJANGTQSidecar: FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent("jangtq_runtime.safetensors").path
            )
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
