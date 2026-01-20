//
//  SearchServiceTests.swift
//  osaurusTests
//
//  Created by Terence on 8/17/25.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SearchServiceTests {

    // MARK: - Normalization

    @Test func normalizeForSearch_removesSpecialCharacters() {
        #expect(SearchService.normalizeForSearch("GLM-4.7-Flash") == "glm47flash")
        #expect(SearchService.normalizeForSearch("Llama-3.2-8B-Instruct") == "llama328binstruct")
        #expect(SearchService.normalizeForSearch("gpt-4o") == "gpt4o")
        #expect(SearchService.normalizeForSearch("hello_world") == "helloworld")
        #expect(SearchService.normalizeForSearch("test 123") == "test123")
    }

    @Test func normalizeForSearch_lowercases() {
        #expect(SearchService.normalizeForSearch("UPPERCASE") == "uppercase")
        #expect(SearchService.normalizeForSearch("MixedCase") == "mixedcase")
    }

    // MARK: - Tokenization

    @Test func tokenize_splitsOnSeparators() {
        #expect(SearchService.tokenize("GLM-4.7-Flash") == ["glm", "4", "7", "flash"])
        #expect(SearchService.tokenize("Llama 3.2 8B") == ["llama", "3", "2", "8b"])
        #expect(SearchService.tokenize("hello_world-test") == ["hello", "world", "test"])
    }

    @Test func tokenize_handlesEmpty() {
        #expect(SearchService.tokenize("").isEmpty)
        #expect(SearchService.tokenize("   ").isEmpty)
        #expect(SearchService.tokenize("---").isEmpty)
    }

    // MARK: - Main Search (matches)

    @Test func matches_emptyQuery() {
        #expect(SearchService.matches(query: "", in: "anything"))
        #expect(SearchService.matches(query: "   ", in: "anything"))
    }

    @Test func matches_exactSubstring() {
        #expect(SearchService.matches(query: "llama", in: "Llama-3-8B"))
        #expect(SearchService.matches(query: "8B", in: "Llama-3-8B"))
    }

    @Test func matches_tokenBased() {
        #expect(SearchService.matches(query: "GLM Flash", in: "glm-4-7b-flash"))
        #expect(SearchService.matches(query: "llama 8b", in: "Llama-3-8B-Instruct"))
        #expect(SearchService.matches(query: "mistral instruct", in: "Mistral-7B-Instruct-v0.2"))
    }

    @Test func matches_tokenOrderIndependent() {
        #expect(SearchService.matches(query: "flash glm", in: "glm-4-7b-flash"))
        #expect(SearchService.matches(query: "8b llama", in: "Llama-3-8B"))
        #expect(SearchService.matches(query: "instruct mistral 7b", in: "Mistral-7B-Instruct"))
    }

    @Test func matches_normalized() {
        #expect(SearchService.matches(query: "glm47", in: "GLM-4.7-Flash"))
        #expect(SearchService.matches(query: "llama32", in: "Llama-3.2-8B-Instruct"))
        #expect(SearchService.matches(query: "gpt4o", in: "openai/gpt-4o"))
    }

    @Test func matches_partialToken() {
        #expect(SearchService.matches(query: "GLM", in: "glm-4-7b-flash"))
        #expect(SearchService.matches(query: "inst", in: "Llama-3-8B-Instruct"))
    }

    @Test func matches_providerAndModel() {
        #expect(SearchService.matches(query: "openai gpt", in: "OpenAI/gpt-4o"))
        #expect(SearchService.matches(query: "mlx llama", in: "mlx-community/Llama-3-8B"))
    }

    @Test func matches_realWorldExamples() {
        // Original issue: GLM 4.7 Flash
        #expect(SearchService.matches(query: "GLM 4.7 Flash", in: "glm-4-7b-flash"))
        #expect(SearchService.matches(query: "GLM 4.7", in: "GLM-4-7B-Chat-4bit"))
        // Other common searches
        #expect(SearchService.matches(query: "qwen 2.5", in: "Qwen2.5-7B-Instruct"))
        #expect(SearchService.matches(query: "deepseek coder", in: "deepseek-coder-6.7b-instruct"))
        #expect(SearchService.matches(query: "phi 3", in: "Phi-3-mini-4k-instruct"))
    }

    @Test func matches_noMatch() {
        #expect(!SearchService.matches(query: "gpt4", in: "Llama-3-8B"))
        #expect(!SearchService.matches(query: "xyz123", in: "Mistral-7B"))
        #expect(!SearchService.matches(query: "claude", in: "gpt-4o"))
    }

    // MARK: - Tokenized Match

    @Test func tokenizedMatch_allTokensRequired() {
        #expect(SearchService.tokenizedMatch(query: "llama 3 8b", in: "Llama-3-8B"))
        #expect(!SearchService.tokenizedMatch(query: "llama xyz", in: "Llama-3-8B"))
    }

    // MARK: - Fuzzy Match (Subsequence)

    @Test func fuzzyMatch_exact() {
        #expect(SearchService.fuzzyMatch(query: "llama", in: "llama"))
        #expect(SearchService.fuzzyMatch(query: "model", in: "model"))
    }

    @Test func fuzzyMatch_caseInsensitive() {
        #expect(SearchService.fuzzyMatch(query: "LLAMA", in: "llama"))
        #expect(SearchService.fuzzyMatch(query: "llama", in: "LLAMA"))
        #expect(SearchService.fuzzyMatch(query: "LLaMa", in: "llama"))
    }

    @Test func fuzzyMatch_subsequence() {
        #expect(SearchService.fuzzyMatch(query: "lm3", in: "Llama-3"))
        #expect(SearchService.fuzzyMatch(query: "meta", in: "Meta-Llama"))
        #expect(SearchService.fuzzyMatch(query: "70b", in: "Llama-3-70B"))
        #expect(SearchService.fuzzyMatch(query: "mlx", in: "mlx-community"))
    }

    @Test func fuzzyMatch_noMatch() {
        #expect(!SearchService.fuzzyMatch(query: "3lm", in: "Llama-3"))
        #expect(!SearchService.fuzzyMatch(query: "xyz", in: "Llama-3"))
        #expect(!SearchService.fuzzyMatch(query: "llamaa", in: "llama"))
    }

    @Test func fuzzyMatch_empty() {
        #expect(SearchService.fuzzyMatch(query: "", in: "anything"))
        #expect(!SearchService.fuzzyMatch(query: "something", in: ""))
        #expect(SearchService.fuzzyMatch(query: "", in: ""))
    }

    @Test func fuzzyMatch_specialCharacters() {
        #expect(SearchService.fuzzyMatch(query: "m-l", in: "meta-llama"))
        #expect(SearchService.fuzzyMatch(query: "3.1", in: "Llama-3.1-8B"))
        #expect(SearchService.fuzzyMatch(query: "community/llama", in: "mlx-community/Llama-3"))
    }

    // MARK: - Filter Models

    @Test func filterModels_emptyQuery() {
        let models = createTestModels()
        #expect(SearchService.filterModels(models, with: "").count == models.count)
        #expect(SearchService.filterModels(models, with: "   ").count == models.count)
    }

    @Test func filterModels_byName() {
        let models = createTestModels()
        let filtered = SearchService.filterModels(models, with: "llama")
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.name.lowercased().contains("llama") })

        let filtered2 = SearchService.filterModels(models, with: "mistral")
        #expect(filtered2.count == 1)
        #expect(filtered2.first?.name == "Mistral-7B")
    }

    @Test func filterModels_byId() {
        let models = createTestModels()
        #expect(SearchService.filterModels(models, with: "mlx-community").count == 3)

        let filtered = SearchService.filterModels(models, with: "mistral-7b")
        #expect(filtered.count == 1)
        #expect(filtered.first?.id == "mlx-community/Mistral-7B")
    }

    @Test func filterModels_byDescription() {
        let models = createTestModels()
        #expect(SearchService.filterModels(models, with: "language model").count == 3)

        let filtered = SearchService.filterModels(models, with: "8 billion")
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "Llama-3-8B")
    }

    @Test func filterModels_byURL() {
        let models = createTestModels()
        #expect(SearchService.filterModels(models, with: "huggingface").count == 3)
        #expect(SearchService.filterModels(models, with: ".co/mlx").count == 3)
    }

    @Test func filterModels_fuzzy() {
        let models = createTestModels()
        #expect(SearchService.filterModels(models, with: "lm3").count == 2)
        #expect(SearchService.filterModels(models, with: "70b").first?.name == "Llama-3-70B")
        #expect(SearchService.filterModels(models, with: "mstrl").count == 1)
        #expect(SearchService.filterModels(models, with: "mlxllama").count == 2)
    }

    @Test func filterModels_noMatch() {
        let models = createTestModels()
        #expect(SearchService.filterModels(models, with: "gpt4").isEmpty)
        #expect(SearchService.filterModels(models, with: "xyz123").isEmpty)
    }

    // MARK: - Helpers

    private func createTestModels() -> [MLXModel] {
        [
            MLXModel(
                id: "mlx-community/Llama-3-8B",
                name: "Llama-3-8B",
                description: "Meta's Llama 3 language model with 8 billion parameters",
                downloadURL: "https://huggingface.co/mlx-community/Llama-3-8B"
            ),
            MLXModel(
                id: "mlx-community/Llama-3-70B",
                name: "Llama-3-70B",
                description: "Meta's Llama 3 language model with 70 billion parameters",
                downloadURL: "https://huggingface.co/mlx-community/Llama-3-70B"
            ),
            MLXModel(
                id: "mlx-community/Mistral-7B",
                name: "Mistral-7B",
                description: "Mistral AI's 7B parameter language model",
                downloadURL: "https://huggingface.co/mlx-community/Mistral-7B"
            ),
        ]
    }
}
