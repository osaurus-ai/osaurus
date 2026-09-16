import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite("Native MTP admission")
struct NativeMTPAdmissionTests {
    private var evidence: NativeMTPAdmission {
        NativeMTPAdmission(
            configData: Data(#"{"model_type":"qwen3_5","mtp_num_hidden_layers":1}"#.utf8),
            status: MTPBundleStatus(
                bundleHasMTP: true,
                configuredLayers: 1,
                tensorCount: 57,
                mode: .preservedEnabled
            )
        )
    }

    @Test func forceOnWithoutTuningFailsBeforeLoad() {
        var settings = VMLXServerRuntimeSettings()
        settings.mtp.mode = .forceOn
        #expect(throws: NativeMTPAdmission.Refusal.self) {
            try evidence.validateLoad(settings: settings, externalDrafterSelected: false)
        }
    }

    @Test func offAndUntunedAutoRemainValidPlainRequests() throws {
        for mode in [VMLXMTPServerMode.off, .auto] {
            #expect(try evidence.requestStrategy(loaded: nil, mtp: .init(mode: mode)) == nil)
            #expect(
                try evidence.requestStrategy(
                    loaded: .nativeMTP(depth: 3, verifierMode: nil),
                    mtp: .init(mode: mode)
                ) == nil
            )
        }
    }

    @Test func manualDepthsUseTheLoadedHeadAndPreserveSamplingPolicy() throws {
        for depth in 1 ... 3 {
            let result = try evidence.requestStrategy(
                loaded: .nativeMTP(depth: 1, verifierMode: nil),
                mtp: .init(mode: .forceOn, explicitDepth: depth)
            )
            #expect(result == .nativeMTP(depth: depth, verifierMode: nil))
        }
    }

    @Test func warmPlainHolderCannotSilentlyIgnoreExplicitActivation() {
        #expect(throws: NativeMTPAdmission.Refusal.self) {
            try evidence.requestStrategy(loaded: nil, mtp: .init(mode: .forceOn, explicitDepth: 2))
        }
    }

    @Test func warmManualHeadDoesNotBypassForceOnTuningRequirement() {
        #expect(throws: NativeMTPAdmission.Refusal.self) {
            try evidence.requestStrategy(
                loaded: .nativeMTP(depth: 3, verifierMode: nil),
                mtp: .init(mode: .forceOn)
            )
        }
    }

    @Test func absentEvidenceCannotCreateAHead() {
        #expect(throws: NativeMTPAdmission.Refusal.self) {
            try NativeMTPAdmission().requestStrategy(
                loaded: nil,
                mtp: .init(mode: .forceOn, explicitDepth: 1)
            )
        }
    }

    @Test func invalidDepthIsNotRepaired() {
        for depth in [0, 4] {
            #expect(throws: NativeMTPAdmission.Refusal.self) {
                try evidence.requestStrategy(
                    loaded: .nativeMTP(depth: 1, verifierMode: nil),
                    mtp: .init(mode: .forceOn, explicitDepth: depth)
                )
            }
        }
    }

    @Test func explicitlySelectedExternalDrafterKeepsItsSeparatePolicy() throws {
        var selected = evidence
        selected.externalDrafterSelected = true
        var settings = VMLXServerRuntimeSettings()
        settings.mtp.mode = .forceOn
        try selected.validateLoad(settings: settings, externalDrafterSelected: true)
        // A width rejected by the DFlash resolver retains its documented plain
        // fallback; a native-MTP refusal must not change that independent path.
        #expect(try selected.requestStrategy(loaded: nil, mtp: settings.mtp) == nil)
    }
}
