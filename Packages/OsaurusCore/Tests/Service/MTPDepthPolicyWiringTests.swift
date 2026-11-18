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

    /// No hard draft depth: Adaptive's top rung is the runtime's (the loaded model's verifier capability), never
    /// an app constant. The former `min(draftTokenLimit ?? 5, 5)` fails every runtime rung above 5 below (and
    /// pinned a stale `draftTokenLimit` as the ceiling).
    @Test func adaptiveSetsNoHostCeilingTheRuntimeRungGoverns() {
        let selections: [VMLXServerMTPSettings] = [
            .init(),  // untouched default (family default)
            .init(mode: .auto),  // On (Adaptive)
            .init(mode: .forceOn),  // legacy force-on without a depth button
            .init(mode: .auto, draftTokenLimit: 2),  // stale legacy limit
            .init(mode: .auto, draftTokenLimit: 99),
            .init(mode: .auto, explicitDepth: 1),  // stale manual depth under Auto
        ]
        for settings in selections {
            let policy = MLXBatchAdapter.nativeMTPDepthPolicy(settings)
            guard case .adaptive(let hostCeiling) = policy else {
                Issue.record("\(settings): \(policy) is not Adaptive")
                continue
            }
            // Whatever top rung vmlx reports for the loaded model (recursive head 5, LiLiCorr block 8 -> 7,
            // the exact verify window 7, a future 15) must survive the host's ceiling unchanged.
            for runtimeRung in [1, 3, 5, 6, 7, 8, 15, 64, 4096] {
                #expect(min(hostCeiling, runtimeRung) == runtimeRung, "\(settings): rung \(runtimeRung)")
            }
            #expect(policy == .adaptive(maximumDepth: MLXBatchAdapter.nativeMTPAdaptiveNoHostCeiling))
        }
    }

    @Test func offDoesNotOptIntoExploration() {
        #expect(MLXBatchAdapter.nativeMTPDepthPolicy(.init(mode: .off)) == .fixed)
    }

    @Test func autoIgnoresStaleManualDepthLikeTheLaunchResolver() {
        let settings = VMLXServerMTPSettings(mode: .auto, explicitDepth: 1)
        #expect(
            MLXBatchAdapter.nativeMTPDepthPolicy(settings)
                == .adaptive(maximumDepth: MLXBatchAdapter.nativeMTPAdaptiveNoHostCeiling))
    }

    /// The depth policy no longer reads `draftTokenLimit`; an invalid limit is still not silently repaired: the
    /// launch resolver reports it (and blocks the launch) where it is validated.
    @Test func invalidLimitIsNotSilentlyRepaired() {
        var settings = VMLXServerRuntimeSettings()
        settings.mtp = VMLXServerMTPSettings(mode: .auto)
        settings.mtp.draftTokenLimit = 0
        #expect(
            settings.validationIssues(mtpStatus: nil).contains {
                $0.severity == .error && $0.field == "mtp.draftTokenLimit"
            })
        #expect(settings.resolvedMTPLaunch(configData: nil, jangConfig: nil, status: nil).launchMode == .blocked)
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

    @Test func explicitDepthPrecedenceDoesNotDependOnResidentDepth() {
        for residentDepth in 1 ... 3 {
            for selectedDepth in 1 ... 3 {
                for legacyLimit in 1 ... 3 {
                    let loaded = DraftStrategy.nativeMTP(depth: residentDepth, verifierMode: nil)
                    let settings = VMLXServerMTPSettings(
                        mode: .forceOn, draftTokenLimit: legacyLimit, explicitDepth: selectedDepth)
                    let strategy = ModelRuntime.requestDraftStrategy(loaded, mtp: settings)
                    guard case .some(.nativeMTP(let resolvedDepth, _)) = strategy else {
                        Issue.record("explicit depth lost the resident native head")
                        continue
                    }
                    #expect(resolvedDepth == selectedDepth)
                    #expect(MLXBatchAdapter.nativeMTPDepthPolicy(settings) == .fixed)
                }
            }
        }
    }

    /// A legacy limit may only choose where Adaptive STARTS, never its top rung.
    @Test func autoDraftTokenLimitIsAStartNotACeiling() {
        let loaded = DraftStrategy.nativeMTP(depth: 3, verifierMode: nil)
        let settings = VMLXServerMTPSettings(mode: .auto, draftTokenLimit: 1)
        guard case .some(.nativeMTP(let depth, _)) = ModelRuntime.requestDraftStrategy(loaded, mtp: settings) else {
            Issue.record("Auto lost the resident native head")
            return
        }
        #expect(depth == 1)
        #expect(
            MLXBatchAdapter.nativeMTPDepthPolicy(settings)
                == .adaptive(maximumDepth: MLXBatchAdapter.nativeMTPAdaptiveNoHostCeiling))
    }

    @Test func depthOnlyChangesInvalidateTheSnapshotWithoutReloadingWeights() {
        var previous = VMLXServerRuntimeSettings()
        previous.mtp = .init(mode: .forceOn, explicitDepth: 1)
        var next = previous
        next.mtp.explicitDepth = 3
        #expect(ServerController.runtimeConfigInputsRequireInvalidate(previous: previous, next: next))
        #expect(!ServerController.loadedModelRuntimeInputsRequireRefresh(previous: previous, next: next))
    }

    @Test func changingFixedToAutoInvalidatesPolicyWithoutReloadingWeights() {
        var previous = VMLXServerRuntimeSettings()
        previous.mtp = .init(mode: .forceOn, explicitDepth: 3)
        var next = previous
        next.mtp = .init(mode: .auto)
        #expect(ServerController.runtimeConfigInputsRequireInvalidate(previous: previous, next: next))
        #expect(!ServerController.loadedModelRuntimeInputsRequireRefresh(previous: previous, next: next))
    }

    @Test func unchangedSettingsDoNotInvalidateTheSnapshot() {
        let settings = VMLXServerRuntimeSettings()
        #expect(!ServerController.runtimeConfigInputsRequireInvalidate(previous: settings, next: settings))
    }
}
