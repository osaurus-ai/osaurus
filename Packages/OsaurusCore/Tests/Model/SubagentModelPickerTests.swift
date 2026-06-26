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
