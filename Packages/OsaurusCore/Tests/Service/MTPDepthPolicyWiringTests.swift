import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite struct MTPDepthPolicyWiringTests {
    @Test func explicitButtonsAreFixed() {
        for depth in 1 ... 3 {
            let settings = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: depth)
            #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .fixed)
        }
    }

    @Test func autoHasAnExplicitBoundedExplorationRange() {
        var settings = VMLXServerMTPSettings(mode: .auto)
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .adaptive(maximumDepth: 3))
        settings.draftTokenLimit = 2
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .adaptive(maximumDepth: 2))
        settings.draftTokenLimit = 99
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .adaptive(maximumDepth: 3))
    }

    @Test func offDoesNotOptIntoExploration() {
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(.init(mode: .off)) == .fixed)
    }

    @Test func autoIgnoresStaleManualDepthLikeTheLaunchResolver() {
        let settings = VMLXServerMTPSettings(mode: .auto, explicitDepth: 1)
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .adaptive(maximumDepth: 3))
    }

    @Test func invalidLimitIsNotSilentlyRepaired() {
        var settings = VMLXServerMTPSettings(mode: .auto)
        settings.draftTokenLimit = 0
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .adaptive(maximumDepth: 0))
    }

    @Test func resolvedDepthAndPolicyUseTheSameSnapshot() throws {
        let loaded = DraftStrategy.nativeMTP(depth: 2, verifierMode: nil)
        for depth in 1 ... 3 {
            let mtp = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: depth)
            let snapshot = RuntimeConfig(generation: .init(), concurrency: .init(), mtp: mtp)
            let strategy = ModelRuntime.requestDraftStrategy(loaded, mtp: snapshot.mtp)
            guard case .some(.nativeMTP(let resolvedDepth, _)) = strategy else {
                Issue.record("expected native strategy from explicit settings snapshot")
                continue
            }
            #expect(resolvedDepth == depth)
            #expect(MLXBatchAdapter.nativeMTPDepthPolicy(snapshot.mtp) == .fixed)
        }
    }

    @Test func anExplicitDepthCannotCreateAnAbsentHead() {
        #expect(ModelRuntime.requestDraftStrategy(nil, mtp: .init(mode: .forceOn, explicitDepth: 3)) == nil)
    }
}
