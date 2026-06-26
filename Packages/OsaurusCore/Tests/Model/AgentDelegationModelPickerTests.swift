//
//  AgentDelegationModelPickerTests.swift
//  osaurusTests
//
//  Ensures agent-delegation settings only select compatible downloaded models.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentDelegationModelPickerTests {
    @Test("local text delegate candidates exclude remote image and embedding rows")
    func localTextDelegateCandidatesExcludeNonLocalChatRows() {
        let remoteId = UUID()
        let items: [ModelPickerItem] = [
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
            ModelPickerItem(id: "local-embed", displayName: "Local Embed", source: .local, isEmbedding: true),
            .fromRemoteModel(modelId: "openai/gpt-4o", providerName: "OpenAI", providerId: remoteId),
            imageModel(id: "flux", textToImage: true),
        ]

        #expect(items.localTextDelegateCandidates.map(\.id) == ["local-chat"])
        #expect(items.defaultAgentDelegationCandidate(kind: .localTextDelegate)?.id == "local-chat")
    }

    @Test("image generation candidates require ready text to image capability")
    func imageGenerationCandidatesRequireReadyTextToImage() {
        let items: [ModelPickerItem] = [
            imageModel(id: "not-ready", ready: false, textToImage: true),
            imageModel(id: "edit-only", imageEdit: true),
            imageModel(id: "flux", textToImage: true),
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
        ]

        #expect(items.imageGenerationDelegateCandidates.map(\.id) == ["flux"])
        #expect(items.defaultAgentDelegationCandidate(kind: .imageGeneration)?.id == "flux")
    }

    @Test("image edit candidates require ready edit capability")
    func imageEditCandidatesRequireReadyEdit() {
        let items: [ModelPickerItem] = [
            imageModel(id: "flux", textToImage: true),
            imageModel(id: "edit-not-ready", ready: false, imageEdit: true),
            imageModel(id: "qwen-edit", imageEdit: true),
        ]

        #expect(items.imageEditDelegateCandidates.map(\.id) == ["qwen-edit"])
        #expect(items.defaultAgentDelegationCandidate(kind: .imageEdit)?.id == "qwen-edit")
    }

    @Test("configured candidate rejects missing or incompatible ids")
    func configuredCandidateRejectsMissingOrIncompatibleIds() {
        let items: [ModelPickerItem] = [
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
            imageModel(id: "flux", textToImage: true),
            imageModel(id: "qwen-edit", imageEdit: true),
        ]

        #expect(items.agentDelegationCandidate(id: "local-chat", kind: .localTextDelegate)?.id == "local-chat")
        #expect(items.agentDelegationCandidate(id: "flux", kind: .localTextDelegate) == nil)
        #expect(items.agentDelegationCandidate(id: "missing", kind: .imageGeneration) == nil)
        #expect(items.agentDelegationCandidate(id: nil, kind: .imageEdit) == nil)
    }

    private func imageModel(
        id: String,
        ready: Bool = true,
        textToImage: Bool = false,
        imageEdit: Bool = false
    ) -> ModelPickerItem {
        ModelPickerItem(
            id: id,
            displayName: id,
            source: .imageGeneration,
            imageCapabilities: ImageModelCapabilities(
                textToImage: textToImage,
                imageEdit: imageEdit,
                negativePrompt: textToImage || imageEdit
            ),
            imageReady: ready
        )
    }
}
