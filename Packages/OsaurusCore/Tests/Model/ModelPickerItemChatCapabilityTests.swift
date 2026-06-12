//
//  ModelPickerItemChatCapabilityTests.swift
//  osaurusTests
//
//  Covers the default-selection heuristic used by the Chat tab when a
//  remote provider's `/v1/models` response begins with an embedding or
//  reranker model. Before the fix, `pickerItems.first?.id` was selected
//  unconditionally, so any chat turn against the auto-picked model failed
//  with an opaque HTTP 500. The heuristic is intentionally conservative:
//  it rejects obvious embedding/reranker IDs while leaving an absolute
//  fallback so a chat model with an unusual name is still selected.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ModelPickerItemChatCapabilityTests {

    // MARK: - Classifier: known embedding / reranker families

    @Test func classifier_flagsOpenAIEmbeddings() {
        for id in [
            "text-embedding-ada-002",
            "text-embedding-3-small",
            "text-embedding-3-large",
        ] {
            #expect(
                ModelPickerItem.isLikelyEmbeddingOrRerankerID(id),
                "Expected \(id) to be flagged as embedding"
            )
        }
    }

    @Test func classifier_flagsNomicAndJinaEmbeddings() {
        for id in [
            "nomic-embed-text-v1.5",
            "nomic-embed-vision-v1",
            "jina-embeddings-v2-base-en",
            "mxbai-embed-large-v1",
        ] {
            #expect(
                ModelPickerItem.isLikelyEmbeddingOrRerankerID(id),
                "Expected \(id) to be flagged as embedding"
            )
        }
    }

    @Test func classifier_flagsBGEAndReranker() {
        for id in [
            "bge-small-en-v1.5",
            "bge-large-en-v1.5",
            "bge-m3",
            "bge-reranker-v2-m3",
            "BAAI/bge-reranker-v2-m3",
        ] {
            #expect(
                ModelPickerItem.isLikelyEmbeddingOrRerankerID(id),
                "Expected \(id) to be flagged as embedding/reranker"
            )
        }
    }

    @Test func classifier_flagsColbert() {
        // Only separator-delimited forms are caught. A smushed form like
        // `"colbertv2"` is intentionally NOT flagged — keeping the tokenizer
        // strict avoids false positives on unrelated names that happen to
        // contain the substring.
        #expect(ModelPickerItem.isLikelyEmbeddingOrRerankerID("colbert-v2"))
        #expect(ModelPickerItem.isLikelyEmbeddingOrRerankerID("colbert_v2"))
    }

    @Test func classifier_stripsProviderPrefixBeforeMatching() {
        // Remote picker items are prefixed like "provider-name/model-id"; the
        // classifier must match on the tail so prefixed forms still get caught.
        #expect(
            ModelPickerItem.isLikelyEmbeddingOrRerankerID(
                "Qwen/Qwen3-Embedding-8B-GGUF"
            )
        )
        #expect(
            ModelPickerItem.isLikelyEmbeddingOrRerankerID(
                "openai/text-embedding-3-small"
            )
        )
        #expect(
            ModelPickerItem.isLikelyEmbeddingOrRerankerID(
                "huggingface/bge-small-en"
            )
        )
    }

    // MARK: - Classifier: known chat models must NOT be flagged

    @Test func classifier_passesChatModels() {
        for id in [
            "gpt-4o",
            "gpt-4-turbo",
            "gpt-3.5-turbo",
            "claude-opus-4",
            "claude-sonnet-4.5",
            "claude-haiku-4.5",
            "qwen3-coder-30b-a3b-instruct",
            "Qwen3-Coder-30B-A3B-Instruct-GGUF",
            "llama-3.3-70b-instruct",
            "Meta-Llama-3.2-3B-Instruct-4bit",
            "mistral-small-instruct",
            "gemini-1.5-pro",
            "mixtral-8x22b-instruct",
        ] {
            #expect(
                !ModelPickerItem.isLikelyEmbeddingOrRerankerID(id),
                "Did not expect \(id) to be flagged"
            )
        }
    }

    @Test func classifier_doesNotMisfireOnSubstringMatches() {
        // Whole-token matching should mean "embedded" in a model name does
        // not register as "embed". This guards against a future regression
        // where a contains()-style check is substituted for the tokenizer.
        #expect(!ModelPickerItem.isLikelyEmbeddingOrRerankerID("embedded-llama-7b"))
        #expect(!ModelPickerItem.isLikelyEmbeddingOrRerankerID("rerankable-sort-3b"))
    }

    // MARK: - isLikelyChatCapable per source

    @Test func foundationIsAlwaysChatCapable() {
        #expect(ModelPickerItem.foundation().isLikelyChatCapable)
    }

    @Test func localNonEmbeddingModelsAreChatCapable() {
        // Local items use the config.json-derived `isEmbedding` flag, not
        // the name heuristic — an embedding-looking name must not trip it.
        let localLooksLikeEmbedding = ModelPickerItem(
            id: "mlx-community/some-embedded-model-name",
            displayName: "Some Embedded",
            source: .local
        )
        #expect(localLooksLikeEmbedding.isLikelyChatCapable)
    }

    @Test func localEmbeddingModelsAreNotChatCapable() {
        // An embedding bundle imported from the HF cache (e.g.
        // minishlab/potion-base-4M downloaded by the memory feature) is not
        // chat-capable, even though its name matches no embedding token.
        let item = ModelPickerItem(
            id: "minishlab/potion-base-4M",
            displayName: "Potion Base 4M",
            source: .local,
            isEmbedding: true
        )
        #expect(!item.isLikelyChatCapable)
    }

    @Test func firstChatCapable_skipsLeadingLocalEmbedding() {
        // Alphabetical ordering frequently puts all-MiniLM/potion first in
        // the local list; default selection must skip past them.
        let items: [ModelPickerItem] = [
            ModelPickerItem(
                id: "sentence-transformers/all-MiniLM-L6-v2",
                displayName: "All MiniLM L6 v2",
                source: .local,
                isEmbedding: true
            ),
            ModelPickerItem(
                id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                displayName: "Llama 3.2 3B",
                source: .local
            ),
        ]
        #expect(items.firstChatCapable?.id == "mlx-community/Llama-3.2-3B-Instruct-4bit")
    }

    @Test func fromMLXModel_carriesEmbeddingVerdictFromBundleConfig() throws {
        // The picker item's flag must come from the bundle's config.json via
        // MLXModel.isEmbedding, so HF-cache imports are classified by
        // architecture rather than by name.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osu-picker-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config: [String: Any] = [
            "model_type": "bert",
            "architectures": ["BertModel"],
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: dir.appendingPathComponent("config.json"))

        let model = MLXModel(
            id: "sentence-transformers/all-MiniLM-L6-v2",
            name: "All MiniLM L6 v2",
            description: "fixture",
            downloadURL: "https://example.invalid/minilm",
            bundleDirectory: dir,
            externalSource: "Hugging Face cache"
        )
        let item = ModelPickerItem.fromMLXModel(model)
        #expect(item.isEmbedding)
        #expect(!item.isLikelyChatCapable)
    }

    @Test func remoteEmbeddingIsNotChatCapable() {
        let item = ModelPickerItem.fromRemoteModel(
            modelId: "openai/text-embedding-3-small",
            providerName: "OpenAI",
            providerId: UUID()
        )
        #expect(!item.isLikelyChatCapable)
    }

    @Test func remoteChatModelIsChatCapable() {
        let item = ModelPickerItem.fromRemoteModel(
            modelId: "openai/gpt-4o",
            providerName: "OpenAI",
            providerId: UUID()
        )
        #expect(item.isLikelyChatCapable)
    }

    // MARK: - firstChatCapable fallback behavior

    @Test func firstChatCapable_prefersChatOverLeadingEmbedding() {
        // The reported #884 scenario: a custom provider's /v1/models returns
        // an embedding model first. firstChatCapable must skip past it.
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(
                modelId: "myprovider/text-embedding-3-small",
                providerName: "MyProvider",
                providerId: providerId
            ),
            .fromRemoteModel(
                modelId: "myprovider/gpt-4o",
                providerName: "MyProvider",
                providerId: providerId
            ),
        ]
        #expect(items.firstChatCapable?.id == "myprovider/gpt-4o")
    }

    @Test func firstChatCapable_fallsBackToFirstWhenNoneMatch() {
        // Defensive fallback: if every item trips the heuristic (e.g. a
        // provider that exposes only reranker models), we still return
        // something so the picker is never left nil with items present.
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(
                modelId: "myprovider/bge-reranker-v2-m3",
                providerName: "MyProvider",
                providerId: providerId
            ),
            .fromRemoteModel(
                modelId: "myprovider/text-embedding-3-small",
                providerName: "MyProvider",
                providerId: providerId
            ),
        ]
        #expect(items.firstChatCapable?.id == "myprovider/bge-reranker-v2-m3")
    }

    @Test func firstChatCapable_emptyArrayReturnsNil() {
        let items: [ModelPickerItem] = []
        #expect(items.firstChatCapable == nil)
    }

    @Test func firstChatCapable_prefersOsaurusGemmaQATOverSourceGemma() {
        let items: [ModelPickerItem] = [
            ModelPickerItem(
                id: "google--gemma-4-26b-a4b-it-qat-q4_0-unquantized",
                displayName: "google Gemma 4 26B A4B it qat q4_0 unquantized",
                source: .local
            ),
            ModelPickerItem(
                id: "osaurusai--gemma-4-12b-it-qat-jang_4m",
                displayName: "OsaurusAI Gemma 4 12B it qat JANG_4M",
                source: .local
            ),
        ]

        #expect(items.firstChatCapable?.id == "osaurusai--gemma-4-12b-it-qat-jang_4m")
    }

    @Test func firstChatCapable_prefersFoundationWhenLeading() {
        // Matches the computeItems() ordering where Foundation (when
        // available) is prepended and should always be the default pick.
        let items: [ModelPickerItem] = [
            .foundation(),
            .fromRemoteModel(
                modelId: "openai/text-embedding-3-small",
                providerName: "OpenAI",
                providerId: UUID()
            ),
        ]
        #expect(items.firstChatCapable?.id == "foundation")
    }
}
