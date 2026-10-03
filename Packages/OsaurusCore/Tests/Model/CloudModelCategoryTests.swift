import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct CloudModelCategoryTests {
    private let providerID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    private func chat(_ name: String, vision: Bool = false, context: Int? = nil) -> ModelPickerItem {
        ModelPickerItem(
            id: name, displayName: name,
            source: .remote(providerName: "Osaurus Cloud", providerId: providerID),
            isVLM: vision, contextLength: context
        )
    }

    private func media(_ kind: MediaGenerationKind, name: String = "Media") -> ModelPickerItem {
        .fromMediaModel(
            MediaModelInfo(
                target: MediaModelTarget(backend: .osaurusCloud, modelID: name),
                displayName: name, providerName: "Osaurus Cloud", kind: kind,
                constraints: MediaModelConstraints(), offline: false
            ),
            providerId: providerID
        )
    }

    @Test func visionChatSupportsBothTextAndImageInputTasks() {
        let model = chat("Multimodal", vision: true)
        #expect(CloudModelCategory.textToText.includes(model))
        #expect(CloudModelCategory.imageToText.includes(model))
        #expect(!CloudModelCategory.image.includes(model))
        #expect(!CloudModelCategory.imageToText.includes(chat("Text only")))
    }

    @Test func mediaOperationsRemainDistinctEvenWithMisleadingNames() {
        let image = media(.image, name: "Text to video")
        let textVideo = media(.textToVideo, name: "Image to video")
        let imageVideo = media(.imageToVideo, name: "Image")
        let items = [image, textVideo, imageVideo]
        #expect(items.filter(CloudModelCategory.image.includes) == [image])
        #expect(items.filter(CloudModelCategory.textToVideo.includes) == [textVideo])
        #expect(items.filter(CloudModelCategory.imageToVideo.includes) == [imageVideo])
        #expect(items.filter(CloudModelCategory.textToText.includes).isEmpty)
        #expect(items.filter(CloudModelCategory.imageToText.includes).isEmpty)
    }

    @Test func categoryChoicesReflectTheCatalogAndRetainAllForEmptyCatalogs() {
        #expect(CloudModelCategory.available(in: []) == [.all])
        #expect(CloudModelCategory.available(in: [media(.image)]) == [.all, .image])
        #expect(CloudModelCategory.available(in: [chat("Vision", vision: true), media(.imageToVideo)])
            == [.all, .textToText, .imageToText, .imageToVideo])
    }

    @Test func categoryCombinesWithSearchAndContextWithoutChangingOrder() {
        let short = chat("Atlas small", vision: true, context: 32_000)
        let long = chat("Atlas large", vision: true, context: 128_000)
        let other = chat("Other", vision: true, context: 256_000)
        let items = [short, long, other, media(.image)]
        let result = items
            .filter { $0.matches(searchQuery: "Atlas") }
            .filteredByContext(.min128K)
            .filter(CloudModelCategory.imageToText.includes)
        #expect(result == [long])
        #expect(items.filter(CloudModelCategory.all.includes) == items)
    }

    @Test func modelNamesDoNotInventImageInputCapability() {
        let text = chat("Vision Image-to-text")
        #expect(!CloudModelCategory.imageToText.includes(text))
        #expect(CloudModelCategory.available(in: [text]) == [.all, .textToText])
    }
}
