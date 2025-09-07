//
//  SearchServiceTests.swift
//  osaurusTests
//
//  Created by Terence on 8/17/25.
//

import Foundation
import Testing

@testable import osaurus

struct SearchServiceTests {

  // MARK: - Fuzzy Match Tests

  @Test func fuzzyMatch_exactMatch() async throws {
    #expect(SearchService.fuzzyMatch(query: "llama", in: "llama"))
    #expect(SearchService.fuzzyMatch(query: "model", in: "model"))
  }

  @Test func fuzzyMatch_caseInsensitive() async throws {
    #expect(SearchService.fuzzyMatch(query: "LLAMA", in: "llama"))
    #expect(SearchService.fuzzyMatch(query: "llama", in: "LLAMA"))
    #expect(SearchService.fuzzyMatch(query: "LLaMa", in: "llama"))
  }

  @Test func fuzzyMatch_subsequence() async throws {
    // All characters in order but not consecutive
    #expect(SearchService.fuzzyMatch(query: "lm3", in: "Llama-3"))
    #expect(SearchService.fuzzyMatch(query: "meta", in: "Meta-Llama"))
    #expect(SearchService.fuzzyMatch(query: "70b", in: "Llama-3-70B"))
    #expect(SearchService.fuzzyMatch(query: "mlx", in: "mlx-community"))
  }

  @Test func fuzzyMatch_noMatch() async throws {
    // Characters not in order
    #expect(SearchService.fuzzyMatch(query: "3lm", in: "Llama-3") == false)
    #expect(SearchService.fuzzyMatch(query: "xyz", in: "Llama-3") == false)
    #expect(SearchService.fuzzyMatch(query: "llamaa", in: "llama") == false)  // Extra character
  }

  @Test func fuzzyMatch_emptyStrings() async throws {
    #expect(SearchService.fuzzyMatch(query: "", in: "anything"))
    #expect(SearchService.fuzzyMatch(query: "something", in: "") == false)
    #expect(SearchService.fuzzyMatch(query: "", in: ""))
  }

  @Test func fuzzyMatch_specialCharacters() async throws {
    #expect(SearchService.fuzzyMatch(query: "m-l", in: "meta-llama"))
    #expect(SearchService.fuzzyMatch(query: "3.1", in: "Llama-3.1-8B"))
    #expect(SearchService.fuzzyMatch(query: "community/llama", in: "mlx-community/Llama-3"))
  }

  // MARK: - Filter Models Tests

  @Test func filterModels_emptyQuery() async throws {
    let models = createTestModels()
    let filtered = SearchService.filterModels(models, with: "")
    #expect(filtered.count == models.count)

    // Also test with whitespace
    let filtered2 = SearchService.filterModels(models, with: "   ")
    #expect(filtered2.count == models.count)
  }

  @Test func filterModels_byName() async throws {
    let models = createTestModels()

    let filtered = SearchService.filterModels(models, with: "llama")
    #expect(filtered.count == 2)
    #expect(filtered.allSatisfy { $0.name.lowercased().contains("llama") })

    let filtered2 = SearchService.filterModels(models, with: "mistral")
    #expect(filtered2.count == 1)
    #expect(filtered2.first?.name == "Mistral-7B")
  }

  @Test func filterModels_byId() async throws {
    let models = createTestModels()

    let filtered = SearchService.filterModels(models, with: "mlx-community")
    #expect(filtered.count == 3)  // All test models have mlx-community in ID

    let filtered2 = SearchService.filterModels(models, with: "mistral-7b")
    #expect(filtered2.count == 1)
    #expect(filtered2.first?.id == "mlx-community/Mistral-7B")
  }

  @Test func filterModels_byDescription() async throws {
    let models = createTestModels()

    let filtered = SearchService.filterModels(models, with: "language model")
    #expect(filtered.count == 3)  // All have "language model" in description

    let filtered2 = SearchService.filterModels(models, with: "8 billion")
    #expect(filtered2.count == 1)
    #expect(filtered2.first?.name == "Llama-3-8B")
  }

  @Test func filterModels_byURL() async throws {
    let models = createTestModels()

    let filtered = SearchService.filterModels(models, with: "huggingface")
    #expect(filtered.count == 3)  // All have huggingface in URL

    let filtered2 = SearchService.filterModels(models, with: ".co/mlx")
    #expect(filtered2.count == 3)
  }

  @Test func filterModels_fuzzySearch() async throws {
    let models = createTestModels()

    // Fuzzy searches that should match
    let filtered1 = SearchService.filterModels(models, with: "lm3")
    #expect(filtered1.count == 2)  // Matches Llama-3 models

    let filtered2 = SearchService.filterModels(models, with: "70b")
    #expect(filtered2.count == 1)
    #expect(filtered2.first?.name == "Llama-3-70B")

    let filtered3 = SearchService.filterModels(models, with: "mstrl")
    #expect(filtered3.count == 1)  // Fuzzy matches Mistral

    let filtered4 = SearchService.filterModels(models, with: "mlxllama")
    #expect(filtered4.count == 2)  // Matches mlx-community/Llama models
  }

  @Test func filterModels_noMatches() async throws {
    let models = createTestModels()

    let filtered = SearchService.filterModels(models, with: "gpt4")
    #expect(filtered.isEmpty)

    let filtered2 = SearchService.filterModels(models, with: "xyz123")
    #expect(filtered2.isEmpty)
  }

  // MARK: - Test Helpers

  private func createTestModels() -> [MLXModel] {
    return [
      MLXModel(
        id: "mlx-community/Llama-3-8B",
        name: "Llama-3-8B",
        description: "Meta's Llama 3 language model with 8 billion parameters",
        size: 16_000_000_000,
        downloadURL: "https://huggingface.co/mlx-community/Llama-3-8B",
        requiredFiles: ["config.json", "model.safetensors"]
      ),
      MLXModel(
        id: "mlx-community/Llama-3-70B",
        name: "Llama-3-70B",
        description: "Meta's Llama 3 language model with 70 billion parameters",
        size: 140_000_000_000,
        downloadURL: "https://huggingface.co/mlx-community/Llama-3-70B",
        requiredFiles: ["config.json", "model.safetensors"]
      ),
      MLXModel(
        id: "mlx-community/Mistral-7B",
        name: "Mistral-7B",
        description: "Mistral AI's 7B parameter language model",
        size: 14_000_000_000,
        downloadURL: "https://huggingface.co/mlx-community/Mistral-7B",
        requiredFiles: ["config.json", "model.safetensors"]
      ),
    ]
  }
}
