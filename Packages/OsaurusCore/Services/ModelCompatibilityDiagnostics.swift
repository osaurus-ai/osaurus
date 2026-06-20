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
        let preflight: PreflightStatus
        let benchmark: BenchmarkStatus
        let featureHooks: [FeatureHook]
        let evidence: [Evidence]

        var primaryTitle: String { preflight.title }
        var primaryDetail: String { preflight.detail }
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
        let tokenizer: TokenizerSummary?
        let generation: GenerationSummary?

        var displayModelType: String? {
            modelType ?? textModelType
        }
    }

    struct TokenizerSummary: Equatable {
        let tokenizerClass: String?
        let modelMaxLength: Int?
        let chatTemplatePresent: Bool
        let specialTokenKeys: [String]
        let hasDFlashReference: Bool
    }

    struct GenerationSummary: Equatable {
        let keys: [String]
        let maxNewTokens: Int?
        let topK: Int?
        let hasDFlashReference: Bool
    }

    struct RuntimeStatus: Equatable {
        enum Kind: String {
            case ready
            case blocked
            case partial
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
            case partialDFlashSpeculativeDecoding
        }

        let kind: Kind
        let reason: ReasonCode
        let title: String
        let detail: String
    }

    struct PreflightStatus: Equatable {
        enum Status: String {
            case supported
            case partial
            case unsupported
            case unproven
        }

        let status: Status
        let reason: RuntimeStatus.ReasonCode
        let title: String
        let detail: String

        var blocksRuntimeLoad: Bool {
            status == .unsupported || status == .partial
        }
    }

    struct Evidence: Equatable, Identifiable {
        let source: String
        let key: String
        let value: String

        var id: String { "\(source):\(key):\(value)" }
    }

    struct PreflightError: LocalizedError, Sendable, Equatable {
        let modelId: String
        let modelName: String
        let status: String
        let reason: String
        let title: String
        let detail: String
        let evidence: [String]

        var errorDescription: String? {
            var message = "\(title): \(detail)"
            if !evidence.isEmpty {
                message += " Evidence: \(evidence.joined(separator: "; "))"
            }
            return message
        }
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
        let evidence = evidenceRows(
            modelId: modelId,
            modelName: modelName,
            modelTypeHint: modelTypeHint,
            source: source,
            localBundle: localBundle,
            config: config
        )
        let preflight = preflightStatus(runtime: runtime)
        let benchmark = benchmarkStatus(runtime: runtime, localBundle: localBundle)
        return Report(
            modelId: modelId,
            source: source,
            localBundle: localBundle,
            runtime: runtime,
            preflight: preflight,
            benchmark: benchmark,
            featureHooks: runtime.kind == .blocked || runtime.kind == .partial
                ? []
                : futureHooks(for: localBundle),
            evidence: evidence
        )
    }

    static func validateLoadAllowed(_ report: Report, modelName: String) throws {
        guard report.preflight.blocksRuntimeLoad else { return }
        throw PreflightError(
            modelId: report.modelId,
            modelName: modelName,
            status: report.preflight.status.rawValue,
            reason: report.preflight.reason.rawValue,
            title: report.preflight.title,
            detail: report.preflight.detail,
            evidence: report.evidence.map { "\($0.source).\($0.key)=\($0.value)" }
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

    private static func preflightStatus(runtime: RuntimeStatus) -> PreflightStatus {
        let status: PreflightStatus.Status
        switch runtime.kind {
        case .ready:
            status = .supported
        case .partial:
            status = .partial
        case .blocked:
            status = .unsupported
        case .needsDownload, .unproven:
            status = .unproven
        }
        return PreflightStatus(
            status: status,
            reason: runtime.reason,
            title: runtime.title,
            detail: runtime.detail
        )
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

        if isDFlashStyleBundle(modelTypes: modelTypes, architectures: architectures, config: config, names: names) {
            return RuntimeStatus(
                kind: .partial,
                reason: .partialDFlashSpeculativeDecoding,
                title: L("DFlash speculative decoding incomplete"),
                detail:
                    L(
                        "This bundle advertises DFlash/speculative-decoding metadata, but local generation has no target/draft acceptance contract or benchmark proof yet. Use it only after native runtime support lands."
                    )
            )
        }

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

    private static func isDFlashStyleBundle(
        modelTypes: [String],
        architectures: [String],
        config: ConfigSummary?,
        names: [String]
    ) -> Bool {
        let directHints =
            modelTypes.contains(where: isDFlashToken)
            || architectures.contains(where: isDFlashToken)
            || names.contains(where: isDFlashToken)
        if directHints { return true }

        if config?.tokenizer?.hasDFlashReference == true { return true }
        if config?.generation?.hasDFlashReference == true { return true }
        return false
    }

    private static func isDFlashToken(_ value: String) -> Bool {
        let normalized =
            value
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return normalized == "dflash"
            || normalized.contains("_dflash")
            || normalized.contains("dflash_")
            || normalized.contains("d_flash")
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
        case .blocked, .partial:
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

    private static func evidenceRows(
        modelId: String,
        modelName: String,
        modelTypeHint: String?,
        source: SourceStatus,
        localBundle: LocalBundleStatus,
        config: ConfigSummary?
    ) -> [Evidence] {
        var rows: [Evidence] = [
            Evidence(source: "model", key: "id", value: modelId),
            Evidence(source: "model", key: "name", value: modelName),
            Evidence(source: "source", key: "kind", value: source.kind.rawValue),
            Evidence(source: "bundle", key: "status", value: localBundle.kind.rawValue),
        ]
        if let path = localBundle.path {
            rows.append(Evidence(source: "bundle", key: "path", value: path))
        }
        if let modelTypeHint {
            rows.append(Evidence(source: "catalog", key: "model_type", value: modelTypeHint))
        }
        guard let config else { return rows }

        appendOptional(&rows, source: "config.json", key: "model_type", value: config.modelType)
        appendOptional(
            &rows,
            source: "config.json",
            key: "text_config.model_type",
            value: config.textModelType
        )
        if !config.architectures.isEmpty {
            rows.append(
                Evidence(
                    source: "config.json",
                    key: "architectures",
                    value: config.architectures.joined(separator: ", ")
                )
            )
        }
        rows.append(
            Evidence(
                source: "config.json",
                key: "vision_config",
                value: config.hasVisionConfig ? "present" : "absent"
            )
        )
        rows.append(
            Evidence(
                source: "jang_config.json",
                key: "file",
                value: config.hasJANGConfig ? "present" : "absent"
            )
        )
        rows.append(
            Evidence(
                source: "jangtq_runtime.safetensors",
                key: "file",
                value: config.hasJANGTQSidecar ? "present" : "absent"
            )
        )

        if let tokenizer = config.tokenizer {
            appendOptional(
                &rows,
                source: "tokenizer_config.json",
                key: "tokenizer_class",
                value: tokenizer.tokenizerClass
            )
            if let maxLength = tokenizer.modelMaxLength {
                rows.append(
                    Evidence(
                        source: "tokenizer_config.json",
                        key: "model_max_length",
                        value: "\(maxLength)"
                    )
                )
            }
            rows.append(
                Evidence(
                    source: "tokenizer_config.json",
                    key: "chat_template",
                    value: tokenizer.chatTemplatePresent ? "present" : "absent"
                )
            )
            if !tokenizer.specialTokenKeys.isEmpty {
                rows.append(
                    Evidence(
                        source: "tokenizer_config.json",
                        key: "special_tokens",
                        value: tokenizer.specialTokenKeys.joined(separator: ", ")
                    )
                )
            }
        }

        if let generation = config.generation {
            if !generation.keys.isEmpty {
                rows.append(
                    Evidence(
                        source: "generation_config.json",
                        key: "keys",
                        value: generation.keys.joined(separator: ", ")
                    )
                )
            }
            if let maxNewTokens = generation.maxNewTokens {
                rows.append(
                    Evidence(
                        source: "generation_config.json",
                        key: "max_new_tokens",
                        value: "\(maxNewTokens)"
                    )
                )
            }
            if let topK = generation.topK {
                rows.append(
                    Evidence(source: "generation_config.json", key: "top_k", value: "\(topK)")
                )
            }
        }
        return rows
    }

    private static func appendOptional(
        _ rows: inout [Evidence],
        source: String,
        key: String,
        value: String?
    ) {
        guard let value else { return }
        rows.append(Evidence(source: source, key: key, value: value))
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
            ),
            tokenizer: readTokenizerSummary(at: bundleURL),
            generation: readGenerationSummary(at: bundleURL)
        )
    }

    private static func readTokenizerSummary(at bundleURL: URL) -> TokenizerSummary? {
        let url = bundleURL.appendingPathComponent("tokenizer_config.json")
        guard let object = readJSONObject(at: url) else { return nil }
        let specialTokenKeys = object.keys.filter { key in
            key.hasSuffix("_token") || key.hasSuffix("_token_id")
        }.sorted()
        return TokenizerSummary(
            tokenizerClass: stringValue(object["tokenizer_class"]),
            modelMaxLength: intValue(object["model_max_length"]),
            chatTemplatePresent: stringValue(object["chat_template"]) != nil
                || object["chat_template"] is [Any]
                || object["chat_template"] is [String: Any],
            specialTokenKeys: specialTokenKeys,
            hasDFlashReference: containsDFlashReference(object)
        )
    }

    private static func readGenerationSummary(at bundleURL: URL) -> GenerationSummary? {
        let url = bundleURL.appendingPathComponent("generation_config.json")
        guard let object = readJSONObject(at: url) else { return nil }
        return GenerationSummary(
            keys: object.keys.sorted(),
            maxNewTokens: intValue(object["max_new_tokens"]),
            topK: intValue(object["top_k"]),
            hasDFlashReference: containsDFlashReference(object)
        )
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = stringValue(value) { return Int(string) }
        return nil
    }

    private static func containsDFlashReference(_ value: Any) -> Bool {
        if let string = value as? String {
            return isDFlashToken(string)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsDFlashReference)
        }
        if let object = value as? [String: Any] {
            return object.contains { key, nested in
                isDFlashToken(key) || containsDFlashReference(nested)
            }
        }
        return false
    }
}
