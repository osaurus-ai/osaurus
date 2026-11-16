import Testing

@testable import OsaurusCore

/// Gemini text models resolve their own documented level set, and nothing
/// else named `gemini` picks one up (#3108).
@Suite("Gemini reasoning contract")
struct GeminiReasoningContractTests {

    @Test func textModelsResolveTheirOwnLevelSets() {
        let cases: [(String, [String], String?)] = [
            ("gemini-4-carbon", ["low", "medium", "high"], "medium"),
            ("gemini-4-carbon-cyber-permissive", ["low", "medium", "high"], "medium"),
            ("google/gemini-4-argon", ["low", "medium", "high"], "medium"),
            ("openrouter/google/gemini-3.8-flash", ["low", "medium", "high"], "medium"),
            ("gemini-3.7-flash", ["low", "medium", "high"], "medium"),
            ("gemini-3.6-flash-preview-09-2026", ["minimal", "low", "medium", "high"], "medium"),
            ("gemini-3.5-flash", ["minimal", "low", "medium", "high"], "medium"),
            ("gemini-3.1-flash-lite", ["minimal", "low", "medium", "high"], "minimal"),
            ("google/gemini-3-flash-preview", ["minimal", "low", "medium", "high"], "high"),
            ("models/gemini-3.1-pro-preview", ["low", "medium", "high"], "high"),
            ("gemini-3-pro-preview", ["low", "high"], "high"),
            ("gemini-3.5-flash-lite", ["minimal", "low", "medium", "high"], "minimal"),
            ("gemini-2.5-flash-lite", ["low", "medium", "high"], nil),
            ("gemini-2.5-pro", ["low", "medium", "high"], nil),
        ]
        for (modelId, levels, defaultLevel) in cases {
            let capabilities = GeminiReasoningContract.capabilities(forModelId: modelId)
            #expect(capabilities?.levels.map(\.id) == levels, "\(modelId)")
            #expect(capabilities?.defaultLevelId == defaultLevel, "\(modelId)")
        }
    }

    @Test func nonTextAndUnlistedModelsGetNoControl() {
        for modelId in [
            "gemini-3-pro-image-preview",
            "gemini-3.1-flash-image-preview",
            "gemini-3.1-flash-lite-image",
            "gemini-nano-banana-2.1",
            "gemini-2.5-flash-preview-tts",
            "gemini-embedding-001",
            "gemini-live-2.5-flash",
            "gemma-4-27b-it",
            "gemini-2.0-flash",
            "gemini-3.8-flash-lite",
            "gemini-3.9-flash",
        ] {
            #expect(GeminiReasoningContract.capabilities(forModelId: modelId) == nil, "\(modelId)")
        }
    }

    /// Gemini 4 and 3.7/3.8 Flash 400 on `minimal`, and Gemini 4 400s on any
    /// `thinkingBudget`, so neither may reach the wire.
    @Test func gemini4AndLateFlashNeverSendMinimalOrBudget() {
        for modelId in ["gemini-4-carbon", "gemini-4-argon", "gemini-3.7-flash", "gemini-3.8-flash"] {
            #expect(GeminiReasoningContract.thinkingConfig(forModelId: modelId, effort: "minimal") == nil, "\(modelId)")
        }
        for modelId in ["gemini-4-carbon", "gemini-4-argon"] {
            for effort in ["low", "medium", "high"] {
                let config = GeminiReasoningContract.thinkingConfig(forModelId: modelId, effort: effort)
                #expect(config?.thinkingLevel == effort, "\(modelId) \(effort)")
                #expect(config?.thinkingBudget == nil, "\(modelId) \(effort)")
            }
        }
    }

    @Test func routeScopingCoversOnlyForwardingHosts() {
        #expect(GeminiReasoningContract.routeHonorsContract(providerType: .gemini, host: "generativelanguage.googleapis.com"))
        #expect(GeminiReasoningContract.routeHonorsContract(providerType: .openaiLegacy, host: "openrouter.ai"))
        #expect(GeminiReasoningContract.routeHonorsContract(providerType: .openaiLegacy, host: "generativelanguage.googleapis.com"))
        #expect(!GeminiReasoningContract.routeHonorsContract(providerType: .openaiLegacy, host: "litellm.internal"))
        #expect(!GeminiReasoningContract.routeHonorsContract(providerType: .osaurusRouter, host: "router.osaurus.ai"))
    }
}
