import Foundation
import MLXLMCommon
import Testing
@testable import OsaurusCore

@Suite struct NativeMTPAdaptiveSelectionTests {
    @Test func defaultsAndExplicitOffRemainAR() {
        for depth in [nil, 1, 2, 3] as [Int?] {
            let result = NativeMTPSelectionDefault.adaptiveSelection(
                .init(mode: .off, draftTokenLimit: depth, explicitDepth: depth))
            #expect(result.mode == .off)
            #expect(result.explicitDepth == nil && result.draftTokenLimit == nil)
        }
        #expect(NativeMTPSelectionDefault.adaptiveSelection(.init()).mode == .off)
    }

    @Test func legacyPositiveSelectionsBecomeUncappedAdaptive() {
        for mode in [VMLXMTPServerMode.auto, .forceOn] {
            for depth in 1...3 {
                let result = NativeMTPSelectionDefault.adaptiveSelection(
                    .init(mode: mode, draftTokenLimit: depth, explicitDepth: depth))
                #expect(result.mode == .auto)
                #expect(result.explicitDepth == nil && result.draftTokenLimit == nil)
                #expect(MLXBatchAdapter.nativeMTPDepthPolicy(result) == .adaptive(maximumDepth: 5))
                #expect(ModelRuntime.requestDraftStrategy(nil, mtp: result) == nil)
                #expect(NativeMTPSelectionDefault.adaptiveSelection(result) == result)
            }
        }
    }

    @Test func migrationDoesNotTouchExternalDrafterOrSafetyInvariants() {
        var old = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: 3)
        old.dflash2DrafterPath = "/fixture/external-drafter"
        old.dflash2BlockSize = 8
        let next = NativeMTPSelectionDefault.adaptiveSelection(old)
        #expect(next.dflash2DrafterPath == old.dflash2DrafterPath)
        #expect(next.dflash2BlockSize == old.dflash2BlockSize)
        #expect(next.keepDraftCacheSeparate == old.keepDraftCacheSeparate)
        #expect(next.acceptedTokensOnlyEnterBaseCache == old.acceptedTokensOnlyEnterBaseCache)
    }

    @Test func selectedExternalDrafterEffectiveWidthIsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"vocab_size":100,"num_target_layers":2,"dflash_config":{"selector_top_k":1,"selector_rank":1,"conv_kernel_size":2,"target_layer_ids":[0,1],"block_size":8}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let target = Data(#"{"model_type":"qwen3_5","vocab_size":100,"num_hidden_layers":2}"#.utf8)
        for block in [nil, 4, 8] as [Int?] {
            for limit in 1...3 {
                var before = VMLXServerRuntimeSettings()
                before.mtp = .init(mode: .forceOn, draftTokenLimit: limit, explicitDepth: 3)
                before.mtp.dflash2DrafterPath = directory.path
                before.mtp.dflash2BlockSize = block
                var after = before
                after.mtp = NativeMTPSelectionDefault.adaptiveSelection(before.mtp)
                for settings in [before, after] {
                    let strategy = settings.resolvedMTPDraftStrategy(configData: target, jangConfig: nil, status: nil)
                    guard case .dflash2(let path, let width)? = strategy else {
                        Issue.record("Selected external drafter must retain precedence")
                        continue
                    }
                    #expect(path == directory)
                    #expect(width == block)
                    let info = try #require(settings.resolvedDFlash2Selection(configData: target))
                    #expect((width ?? info.blockSize) == (block ?? 8))
                }
            }
        }
    }

    @Test func formerlyManualAdmissionIsRecheckedWithoutReload() throws {
        let old = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: 3)
        let next = NativeMTPSelectionDefault.adaptiveSelection(old)
        #expect(!ServerController.mtpLoadInputsChanged(previous: old, next: next))
        let evidence = NativeMTPAdmission(
            configData: Data(#"{"model_type":"qwen3_5","mtp_num_hidden_layers":1}"#.utf8),
            status: MTPBundleStatus(bundleHasMTP: true, configuredLayers: 1,
                                    tensorCount: 57, mode: .preservedEnabled))
        #expect(try evidence.requestStrategy(loaded: .nativeMTP(depth: 3, verifierMode: nil), mtp: next) == nil)

        #expect(!ServerController.mtpLoadInputsChanged(previous: next, next: next))
        #expect(ServerController.mtpLoadInputsChanged(previous: .init(mode: .off), next: next))
    }
}
