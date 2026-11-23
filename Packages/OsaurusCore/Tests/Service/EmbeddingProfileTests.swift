//
//  EmbeddingProfileTests.swift
//  osaurus
//
//  Resolution of Model Defaults → Embedding Model into a runnable profile,
//  the per-profile index bookkeeping, and the transformer backend's pure
//  helpers. Bundle fixtures are config files plus placeholder weights; no
//  MLX work runs here.
//

import Foundation
import Testing
import VecturaKit

@testable import OsaurusCore

@Suite(.serialized)
struct EmbeddingProfileTests {

    // MARK: - Resolution

    @Test(arguments: [nil, "minishlab/potion-base-4M", "potion-base-4M", "MINISHLAB/POTION-BASE-4M"] as [String?])
    func builtInSelectionResolvesToBuiltIn(_ id: String?) throws {
        let result = EmbeddingProfileResolver.resolve(
            settings: EmbeddingSettings(selectedModelId: id),
            locate: { _ in nil }
        )
        #expect(try result.get() == .builtIn)
    }

    @Test func missingBundleIsATypedFailure() {
        let id = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
        let result = EmbeddingProfileResolver.resolve(
            settings: EmbeddingSettings(selectedModelId: id, selectedModelPath: "/nonexistent/\(UUID())"),
            locate: { _ in nil }
        )
        #expect(result == .failure(.modelNotInstalled(modelId: id)))
    }

    @Test func storedPathWinsOverLocator() throws {
        let stored = try Fixture.bundle(config: Fixture.bertConfig)
        let located = try Fixture.bundle(config: Fixture.qwen3Config)
        defer { Fixture.remove(stored, located) }
        let profile = try EmbeddingProfileResolver.resolve(
            settings: EmbeddingSettings(selectedModelId: "BAAI/bge-small-en-v1.5", selectedModelPath: stored.path),
            locate: { _ in located }
        ).get()
        #expect(profile.directory?.standardizedFileURL == stored.standardizedFileURL)
        #expect(profile.modelType == "bert")
    }

    @Test func locatorIsUsedWhenStoredPathIsGone() throws {
        let located = try Fixture.bundle(config: Fixture.bertConfig)
        defer { Fixture.remove(located) }
        let profile = try EmbeddingProfileResolver.resolve(
            settings: EmbeddingSettings(selectedModelId: "BAAI/bge-small-en-v1.5", selectedModelPath: "/gone"),
            locate: { _ in located }
        ).get()
        #expect(profile.directory?.standardizedFileURL == located.standardizedFileURL)
    }

    @Test func qwen3UsesLastTokenPoolingCatalogPrefixesAndTheSequenceCap() throws {
        let id = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
        let dir = try Fixture.bundle(config: Fixture.qwen3Config)
        defer { Fixture.remove(dir) }
        let entry = try #require(EmbeddingModelCatalog.entry(for: id))
        let profile = try EmbeddingProfileResolver.profile(modelId: id, directory: dir, catalogEntry: entry).get()

        #expect(profile.backend == .transformer)
        #expect(profile.modelType == "qwen3")
        #expect(profile.pooling == .lastToken)
        #expect(profile.dimension == 1024)
        #expect(profile.maxSequenceLength == EmbeddingProfileResolver.maxSequenceCap)
        #expect(profile.queryPrefix == entry.queryPrefix)
        #expect(profile.documentPrefix == "")
        #expect(profile.positionOffset == 0)
        #expect(profile.weightBytes == Int64(Fixture.weights.count))
        #expect(profile.layerCount == 28)
        #expect(profile.headCount == 16)
    }

    @Test func bundlePromptsOverrideCatalogPrefixes() throws {
        let id = "intfloat/multilingual-e5-small"
        let dir = try Fixture.bundle(
            config: #"{"model_type": "xlm-roberta", "hidden_size": 384, "max_position_embeddings": 514}"#,
            extra: [
                "config_sentence_transformers.json": #"{"prompts": {"query": "q: ", "document": "d: "}}"#
            ]
        )
        defer { Fixture.remove(dir) }
        let entry = try #require(EmbeddingModelCatalog.entry(for: id))
        #expect(entry.queryPrefix != "q: ")
        let profile = try EmbeddingProfileResolver.profile(modelId: id, directory: dir, catalogEntry: entry).get()

        #expect(profile.queryPrefix == "q: ")
        #expect(profile.documentPrefix == "d: ")
        #expect(profile.prefix(for: .query) == "q: ")
        #expect(profile.prefix(for: .document) == "d: ")
        #expect(profile.prefix(for: .raw) == "")
    }

    @Test(arguments: ["gemma3_text", "gemma3", "nomic_bert"])
    func registryTypesThatCannotLoadAreRefused(_ modelType: String) throws {
        let dir = try Fixture.bundle(config: #"{"model_type": "\#(modelType)", "hidden_size": 768}"#)
        defer { Fixture.remove(dir) }
        #expect(!EmbeddingDetection.runtimeSupport(at: dir).isSupported)
        let result = EmbeddingProfileResolver.profile(modelId: "x/\(modelType)", directory: dir, catalogEntry: nil)
        guard case .failure(.unsupportedModel) = result else {
            Issue.record("Expected unsupportedModel for \(modelType), got \(result)")
            return
        }
    }

    @Test func declaredClsPoolingIsFirstToken() throws {
        let dir = try Fixture.bundle(
            config: Fixture.bertConfig,
            extra: [
                "1_Pooling/config.json": #"{"pooling_mode_cls_token": true, "pooling_mode_mean_tokens": false}"#,
                "sentence_bert_config.json": #"{"max_seq_length": 256}"#,
            ]
        )
        defer { Fixture.remove(dir) }
        let profile = try EmbeddingProfileResolver.profile(modelId: "BAAI/bge-small-en-v1.5", directory: dir, catalogEntry: nil)
            .get()
        #expect(profile.pooling == .firstToken)
        #expect(profile.maxSequenceLength == 256)
    }

    @Test func undeclaredBertPoolingIsMean() throws {
        let dir = try Fixture.bundle(config: Fixture.bertConfig)
        defer { Fixture.remove(dir) }
        let profile = try EmbeddingProfileResolver.profile(modelId: "x/bert", directory: dir, catalogEntry: nil).get()
        #expect(profile.pooling == .mean)
        #expect(profile.maxSequenceLength == 512)
    }

    @Test func robertaFamilyPositionsStartAfterThePadToken() throws {
        let dir = try Fixture.bundle(
            config: #"{"model_type": "xlm-roberta", "hidden_size": 384, "max_position_embeddings": 514, "pad_token_id": 1}"#
        )
        defer { Fixture.remove(dir) }
        let profile = try EmbeddingProfileResolver.profile(
            modelId: "intfloat/multilingual-e5-small", directory: dir, catalogEntry: nil
        ).get()
        #expect(profile.positionOffset == 2)
        #expect(profile.maxSequenceLength == 512)
    }

    @Test func model2VecBundleUsesTheStaticBackend() throws {
        let dir = try Fixture.bundle(config: #"{"model_type": "model2vec", "hidden_dim": 256}"#)
        defer { Fixture.remove(dir) }
        let profile = try EmbeddingProfileResolver.profile(modelId: "minishlab/potion-base-8M", directory: dir, catalogEntry: nil)
            .get()
        #expect(profile.backend == .model2vec)
        #expect(profile.dimension == 256)
        #expect(!profile.isBuiltIn)
    }

    @Test func unsupportedBundlesFailWithAReason() throws {
        let cases: [(config: String, files: [String: String], weights: Bool)] = [
            (#"{"model_type": "t5", "d_model": 512}"#, [:], true),
            (#"{"model_type": "qwen3", "hidden_size": 1024, "vision_config": {}}"#, [:], true),
            (Fixture.bertConfig, [:], false),
        ]
        for testCase in cases {
            let dir = try Fixture.bundle(config: testCase.config, extra: testCase.files, weights: testCase.weights)
            defer { Fixture.remove(dir) }
            let result = EmbeddingProfileResolver.profile(modelId: "x/model", directory: dir, catalogEntry: nil)
            guard case .failure(.unsupportedModel(let id, let reason)) = result else {
                Issue.record("Expected unsupportedModel for \(testCase.config), got \(result)")
                continue
            }
            #expect(id == "x/model")
            #expect(!reason.isEmpty)
        }
    }

    @Test func bundleWithoutTokenizerIsUnsupported() throws {
        let dir = try Fixture.bundle(config: Fixture.bertConfig, tokenizer: false)
        defer { Fixture.remove(dir) }
        let result = EmbeddingProfileResolver.profile(modelId: "x/bert", directory: dir, catalogEntry: nil)
        guard case .failure(.unsupportedModel) = result else {
            Issue.record("Expected unsupportedModel, got \(result)")
            return
        }
    }

    // MARK: - Profile identity

    @Test func builtInKeepsTheOriginalIndexDirectory() {
        #expect(EmbeddingProfile.builtIn.indexDirectoryName == "vectura")
        #expect(EmbeddingProfile.builtIn.apiName == "potion-base-4M")
    }

    @Test func otherProfilesGetTheirOwnIndexDirectory() {
        let profile = EmbeddingProfile(
            modelId: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            backend: .transformer,
            dimension: 1024,
            modelType: "qwen3",
            pooling: .lastToken,
            directory: nil
        )
        #expect(profile.indexDirectoryName == "vectura-mlx-community-qwen3-embedding-0-6b-4bit-dwq-1024")
        #expect(profile.apiName == "Qwen3-Embedding-0.6B-4bit-DWQ")
    }

    @Test func builtInIdMatching() {
        #expect(EmbeddingProfile.isBuiltInId("minishlab/potion-base-4M"))
        #expect(EmbeddingProfile.isBuiltInId("Potion-Base-4M"))
        #expect(!EmbeddingProfile.isBuiltInId("minishlab/potion-base-8M"))
        #expect(!EmbeddingProfile.isBuiltInId("other/potion-base-4M"))
    }

    // MARK: - Bundle metadata

    @Test func poolingModeStringsAndFlags() {
        #expect(EmbeddingBundleInfo.pooling(from: ["pooling_mode": "cls"]) == .firstToken)
        #expect(EmbeddingBundleInfo.pooling(from: ["pooling_mode": "lasttoken"]) == .lastToken)
        #expect(EmbeddingBundleInfo.pooling(from: ["pooling_mode_max_tokens": true]) == .max)
        #expect(EmbeddingBundleInfo.pooling(from: ["pooling_mode_lasttoken": true]) == .lastToken)
        #expect(EmbeddingBundleInfo.pooling(from: ["pooling_mode_mean_tokens": false]) == nil)
    }

    @Test func promptKeyAliases() throws {
        let dir = try Fixture.bundle(
            config: Fixture.bertConfig,
            extra: [
                "config_sentence_transformers.json": #"{"prompts": {"search_query": "q: ", "passage": "p: "}}"#
            ]
        )
        defer { Fixture.remove(dir) }
        let info = try #require(EmbeddingBundleInfo.read(at: dir))
        #expect(info.prompt(for: .query) == "q: ")
        #expect(info.prompt(for: .document) == "p: ")
        #expect(info.prompt(for: .raw) == nil)
        #expect(info.hasSentenceTransformersMarkers)
    }

    // MARK: - Detection

    @Test func runtimeSupportByModelType() throws {
        let qwen = try Fixture.bundle(config: Fixture.qwen3Config)
        let t5 = try Fixture.bundle(config: #"{"model_type": "t5"}"#)
        let staticModel = try Fixture.bundle(config: #"{"model_type": "model2vec", "hidden_dim": 64}"#)
        defer { Fixture.remove(qwen, t5, staticModel) }
        #expect(EmbeddingDetection.runtimeSupport(at: qwen) == .transformer(modelType: "qwen3"))
        #expect(EmbeddingDetection.runtimeSupport(at: staticModel) == .model2vec)
        #expect(!EmbeddingDetection.runtimeSupport(at: t5).isSupported)
    }

    @Test func sentenceTransformersLayoutMarksADecoderAsEmbedding() throws {
        let marked = try Fixture.bundle(
            config: Fixture.qwen3Config, extra: ["modules.json": "[]"])
        let plain = try Fixture.bundle(config: Fixture.qwen3Config)
        defer { Fixture.remove(marked, plain) }
        #expect(EmbeddingDetection.isEmbedding(at: marked))
        #expect(!EmbeddingDetection.isEmbedding(at: plain))
    }

    @Test func curatedIdsAreEmbeddingModelsWithoutSentenceTransformersFiles() {
        let model = MLXModel(
            id: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            name: "Qwen3 Embedding",
            description: "",
            downloadURL: ""
        )
        #expect(model.isEmbedding)
    }

    @Test func completedEmbeddingDownloadsAreJudgedByTheEmbeddingEngine() throws {
        let bert = try Fixture.bundle(config: Fixture.bertConfig, extra: ["modules.json": "[]"])
        let gemma = try Fixture.bundle(
            config: #"{"model_type": "gemma3_text", "architectures": ["Gemma3TextModel"], "hidden_size": 768}"#,
            extra: ["modules.json": "[]"])
        defer { Fixture.remove(bert, gemma) }
        func model(_ directory: URL) -> MLXModel {
            MLXModel(
                id: "fixture/\(directory.lastPathComponent)", name: "Fixture", description: "", downloadURL: "",
                bundleDirectory: directory)
        }

        #expect(ModelDownloadService.postDownloadCompatibilityIssue(for: model(bert)) == nil)
        let refusal = try #require(ModelDownloadService.postDownloadCompatibilityIssue(for: model(gemma)))
        #expect(refusal.contains("Embedding model not supported"))
        #expect(refusal.contains("EmbeddingGemma"))
    }

    // MARK: - Catalog

    @Test func catalogStartsWithTheBuiltInAndHasUniqueIds() {
        let curated = EmbeddingModelCatalog.curated
        #expect(curated.first?.isBuiltIn == true)
        #expect(curated.filter(\.isBuiltIn).count == 1)
        #expect(Set(curated.map { $0.id.lowercased() }).count == curated.count)
        #expect(curated.contains { $0.isTopPick })
        #expect(curated.allSatisfy { $0.dimension > 0 && $0.downloadSizeBytes > 0 })
    }

    @Test func hubListingFilter() {
        #expect(EmbeddingModelCatalog.isEmbeddingListing(pipelineTag: "feature-extraction", tags: []))
        #expect(EmbeddingModelCatalog.isEmbeddingListing(pipelineTag: "sentence-similarity", tags: []))
        #expect(EmbeddingModelCatalog.isEmbeddingListing(pipelineTag: nil, tags: ["sentence-transformers"]))
        #expect(!EmbeddingModelCatalog.isEmbeddingListing(pipelineTag: "text-generation", tags: ["mlx"]))
    }

    // MARK: - Settings and index state

    @Test func savingTheBuiltInStoresTheDefault() throws {
        _ = EmbeddingService.launchState
        let dir = try Fixture.directory()
        EmbeddingSettingsStore.setOverrideDirectory(dir)
        defer {
            EmbeddingSettingsStore.setOverrideDirectory(nil)
            Fixture.remove(dir)
        }
        EmbeddingSettingsStore.save(EmbeddingSettings(selectedModelId: "BAAI/bge-small-en-v1.5", selectedModelPath: "/m"))
        #expect(EmbeddingSettingsStore.snapshot().selectedModelId == "BAAI/bge-small-en-v1.5")
        #expect(EmbeddingSettingsStore.snapshot().selectedModelPath == "/m")

        EmbeddingSettingsStore.save(EmbeddingSettings(selectedModelId: "potion-base-4M", selectedModelPath: "/x"))
        #expect(EmbeddingSettingsStore.snapshot() == .default)
        #expect(EmbeddingSettingsStore.snapshot().effectiveModelId == EmbeddingProfile.builtInModelId)
    }

    @Test func indexStateTracksRebuilds() throws {
        let dir = try Fixture.directory()
        EmbeddingIndexStateStore.setOverrideDirectory(dir)
        defer {
            EmbeddingIndexStateStore.setOverrideDirectory(nil)
            Fixture.remove(dir)
        }
        let qwen = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
        #expect(!EmbeddingIndexStateStore.needsRebuild(.memory, modelId: EmbeddingProfile.builtInModelId))
        #expect(EmbeddingIndexStateStore.needsRebuild(.memory, modelId: qwen))

        EmbeddingIndexStateStore.markRebuilding(.memory, modelId: qwen)
        #expect(EmbeddingIndexStateStore.needsRebuild(.memory, modelId: qwen))

        EmbeddingIndexStateStore.markComplete(.memory, modelId: qwen)
        #expect(!EmbeddingIndexStateStore.needsRebuild(.memory, modelId: qwen))
        #expect(EmbeddingIndexStateStore.needsRebuild(.tools, modelId: qwen))
        #expect(EmbeddingIndexStateStore.needsRebuild(.memory, modelId: EmbeddingProfile.builtInModelId))
    }

    // MARK: - Embedders

    @Test func unavailableEmbedderThrowsTheLaunchError() async {
        let error = EmbeddingProfileError.modelNotInstalled(modelId: "x/missing")
        let embedder = EmbeddingService.makeEmbedder(
            for: EmbeddingLaunchState(requestedModelId: "x/missing", result: .failure(error)))
        await #expect(throws: EmbeddingProfileError.self) {
            _ = try await embedder.embed(texts: ["hello"])
        }
        await #expect(throws: EmbeddingProfileError.self) {
            _ = try await embedder.dimension
        }
    }

    @Test func gateHoldsAreChunkedAndOrderIsKept() async throws {
        let inner = RecordingEmbedder()
        let embedder = MetalSafeEmbedder(inner: inner, maxTextsPerGateHold: 2)
        let texts = ["a", "bb", "ccc", "dddd", "eeeee"]
        let vectors = try await embedder.embed(texts: texts)
        #expect(vectors.map { Int($0[0]) } == [1, 2, 3, 4, 5])
        #expect(await inner.batchSizes == [2, 2, 1])
    }

    @Test func batchesRespectTokenAndAttentionBudgets() {
        let lengths = [512, 0, 10, 512, 10, 512, 10]
        let batches = VMLXTransformerEmbedder.batches(lengths: lengths, tokenBudget: 2048, attentionBudget: 512 * 512 * 2)
        #expect(batches.flatMap { $0 }.sorted() == [0, 2, 3, 4, 5, 6])
        for batch in batches {
            let longest = batch.map { lengths[$0] }.max() ?? 0
            #expect(batch.count == 1 || longest * batch.count <= 2048)
            #expect(batch.count == 1 || longest * longest * batch.count <= 512 * 512 * 2)
        }
        #expect(batches.first == [2, 4, 6])
        #expect(VMLXTransformerEmbedder.batches(lengths: [9000], tokenBudget: 2048, attentionBudget: 1) == [[0]])
    }

    @Test func batchBudgetShrinksWithDepthAndWidth() {
        func profile(layers: Int, hidden: Int, heads: Int) -> EmbeddingProfile {
            EmbeddingProfile(
                modelId: "x/m", backend: .transformer, dimension: hidden, modelType: "bert", pooling: .mean,
                directory: nil, layerCount: layers, headCount: heads)
        }
        let small = VMLXTransformerEmbedder.batchBudget(for: profile(layers: 6, hidden: 384, heads: 12))
        let large = VMLXTransformerEmbedder.batchBudget(for: profile(layers: 24, hidden: 1024, heads: 16))
        let huge = VMLXTransformerEmbedder.batchBudget(for: profile(layers: 36, hidden: 4096, heads: 32))
        #expect(small.tokens > large.tokens)
        #expect(small.attentionCells > large.attentionCells)
        #expect(huge.tokens == 512)
        #expect(small.tokens <= 8192)
    }

    @Test func truncationKeepsTrailingSpecialTokens() {
        let tokens = [101, 1, 2, 3, 4, 5, 102]
        #expect(VMLXTransformerEmbedder.truncate(tokens, to: 4, keepingLast: 1) == [101, 1, 2, 102])
        #expect(VMLXTransformerEmbedder.truncate(tokens, to: 10, keepingLast: 1) == tokens)
        #expect(VMLXTransformerEmbedder.truncate(tokens, to: 3, keepingLast: 0) == [101, 1, 2])
        #expect(VMLXTransformerEmbedder.truncate([1, 2], to: 1, keepingLast: 3) == [2])
    }
}

private actor RecordingEmbedder: VecturaEmbedder {
    private(set) var batchSizes: [Int] = []

    var dimension: Int {
        get async throws { 1 }
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        batchSizes.append(texts.count)
        return texts.map { [Float($0.count)] }
    }

    func embed(text: String) async throws -> [Float] {
        try await embed(texts: [text])[0]
    }
}

private enum Fixture {
    static let bertConfig = #"{"model_type": "bert", "architectures": ["BertModel"], "hidden_size": 384, "max_position_embeddings": 512}"#
    static let qwen3Config =
        #"{"model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"], "hidden_size": 1024, "max_position_embeddings": 32768, "num_hidden_layers": 28, "num_attention_heads": 16}"#
    static let weights = Data(repeating: 7, count: 64)

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            component: "osaurus-embedding-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func bundle(
        config: String,
        extra: [String: String] = [:],
        weights hasWeights: Bool = true,
        tokenizer: Bool = true
    ) throws -> URL {
        let dir = try directory()
        try Data(config.utf8).write(to: dir.appending(component: "config.json"))
        if hasWeights { try weights.write(to: dir.appending(component: "model.safetensors")) }
        if tokenizer { try Data("{}".utf8).write(to: dir.appending(component: "tokenizer.json")) }
        for (path, contents) in extra {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return dir
    }

    static func remove(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
