//
//  SubagentModelPickerTests.swift
//  osaurusTests
//
//  Ensures agent-delegation settings only select compatible downloaded models.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SubagentModelPickerTests {
    @Test("image generation candidates require ready text to image capability")
    func imageGenerationCandidatesRequireReadyTextToImage() {
        let items: [ModelPickerItem] = [
            imageModel(id: "not-ready", ready: false, textToImage: true),
            imageModel(id: "edit-only", imageEdit: true),
            imageModel(id: "flux", textToImage: true),
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
        ]

        #expect(items.imageGenerationDelegateCandidates.map(\.id) == ["flux"])
        #expect(items.defaultSubagentModelCandidate(kind: .imageGeneration)?.id == "flux")
    }

    @Test("image edit candidates require ready edit capability")
    func imageEditCandidatesRequireReadyEdit() {
        let items: [ModelPickerItem] = [
            imageModel(id: "flux", textToImage: true),
            imageModel(id: "edit-not-ready", ready: false, imageEdit: true),
            imageModel(id: "qwen-edit", imageEdit: true),
        ]

        #expect(items.imageEditDelegateCandidates.map(\.id) == ["qwen-edit"])
        #expect(items.defaultSubagentModelCandidate(kind: .imageEdit)?.id == "qwen-edit")
    }

    @Test("configured candidate rejects missing or incompatible ids")
    func configuredCandidateRejectsMissingOrIncompatibleIds() {
        let items: [ModelPickerItem] = [
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
            imageModel(id: "flux", textToImage: true),
            imageModel(id: "qwen-edit", imageEdit: true),
        ]

        #expect(items.subagentModelCandidate(id: "flux", kind: .imageGeneration)?.id == "flux")
        #expect(items.subagentModelCandidate(id: "local-chat", kind: .imageGeneration) == nil)
        #expect(items.subagentModelCandidate(id: "missing", kind: .imageGeneration) == nil)
        #expect(items.subagentModelCandidate(id: nil, kind: .imageEdit) == nil)
    }

    @Test("chat candidates include local/remote chat and exclude image/embedding")
    func chatCandidatesFilterByCapability() {
        let items: [ModelPickerItem] = [
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
            ModelPickerItem(
                id: "embedder",
                displayName: "Embedder",
                source: .local,
                isEmbedding: true
            ),
            imageModel(id: "flux", textToImage: true),
            ModelPickerItem(
                id: "remote-chat",
                displayName: "Remote Chat",
                source: .remote(providerName: "P", providerId: UUID())
            ),
        ]

        #expect(Set(items.chatModelCandidates.map(\.id)) == ["local-chat", "remote-chat"])
    }

    @Test("subagentChatModelCandidate matches a stored chat id, else nil")
    func chatCandidateLookup() {
        let items: [ModelPickerItem] = [
            ModelPickerItem(id: "local-chat", displayName: "Local Chat", source: .local),
            imageModel(id: "flux", textToImage: true),
        ]

        #expect(items.subagentChatModelCandidate(id: "local-chat")?.id == "local-chat")
        // An image model is not a chat candidate, so the lookup misses.
        #expect(items.subagentChatModelCandidate(id: "flux") == nil)
        #expect(items.subagentChatModelCandidate(id: "   ") == nil)
        #expect(items.subagentChatModelCandidate(id: nil) == nil)
        #expect(items.subagentChatModelCandidate(id: "missing") == nil)
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
