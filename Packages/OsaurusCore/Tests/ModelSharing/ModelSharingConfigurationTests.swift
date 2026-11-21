import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model sharing configuration", .serialized)
struct ModelSharingConfigurationTests {
    @Test func defaultsShareNothingAndLookForNearbyMacs() {
        let configuration = ModelSharingConfiguration()
        #expect(!configuration.shareOnLocalNetwork)
        #expect(configuration.sharedItemIds.isEmpty)
        #expect(configuration.useNearbyMacs)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let empty = try JSONDecoder().decode(ModelSharingConfiguration.self, from: Data("{}".utf8))
        #expect(empty == ModelSharingConfiguration())

        let partial = try JSONDecoder().decode(
            ModelSharingConfiguration.self,
            from: Data(#"{"shareOnLocalNetwork":true}"#.utf8)
        )
        #expect(partial.shareOnLocalNetwork)
        #expect(partial.useNearbyMacs)
        #expect(partial.sharedItemIds.isEmpty)
    }

    @Test func sharedIdsEncodeSorted() throws {
        let configuration = ModelSharingConfiguration(
            shareOnLocalNetwork: true,
            sharedItemIds: ["speech:v3", "image:flux-schnell", "language:mlx-community/Raptor-4bit"],
            useNearbyMacs: false
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )
        #expect(
            object["sharedItemIds"] as? [String] == [
                "image:flux-schnell", "language:mlx-community/Raptor-4bit", "speech:v3",
            ]
        )
        let decoded = try JSONDecoder().decode(
            ModelSharingConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded == configuration)
        #expect(decoded.isShared("speech:v3"))
        #expect(!decoded.isShared("speech:v2"))
    }

    @Test func storeRoundTripsThroughConfigFile() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-model-sharing-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            ModelSharingConfigurationStore.resetCacheForTests()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                ModelSharingConfigurationStore.resetCacheForTests()
                try? FileManager.default.removeItem(at: root)
            }

            #expect(ModelSharingConfigurationStore.load() == ModelSharingConfiguration())

            let saved = ModelSharingConfiguration(
                shareOnLocalNetwork: true,
                sharedItemIds: ["language:mlx-community/Raptor-4bit"],
                useNearbyMacs: false
            )
            ModelSharingConfigurationStore.save(saved)
            #expect(FileManager.default.fileExists(atPath: OsaurusPaths.modelSharingConfigFile().path))

            ModelSharingConfigurationStore.resetCacheForTests()
            #expect(ModelSharingConfigurationStore.load() == saved)
        }
    }
}
