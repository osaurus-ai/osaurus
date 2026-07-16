import Foundation
import Testing

@testable import OsaurusCore

@Suite("Automatic on-device model routing")
struct AutomaticModelRoutingPolicyTests {
    private let providerId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func local(
        _ id: String,
        memory: Double,
        parameters: String? = nil,
        compatibility: ModelCompatibility = .compatible,
        image: Bool = false,
        video: Bool = false,
        audio: Bool = false
    ) -> ModelPickerItem {
        ModelPickerItem(
            id: id,
            displayName: id,
            source: .local,
            parameterCount: parameters,
            supportsImageInput: image,
            supportsVideoInput: video,
            supportsAudioInput: audio,
            estimatedMemoryGB: memory,
            hardwareCompatibility: compatibility
        )
    }

    @Test("model capability rank beats quantized working-set size")
    func parameterCountOutranksWorkingSet() {
        let decision = AutomaticModelRoutingPolicy.resolve(
            items: [
                local("local/12b-4bit", memory: 8, parameters: "12B"),
                local("local/27b-1bit", memory: 4.5, parameters: "27B"),
            ]
        )

        #expect(decision?.modelId == "local/27b-1bit")
    }

    @Test("chooses strongest compatible local model and never cloud")
    func strongestSafeLocalOnly() {
        let decision = AutomaticModelRoutingPolicy.resolve(
            items: [
                .fromRemoteModel(
                    modelId: "cloud/frontier",
                    providerName: "Cloud",
                    providerId: providerId
                ),
                local("local/small", memory: 3),
                local("local/strong", memory: 9),
                local("local/tight", memory: 12, compatibility: .tight),
                local("local/unknown", memory: 20, compatibility: .unknown),
            ],
            physicalMemoryGB: 24
        )

        #expect(decision?.modelId == "local/strong")
        #expect(decision?.explanation.contains("Private on-device route") == true)
    }

    @Test("keeps current safe route for multi-turn cache locality")
    func currentSafeRouteWins() {
        let decision = AutomaticModelRoutingPolicy.resolve(
            items: [
                local("local/small", memory: 3),
                local("local/strong", memory: 9),
            ],
            currentModelId: "local/small"
        )

        #expect(decision?.modelId == "local/small")
    }

    @Test("upgrades to compatible media model before a media turn")
    func mediaUpgrade() {
        let items = [
            local("local/text", memory: 8),
            local("local/vision", memory: 6, image: true, video: true),
            local("local/omni-tight", memory: 11, compatibility: .tight, image: true, audio: true),
        ]

        let image = AutomaticModelRoutingPolicy.resolve(
            items: items,
            requirements: .image,
            currentModelId: "local/text"
        )
        let video = AutomaticModelRoutingPolicy.resolve(
            items: items,
            requirements: .video,
            currentModelId: "local/text"
        )
        let audio = AutomaticModelRoutingPolicy.resolve(
            items: items,
            requirements: .audio,
            currentModelId: "local/text"
        )

        #expect(image?.modelId == "local/vision")
        #expect(video?.modelId == "local/vision")
        #expect(audio == nil)
    }

    @Test("media controls advertise only routes that can really resolve")
    func advertisedMediaMatchesRoutes() {
        let capabilities = AutomaticModelRoutingPolicy.availableMediaCapabilities(
            items: [
                .foundation(),
                local("local/text", memory: 3),
                local("local/vision", memory: 5, image: true, video: true),
            ]
        )

        #expect(capabilities.supportsImage)
        #expect(capabilities.supportsVideo)
        #expect(!capabilities.supportsAudio)
    }

    @Test("Foundation is an on-device text fallback, never a media fallback")
    func foundationFallbackIsTextOnly() {
        let items: [ModelPickerItem] = [
            .foundation(),
            .fromRemoteModel(
                modelId: "cloud/vision",
                providerName: "Cloud",
                providerId: providerId
            ),
        ]

        #expect(AutomaticModelRoutingPolicy.resolve(items: items)?.modelId == "foundation")
        #expect(
            AutomaticModelRoutingPolicy.resolve(items: items, requirements: .image) == nil
        )
    }

    @Test("synthetic Automatic choice is settings-only")
    func settingsChoice() {
        let base = [local("local/text", memory: 3)]
        let choices = base.withAutomaticOnDeviceChoice

        #expect(choices.first?.id == AutomaticModelRoutingPolicy.modelId)
        #expect(choices.first?.isFavoriteEligible == false)
        #expect(choices.dropFirst().map(\.id) == base.map(\.id))
        #expect(AutomaticModelRoutingPolicy.isAutomatic(choices.first?.id))
    }
}

@Suite("Model hardware guidance")
struct ModelHardwareGuidanceTests {
    @Test("budget summary distinguishes unified memory from model budget")
    func budgetSummary() {
        #expect(
            ModelHardwareGuidance.budgetSummary(physicalMemoryGB: 24)
                == "24 GB unified memory · 16 GB recommended local-model budget"
        )
    }

    @Test("fit summary reports working set against recommended budget")
    func fitSummary() {
        #expect(
            ModelHardwareGuidance.fitSummary(
                estimatedMemoryGB: 10,
                compatibility: .compatible,
                physicalMemoryGB: 24
            ) == "Comfortable fit · ~10 GB working set · 16 GB budget"
        )
    }

    @Test("128 GB Macs expose the Metal-scale local-model budget")
    func highMemoryBudgetSummary() {
        #expect(
            ModelHardwareGuidance.budgetSummary(physicalMemoryGB: 128)
                == "128 GB unified memory · 107.5 GB recommended local-model budget"
        )
    }

    @Test("image guidance matches the execution-time RAM preflight")
    func imageWorkingSetMatchesPreflight() throws {
        let gib: UInt64 = 1024 * 1024 * 1024
        let estimate = try #require(
            ModelHardwareGuidance.estimatedImageWorkingSetGB(onDiskBytes: 20 * gib)
        )
        #expect(abs(estimate - 29) < 0.001)
        #expect(
            ModelHardwareGuidance.delegatedModelPreflightRequiredBytes(
                onDiskBytes: Int64(20 * gib)
            ) == Int64(29 * gib)
        )
    }
}
