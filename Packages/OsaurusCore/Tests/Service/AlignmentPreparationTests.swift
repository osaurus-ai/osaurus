import Foundation
import MLXLMCommon
import Testing
@testable import OsaurusCore

@Suite("Direct-Send alignment preparation")
struct AlignmentPreparationTests {
    @Test func authorizationIsExplicitAndModelScoped() {
        let denied = GenerationParameters(temperature: nil, maxTokens: 1, requestSource: .chatUI)
        #expect(!denied.authorizesAlignmentRepair(for: "chosen"))
        for source in RequestSource.allCases {
            let parameters = GenerationParameters(
                temperature: nil, maxTokens: 1, requestSource: source, alignmentRepairModel: "chosen")
            #expect(parameters.authorizesAlignmentRepair(for: "chosen") == (source == .chatUI))
            #expect(!parameters.authorizesAlignmentRepair(for: "different"))
        }
        let background = GenerationParameters(
            temperature: nil, maxTokens: 1, requestSource: .chatUI,
            loadIntent: .background, alignmentRepairModel: "chosen")
        #expect(!background.authorizesAlignmentRepair(for: "chosen"))
        let child = GenerationParameters(
            temperature: nil, maxTokens: 1, activitySource: .agent,
            requestSource: .chatUI, alignmentRepairModel: "chosen")
        #expect(!child.authorizesAlignmentRepair(for: "chosen"))
        let auxiliary = GenerationParameters(
            temperature: nil, maxTokens: 1, requestSource: .chatUI,
            alignmentRepairModel: "chosen", auxiliaryCacheIntent: true)
        #expect(!auxiliary.authorizesAlignmentRepair(for: "chosen"))
    }

    @Test func wireCannotAuthorizeRepair() throws {
        let bytes = Data(#"{"model":"chosen","messages":[],"alignmentRepairModel":"chosen"}"#.utf8)
        let request = try JSONDecoder().decode(ChatCompletionRequest.self, from: bytes)
        #expect(request.alignmentRepairModel == nil)
        var authorized = request
        authorized.alignmentRepairModel = "chosen"
        let encoded = try JSONEncoder().encode(authorized)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("alignmentRepairModel"))
        #expect(authorized.withModel("different").alignmentRepairModel == "chosen")
    }

    @MainActor @Test func progressCannotLeakAcrossModelsSessionsOrFinishedLoads() {
        let state = AlignmentPreparationState()
        let id = UUID(), session = UUID()
        let bundle = URL(fileURLWithPath: "/temporary-fixture")
        let copying = AlignmentRepairProgress(
            bundle: bundle, shard: bundle.appendingPathComponent("model.safetensors"),
            stage: .copying, copiedBytes: 4, totalBytes: 10)
        state.begin(id: id, modelID: "chosen", sessionID: session.uuidString)
        #expect(state.progress(modelID: "chosen", sessionID: session) == nil)
        state.update(id: id, progress: copying)
        #expect(state.progress(modelID: "chosen", sessionID: session) == copying)
        #expect(state.progress(modelID: "other", sessionID: session) == nil)
        #expect(state.progress(modelID: "chosen", sessionID: UUID()) == nil)
        state.finish(id: id)
        state.update(id: id, progress: copying)
        #expect(state.entries.isEmpty)
    }
}
