import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

extension EvalStorageIsolationTests {
    @MainActor
    struct DefaultAgentModelBindingTests {
        private enum ProbeError: Error { case failed }

        private func withStore(_ body: @MainActor () async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("eval-model-binding-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous = DefaultAgentConfigurationStore.overrideDirectory
            DefaultAgentConfigurationStore.overrideDirectory = directory
            DefaultAgentConfigurationStore.resetCacheForTests()
            defer {
                DefaultAgentConfigurationStore.overrideDirectory = previous
                DefaultAgentConfigurationStore.resetCacheForTests()
                try? FileManager.default.removeItem(at: directory)
            }
            try await body()
        }

        @Test func pinsWorkerInheritanceWithoutChangingGenerationSettingsAndRestoresDisk() async throws {
            try await withStore {
                let original = DefaultAgentConfiguration(
                    systemPrompt: "Keep existing behavior", defaultModel: "previous/model",
                    temperature: 0.42, maxTokens: 1234
                )
                DefaultAgentConfigurationStore.save(original)
                let value = await EvalDefaultAgentModelBinding.run(model: "eval/provider-model") {
                    DefaultAgentConfigurationStore.resetCacheForTests()
                    let bound = DefaultAgentConfigurationStore.load()
                    #expect(bound.defaultModel == "eval/provider-model")
                    #expect(bound.systemPrompt == original.systemPrompt)
                    #expect(bound.temperature == original.temperature)
                    #expect(bound.maxTokens == original.maxTokens)
                    return 17
                }
                #expect(value == 17)
                DefaultAgentConfigurationStore.resetCacheForTests()
                #expect(DefaultAgentConfigurationStore.load() == original)
            }
        }

        @Test func restoresAfterThrowAndLeavesUnspecifiedModelUntouched() async throws {
            try await withStore {
                let original = DefaultAgentConfiguration(defaultModel: "original/model")
                DefaultAgentConfigurationStore.save(original)
                await EvalDefaultAgentModelBinding.run(model: nil) {
                    #expect(DefaultAgentConfigurationStore.load() == original)
                }
                do {
                    try await EvalDefaultAgentModelBinding.run(model: "eval/model") {
                        throw ProbeError.failed
                    }
                    Issue.record("Expected probe error")
                } catch ProbeError.failed {}
                DefaultAgentConfigurationStore.resetCacheForTests()
                #expect(DefaultAgentConfigurationStore.load() == original)
            }
        }
    }
}
