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
        jangConfig: String? = nil,
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
        if let jangConfig {
            try? Data(jangConfig.utf8).write(
                to: dir.appendingPathComponent("jang_config.json")
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
        #expect(report.toolUse.status == .unproven)
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "unproven"
            }
        )
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
        #expect(report.toolUse.status == .unproven)
        #expect(report.toolUse.title == "Tool use proof required")
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "unproven"
            }
        )
        #expect(
            report.evidence.contains {
                $0.source == "tokenizer_config.json" && $0.key == "chat_template"
                    && $0.value == "present"
            }
        )
        #expect(
            report.evidence.contains {
                $0.source == "generation_config.json" && $0.key == "top_k" && $0.value == "20"
            }
        )
    }

    @Test func bundleWithToolParserMetadata_reportsUnprovenToolUseWithEvidence() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"deepseek_v4","architectures":["DeepseekV4ForCausalLM"]}"#,
            tokenizerConfig: #"{"chat_template":"{{ messages }}"}"#,
            jangConfig: #"{"chat":{"tool_calling":{"parser":"dsml","format":"xml"}}}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/dsv4",
            modelName: "DSV4",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.toolUse.status == .unproven)
        #expect(report.toolUse.detail.contains("dsml"))
        #expect(report.localBundle.config?.toolCalling?.parser == "dsml")
        #expect(
            report.evidence.contains {
                $0.source == "jang_config.json"
                    && $0.key == "chat.tool_calling.parser"
                    && $0.value == "dsml"
            }
        )
        #expect(
            report.evidence.contains {
                $0.source == "tool_use"
                    && $0.key == "status"
                    && $0.value == "unproven"
            }
        )
    }

    @Test func bundleWithRootToolParserMetadata_reportsRootEvidencePath() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}"#,
            tokenizerConfig: #"{"chat_template":"{{ messages }}"}"#,
            jangConfig: #"{"tool_calling":{"parser":"qwen","format":"json"}}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "org/qwen",
            modelName: "Qwen",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.localBundle.config?.toolCalling?.parser == "qwen")
        #expect(
            report.evidence.contains {
                $0.source == "jang_config.json"
                    && $0.key == "tool_calling.parser"
                    && $0.value == "qwen"
            }
        )
    }

    @Test func gemma3nBundle_reportsUnsupportedToolUse() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"gemma3n_text","architectures":["Gemma3nForConditionalGeneration"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "mlx-community/gemma-3n-E2B-it-4bit",
            modelName: "gemma-3n-e2b-it-4bit",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.runtime.kind == .ready)
        #expect(report.toolUse.status == .unsupported)
        #expect(report.toolUse.detail.contains("unsupported"))
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "unsupported"
            }
        )
    }

    @Test func externalGemma3nBundle_reportsUnsupportedToolUse() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config: #"{"model_type":"gemma3n_text","architectures":["Gemma3nForConditionalGeneration"]}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "mlx-community/gemma-3n-E2B-it-4bit",
            modelName: "gemma-3n-e2b-it-4bit",
            modelTypeHint: nil,
            bundleURL: root,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        #expect(report.runtime.kind == .unproven)
        #expect(report.toolUse.status == .unsupported)
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "unsupported"
            }
        )
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
        #expect(report.toolUse.status == .failed)
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "failed"
            }
        )
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
        #expect(report.toolUse.status == .unproven)
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "unproven"
            }
        )
        #expect(report.preflight.blocksRuntimeLoad)
        #expect(report.featureHooks.isEmpty)
        #expect(
            report.evidence.contains {
                $0.source == "generation_config.json" && $0.key == "keys"
                    && $0.value.contains("speculative_decoding")
            }
        )
    }

    @Test func dflashGenerationConfigReference_keepsBaseRuntimeReady() {
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

        #expect(report.runtime.kind == .ready)
        #expect(report.runtime.reason == .localBundleReady)
        #expect(report.preflight.status == .supported)
        #expect(!report.preflight.blocksRuntimeLoad)
        #expect(report.featureHooks.map(\.code).contains(.dflashSpeculativeDecoding))
        #expect(
            report.evidence.contains {
                $0.source == "generation_config.json" && $0.key == "keys"
                    && $0.value.contains("draft")
            }
        )
    }

    @Test func lagunaTargetWithDFlashRecommendation_keepsBaseRuntimeReady() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        writeBundle(
            at: root,
            config:
                #"{"model_type":"laguna","architectures":["LagunaForCausalLM"]}"#,
            generationConfig:
                #"{"speculative_config":{"method":"dflash","model":"poolside/Laguna-S-2.1-DFlash","num_speculative_tokens":15},"max_new_tokens":32768}"#
        )

        let report = ModelCompatibilityDiagnostics.report(
            modelId: "JANGQ-AI/Laguna-S-2.1-JANG_2L",
            modelName: "Laguna S 2.1 JANG_2L",
            modelTypeHint: "laguna",
            bundleURL: root,
            externalSource: nil
        )

        #expect(report.runtime.kind == .ready)
        #expect(report.preflight.status == .supported)
        #expect(!report.preflight.blocksRuntimeLoad)
        #expect(report.localBundle.config?.generation?.hasDFlashReference == true)
        try ModelCompatibilityDiagnostics.validateLoadAllowed(
            report,
            modelName: "Laguna S 2.1 JANG_2L"
        )
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
        #expect(report.toolUse.status == .failed)
        #expect(
            report.evidence.contains {
                $0.source == "tool_use" && $0.key == "status" && $0.value == "failed"
            }
        )
    }
}
