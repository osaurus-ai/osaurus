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

    @Test func localModelsAreAlwaysChatCapable() {
        // Local models come from the curated MLX catalog (chat-only), so the
        // heuristic is bypassed even if the name happens to match an
        // embedding pattern.
        let localLooksLikeEmbedding = ModelPickerItem(
            id: "mlx-community/some-embedded-model-name",
            displayName: "Some Embedded",
            source: .local
        )
        #expect(localLooksLikeEmbedding.isLikelyChatCapable)
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
