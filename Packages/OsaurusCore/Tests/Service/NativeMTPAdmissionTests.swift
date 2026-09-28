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

    @Test func manualDepthsUseTheLoadedHead() throws {
        for depth in 1 ... 3 {
            let result = try evidence.requestStrategy(
                loaded: .nativeMTP(depth: 1, verifierMode: nil),
                mtp: .init(mode: .forceOn, explicitDepth: depth)
            )
            guard case .nativeMTP(let actualDepth, let verifierMode)? = result else {
                Issue.record("Expected the selected native depth")
                continue
            }
            #expect(actualDepth == depth)
            #expect(verifierMode == nil)
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

    // MARK: - A drafter shipped in the bundle

    /// A Spark2.5-shaped bundle with a fitting drafter in `dflash/`.
    private static func bundleWithDrafter() throws -> (dir: URL, config: Data) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-drafter-\(UUID().uuidString)")
        let drafter = dir.appendingPathComponent("dflash")
        try FileManager.default.createDirectory(at: drafter, withIntermediateDirectories: true)
        let config = Data(
            #"{"model_type":"spark2_5","vocab_size":131072,"num_hidden_layers":36,"hidden_size":2560}"#.utf8)
        try config.write(to: dir.appendingPathComponent("config.json"))
        try Data(
            #"""
            {"model_type":"qwen3","hidden_size":2560,"vocab_size":131072,"num_target_layers":36,
             "dflash_config":{"block_size":8,"selector_top_k":16,"selector_rank":256,
             "conv_kernel_size":2,"target_layer_ids":[1,9,17,25,33]}}
            """#.utf8
        ).write(to: drafter.appendingPathComponent("config.json"))
        return (dir, config)
    }

    @Test func bundledDrafterDraftsWithDefaultSettings() throws {
        let (dir, config) = try Self.bundleWithDrafter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let admission = NativeMTPAdmission(configData: config, modelDirectory: dir)
        let strategy = try admission.requestStrategy(loaded: nil, mtp: .init())
        #expect(strategy?.dflash2DrafterPath?.lastPathComponent == "dflash")
        #expect(admission.dflash2Status(mtp: .init())?.contains("ships with") == true)
    }

    @Test func turningTheBundledDrafterOffAppliesToTheNextRequest() throws {
        let (dir, config) = try Self.bundleWithDrafter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let admission = NativeMTPAdmission(configData: config, modelDirectory: dir)
        let loaded = try admission.requestStrategy(loaded: nil, mtp: .init())
        // Loaded drafting; the user turns it off — plain decode, no refusal.
        for mode in [VMLXMTPServerMode.off, .auto] {
            let off = VMLXServerMTPSettings(mode: mode, bundledDrafter: .off)
            #expect(try admission.requestStrategy(loaded: loaded, mtp: off) == nil)
        }
        // Force On with the drafter off asks for a native head this model
        // does not have; that refusal is the native path's own contract and
        // the drafter must not mask it.
        #expect(throws: NativeMTPAdmission.Refusal.self) {
            try admission.requestStrategy(
                loaded: loaded, mtp: .init(mode: .forceOn, bundledDrafter: .off))
        }
        #expect(
            admission.dflash2Status(mtp: .init(bundledDrafter: .off))
                == "The bundled DFlash 2 drafter is turned off.")
        // …and back on, still without a reload.
        #expect(try admission.requestStrategy(loaded: nil, mtp: .init())?.dflash2DrafterPath != nil)
    }

    @Test func bundledDrafterIsNotRefusedByABlockedNativeHead() throws {
        let (dir, config) = try Self.bundleWithDrafter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let admission = NativeMTPAdmission(configData: config, modelDirectory: dir)
        var settings = VMLXServerRuntimeSettings()
        settings.mtp.mode = .forceOn
        #expect(admission.dflash2Selection(mtp: settings.mtp) != nil)
        #expect(throws: Never.self) {
            try admission.validateLoad(
                settings: settings,
                externalDrafterSelected: admission.dflash2Selection(mtp: settings.mtp) != nil)
        }
    }

    @Test func aModelWithoutADrafterIsUnchanged() throws {
        #expect(try NativeMTPAdmission().requestStrategy(loaded: nil, mtp: .init()) == nil)
        #expect(NativeMTPAdmission().dflash2Status(mtp: .init()) == nil)
    }
}
