import Foundation
import Testing

@testable import OsaurusCore

struct DecisionModelDownloadCatalogTests {
    private let artifacts = [
        "config.json", "tokenizer.json", "model.safetensors.index.json",
        "model-00001-of-00002.safetensors", "jang_config.json",
        "decision/decision_config.json", "decision/readout.safetensors",
    ]

    @Test func declaredDecisionBundlesAreDownloadableButNotChatCatalogEntries() {
        // A different name/org is intentional: task detection must follow
        // publisher metadata, not a hardcoded list of the nine D3 repo IDs.
        #expect(ModelManager.isDecisionCatalogEligible(
            id: "publisher/choice-model", pipelineTag: "zero-shot-classification",
            tags: ["mlx", "decision-model"], files: artifacts
        ))
        #expect(!ModelManager.isChatCatalogEligible(
            id: "publisher/choice-model", pipelineTag: "zero-shot-classification",
            tags: ["mlx", "decision-model"]
        ))
    }

    @Test func namesAndGenericClassificationDoNotDeclareDecisionBundles() {
        #expect(!ModelManager.isDecisionCatalogEligible(
            id: "OsaurusAI/d3-lookalike", pipelineTag: "zero-shot-classification",
            tags: ["mlx"], files: artifacts
        ))
        for tag in ["text-generation", "token-classification", "feature-extraction", "text-to-image"] {
            #expect(!ModelManager.isDecisionCatalogEligible(
                id: "publisher/utility", pipelineTag: tag,
                tags: ["mlx", "decision-model"], files: artifacts
            ))
        }
        #expect(!ModelManager.isDecisionCatalogEligible(
            id: "publisher/model-gguf", pipelineTag: "zero-shot-classification",
            tags: ["decision-model"], files: artifacts
        ))
    }

    @Test func missingDecisionArtifactsDoNotEnterTheDownloadCatalog() {
        for missing in ["jang_config.json", "decision/decision_config.json", "decision/readout.safetensors"] {
            #expect(!ModelManager.isDecisionCatalogEligible(
                id: "publisher/choice", pipelineTag: "zero-shot-classification",
                tags: ["mlx", "decision-model"], files: artifacts.filter { $0 != missing }
            ))
        }
        #expect(!ModelManager.isDecisionCatalogEligible(
            id: "publisher/choice", pipelineTag: "zero-shot-classification",
            tags: ["mlx", "decision-model"], files: nil
        ))
    }

    @Test @MainActor func orgMetadataProducesDecisionCardsWithoutChangingTheirBackbone() throws {
        let object: [String: Any] = [
            "id": "OsaurusAI/d3-flash-JANGH2",
            "pipeline_tag": "zero-shot-classification",
            "tags": ["mlx", "qwen3_5", "vision", "decision-model"],
            "siblings": artifacts.map { ["rfilename": $0] },
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let metadata = try JSONDecoder().decode(ModelManager.HFModel.self, from: data)
        let model = ModelManager.makeAutoFetchedModel(from: metadata)
        #expect(model.id == "OsaurusAI/d3-flash-JANGH2")
        #expect(model.modelType == "qwen3_5")
        #expect(model.isDecision)
        #expect(model.useCase == nil)
        #expect(!ModelPickerItem.fromMLXModel(model).isLikelyChatCapable)
    }

    @Test @MainActor func metadataEnrichmentAndSerializationKeepDecisionsOutOfChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = MLXModel(
            id: "publisher/choice", name: "Choice", description: "fixture", downloadURL: "",
            rootDirectory: root, isDecision: true
        )
        let local = MLXModel(
            id: model.id, name: model.name, description: "local", downloadURL: "",
            rootDirectory: root
        )
        let enriched = model.withDownloadSize(100).withWeightSize(80).withSSDResidentBytes(20)
            .withDownloads(7).mergingLocalInstallationMetadata(from: local)
        let decoded = try JSONDecoder().decode(MLXModel.self, from: JSONEncoder().encode(enriched))
        for candidate in [model, enriched, decoded] {
            #expect(candidate.isDecision)
            #expect(!ModelPickerItem.fromMLXModel(candidate).isLikelyChatCapable)
            #expect(!candidate.isDownloaded)
        }
        #expect(decoded.downloadSizeBytes == 100)
        #expect(decoded.weightSizeBytes == 80)
        #expect(decoded.ssdResidentBytes == nil) // Local metadata is authoritative.
        #expect(decoded.downloads == 7)
    }

    @Test @MainActor func oldCatalogJSONAndChatBackbonesKeepTheirExistingChatTask() throws {
        let data = Data(#"{"id":"publisher/chat","name":"Chat","description":"fixture","downloadURL":"","isTopSuggestion":false}"#.utf8)
        let model = try JSONDecoder().decode(MLXModel.self, from: data)
        #expect(!model.isDecision)
        #expect(ModelPickerItem.fromMLXModel(model).isLikelyChatCapable)
        #expect(ModelManager.isChatCatalogEligible(
            id: "publisher/chat", pipelineTag: "text-generation", tags: ["qwen3_5"]
        ))
    }
}
