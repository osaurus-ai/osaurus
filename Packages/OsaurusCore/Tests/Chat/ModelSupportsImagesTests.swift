//
//  ModelSupportsImagesTests.swift
//  OsaurusCoreTests
//
//  The paired phone's `/models/picker` vision flag and the agent endpoints'
//  `supports_vision` use the desktop image gate. A remote model has no local
//  bundle, so the old local-only check reported it text-only and the phone
//  refused image attachments (#3205).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelSupportsImagesTests {
    private let providerId = UUID()

    @Test func remoteChatModelWithoutCapabilityMetadataAcceptsImages() {
        let item = ModelPickerItem.fromRemoteModel(
            modelId: "custom/vendor/vision-model",
            providerName: "Custom",
            providerId: providerId
        )
        #expect(item.isVLM == false)
        #expect(ChatSession.modelSupportsImages(modelId: item.id, pickerItems: [item]))
    }

    @Test func remoteEmbeddingModelDoesNotAcceptImages() {
        let item = ModelPickerItem(
            id: "custom/vendor/embed-model",
            displayName: "embed-model",
            source: .remote(providerName: "Custom", providerId: providerId),
            isEmbedding: true
        )
        #expect(!ChatSession.modelSupportsImages(modelId: item.id, pickerItems: [item]))
    }

    @Test func unknownModelAndFoundationDoNotAcceptImages() {
        let item = ModelPickerItem.fromRemoteModel(
            modelId: "custom/vendor/vision-model",
            providerName: "Custom",
            providerId: providerId
        )
        #expect(!ChatSession.modelSupportsImages(modelId: "custom/vendor/missing", pickerItems: [item]))
        #expect(!ChatSession.modelSupportsImages(modelId: "foundation", pickerItems: [item]))
    }
}
