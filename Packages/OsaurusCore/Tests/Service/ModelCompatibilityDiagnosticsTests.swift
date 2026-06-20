//
//  ModelCompatibilityDiagnosticsTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelCompatibilityDiagnosticsTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-compat-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeBundle(
        at dir: URL,
        config: String = #"{"model_type":"qwen3"}"#,
        tokenizerConfig: String? = nil,
        generationConfig: String? = nil,
        tokenizer: Bool = true,
        weights: Bool = true
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(config.utf8).write(to: dir.appendingPathComponent("config.json"))
        if let tokenizerConfig {
            try? Data(tokenizerConfig.utf8).write(
                to: dir.appendingPathComponent("tokenizer_config.json")
            )
        }
        if let generationConfig {
            try? Data(generationConfig.utf8).write(
                to: dir.appendingPathComponent("generation_config.json")
            )
        }
        if tokenizer {
            try? Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        }
        if weights {
            try? Data("w".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        }
    }

    @Test func externalBundle_reportsUnprovenRuntimeAndMissingProof() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(at: root)

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.source.kind == .external)
        #expect(report.localBundle.kind == .available)
        #expect(report.preflight.status == .unproven)
        #expect(report.preflight.blocksRuntimeLoad == false)
        #expect(report.runtime.reason == .externalBundleUnproven)
        #expect(report.benchmark.kind == .missingProof)
        #expect(report.featureHooks.map(\.code) == [.dflashSpeculativeDecoding, .tensorParallelism])
    }

    @Test func externalBundleDiagnostic_acceptsHFCacheBlobSymlinks() {
        let cacheRoot = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let fm = FileManager.default
        let blobs = cacheRoot.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = cacheRoot.appendingPathComponent("models--org--repo/snapshots/rev", isDirectory: true)
        try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: snapshot, withIntermediateDirectories: true)

        let configBlob = blobs.appendingPathComponent("config")
        let tokenizerBlob = blobs.appendingPathComponent("tokenizer")
        let weightsBlob = blobs.appendingPathComponent("weights")
        try? Data(#"{"model_type":"qwen3"}"#.utf8).write(to: configBlob)
        try? Data("{}".utf8).write(to: tokenizerBlob)
        try? Data("w".utf8).write(to: weightsBlob)
        try? fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("config.json"),
            withDestinationURL: configBlob
        )
        try? fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("tokenizer.json"),
            withDestinationURL: tokenizerBlob
        )
        try? fm.createSymbolicLink(
            at: snapshot.appendingPathComponent("model.safetensors"),
            withDestinationURL: weightsBlob
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: nil,
            bundleURL: snapshot,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.localBundle.kind == .available)
        #expect(report.runtime.reason == .externalBundleUnproven)
    }

    @Test func supportedLocalBundle_reportsSupportedPreflightWithEvidence() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}"#,
            tokenizerConfig:
                #"{"tokenizer_class":"Qwen2Tokenizer","model_max_length":32768,"chat_template":"{{ messages }}","eos_token":"<|end|>"}"#,
            generationConfig: #"{"top_k":20,"max_new_tokens":4096}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/qwen",
            modelName: "qwen",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.preflight.status == .supported)
        #expect(report.preflight.reason == .localBundleReady)
        #expect(report.preflight.blocksRuntimeLoad == false)
        #expect(report.evidence.contains {
            $0.source == "tokenizer_config.json" && $0.key == "chat_template"
                && $0.value == "present"
        })
        #expect(report.evidence.contains {
            $0.source == "generation_config.json" && $0.key == "top_k" && $0.value == "20"
        })
    }

    @Test func hunyuanDenseConfig_reportsUnsupportedFamily() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config:
                #"{"model_type":"hunyuan_v1_dense","architectures":["HunYuanDenseV1ForCausalLM"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "mlx-community/HY-MT1.5-7B-bf16",
            modelName: "HY-MT1.5",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.runtime.kind == .blocked)
        #expect(report.runtime.reason == .unsupportedHunyuanDense)
        #expect(report.preflight.status == .unsupported)
        #expect(report.preflight.blocksRuntimeLoad)
        #expect(report.benchmark.kind == .notApplicable)
    }

    @Test func hunyuanDenseArchitecture_reportsUnsupportedFamily() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"architectures":["HunYuanDenseV1ForCausalLM"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "mlx-community/HY-MT1.5-7B-bf16",
            modelName: "HY-MT1.5",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.runtime.kind == .blocked)
        #expect(report.runtime.reason == .unsupportedHunyuanDense)
        #expect(report.preflight.status == .unsupported)
    }

    @Test func longCatConfig_reportsUnsupportedFamily() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"longcat_next","architectures":["LongCatFlashForConditionalGeneration"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "meituan-longcat/LongCat-Next",
            modelName: "LongCat Next",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.runtime.kind == .blocked)
        #expect(report.runtime.reason == .unsupportedLongCat)
        #expect(report.preflight.status == .unsupported)
        #expect(report.preflight.blocksRuntimeLoad)
    }

    @Test func dflashConfig_reportsPartialAndBlocksRuntimeLoad() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config:
                #"{"model_type":"dflash","architectures":["DFlashForCausalLM"]}"#,
            tokenizerConfig: #"{"tokenizer_class":"DFlashTokenizer","chat_template":"{{ messages }}"}"#,
            generationConfig:
                #"{"speculative_decoding":{"method":"dflash","draft_model":"org/draft"},"max_new_tokens":512}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/dflash-target",
            modelName: "DFlash Target",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.runtime.kind == .partial)
        #expect(report.runtime.reason == .partialDFlashSpeculativeDecoding)
        #expect(report.preflight.status == .partial)
        #expect(report.preflight.blocksRuntimeLoad)
        #expect(report.featureHooks.isEmpty)
        #expect(report.evidence.contains {
            $0.source == "generation_config.json" && $0.key == "keys"
                && $0.value.contains("speculative_decoding")
        })
    }

    @Test func dflashGenerationConfigReference_reportsPartialEvenWhenModelTypeIsGeneric() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}"#,
            generationConfig: #"{"draft":{"method":"dflash","max_draft_tokens":4}}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/speculative",
            modelName: "Speculative",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.runtime.kind == .partial)
        #expect(report.runtime.reason == .partialDFlashSpeculativeDecoding)
    }

    @Test func validateLoadAllowedThrowsForPartialAndUnsupportedReports() {
        let partialRoot = makeTempDir()
        let unsupportedRoot = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: partialRoot)
            try? FileManager.default.removeItem(at: unsupportedRoot)
        }
        writeBundle(
            at: partialRoot,
            config: #"{"model_type":"dflash","architectures":["DFlashForCausalLM"]}"#
        )
        writeBundle(
            at: unsupportedRoot,
            config: #"{"model_type":"longcat_next"}"#
        )

        let partial = ModelCompatibilityDiagnostics.report(
            modelId: "org/dflash",
            modelName: "DFlash",
            modelTypeHint: nil,
            bundleURL: partialRoot,
            externalSource: nil
        )
        let unsupported = ModelCompatibilityDiagnostics.report(
            modelId: "org/longcat",
            modelName: "LongCat",
            modelTypeHint: nil,
            bundleURL: unsupportedRoot,
            externalSource: nil
        )

        #expect(throws: ModelCompatibilityDiagnostics.PreflightError.self) {
            try ModelCompatibilityDiagnostics.validateLoadAllowed(partial, modelName: "DFlash")
        }
        #expect(throws: ModelCompatibilityDiagnostics.PreflightError.self) {
            try ModelCompatibilityDiagnostics.validateLoadAllowed(unsupported, modelName: "LongCat")
        }
    }

    @Test func catalogEntryWithoutBundle_reportsDownloadRequired() {
        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: "qwen3",
            bundleURL: nil,
            externalSource: nil
        )

        #expect(report.source.kind == .catalog)
        #expect(report.localBundle.kind == .notDownloaded)
        #expect(report.runtime.reason == .needsDownload)
        #expect(report.benchmark.kind == .notApplicable)
        #expect(report.featureHooks.isEmpty)
    }

    @Test func incompleteBundle_reportsRuntimeBlocker() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(at: root, weights: false)

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/repo",
            modelName: "Repo",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.localBundle.kind == .incomplete)
        #expect(report.localBundle.title == "Safetensors missing")
        #expect(report.runtime.reason == .incompleteBundle)
    }
}
