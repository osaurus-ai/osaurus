import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite struct NativeMTPSelectionDefaultTests {
    @Test func savedChoiceProvenancePreservesAutoWithoutClaimingUnrelatedEdits() throws {
        let name = "MTPChoiceProof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let automatic = VMLXServerMTPSettings(mode: .auto)
        let d3 = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: 3)

        // An untouched MTP section in another settings save stays factory-owned.
        NativeMTPSelectionDefault.recordSavedChoice(
            previous: automatic,
            next: automatic,
            isFamilyDefault: false,
            defaults: defaults
        )
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))

        NativeMTPSelectionDefault.recordSavedChoice(
            previous: automatic,
            next: d3,
            isFamilyDefault: true,
            defaults: defaults
        )
        #expect(defaults.bool(forKey: NativeMTPSelectionDefault.familyDefaultKey))
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))

        // Settings/API Auto after the D3 default is an explicit choice.
        NativeMTPSelectionDefault.recordSavedChoice(
            previous: d3,
            next: automatic,
            isFamilyDefault: false,
            defaults: defaults
        )
        #expect(defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.familyDefaultKey))
        #expect(
            NativeMTPSelectionDefault.action(
                settings: automatic,
                eligible: true,
                userHasChosen: defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey),
                ownsCurrentValue: defaults.bool(forKey: NativeMTPSelectionDefault.familyDefaultKey)
            ) == .keep
        )
    }

    @Test func familyRestoreDoesNotBecomeAUserChoice() throws {
        let name = "MTPChoiceProof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        NativeMTPSelectionDefault.recordSavedChoice(
            previous: .init(mode: .forceOn, explicitDepth: 3),
            next: .init(mode: .auto),
            isFamilyDefault: true,
            defaults: defaults
        )
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.familyDefaultKey))
    }

    private func status(tensors: Int = 31, blocked: Bool = false) -> MTPBundleStatus {
        MTPBundleStatus(
            bundleHasMTP: tensors > 0,
            configuredLayers: 1,
            tensorCount: tensors,
            mode: tensors > 0 ? .preservedEnabled : .metadataOnlyMissingWeights,
            nativeMTPTuning: blocked ? NativeMTPTuning(manualBlocked: true) : nil
        )
    }

    @Test func bothTargetArchitecturesUseTheActivationGate() {
        for type in ["qwen4_exp", "qwen3_5"] {
            let config = Data("{\"model_type\":\"\(type)\"}".utf8)
            #expect(NativeMTPSelectionDefault.isEligible(configData: config, status: status()))
            #expect(!NativeMTPSelectionDefault.isEligible(configData: config, status: status(tensors: 0)))
            #expect(!NativeMTPSelectionDefault.isEligible(configData: config, status: status(blocked: true)))
        }
    }

    @Test func unrelatedAndMalformedConfigurationsDoNotReceiveTheDefault() {
        for config in ["{\"model_type\":\"qwen3_5_moe\"}", "{\"model_type\":\"glm5_next\"}", "{}", "bad"] {
            #expect(!NativeMTPSelectionDefault.isEligible(configData: Data(config.utf8), status: status()))
        }
    }

    @Test func onlyFactoryAutoReceivesDepthThree() {
        #expect(
            NativeMTPSelectionDefault.action(
                settings: .init(mode: .auto),
                eligible: true,
                userHasChosen: false,
                ownsCurrentValue: false
            ) == .selectDepthThree
        )
        for settings in [
            VMLXServerMTPSettings(mode: .off), .init(mode: .forceOn, explicitDepth: 2),
            .init(mode: .auto, draftTokenLimit: 1),
        ] {
            #expect(
                NativeMTPSelectionDefault.action(
                    settings: settings,
                    eligible: true,
                    userHasChosen: false,
                    ownsCurrentValue: false
                ) == .keep
            )
        }
    }

    @Test func explicitUserAutoAndOffArePreserved() {
        for eligible in [true, false] {
            for settings in [
                VMLXServerMTPSettings(mode: .auto), .init(mode: .off),
                .init(mode: .forceOn, explicitDepth: 3),
            ] {
                #expect(
                    NativeMTPSelectionDefault.action(
                        settings: settings,
                        eligible: eligible,
                        userHasChosen: true,
                        ownsCurrentValue: true
                    ) == .keep
                )
            }
        }
    }

    @Test func switchingBetweenEligibleFamiliesKeepsOwnedDepthThree() {
        #expect(
            NativeMTPSelectionDefault.action(
                settings: .init(mode: .forceOn, explicitDepth: 3),
                eligible: true,
                userHasChosen: false,
                ownsCurrentValue: true
            ) == .keep
        )
    }

    @Test func leavingFamilyRestoresOnlyAnUnmodifiedOwnedDefault() {
        let original = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: 3)
        #expect(
            NativeMTPSelectionDefault.action(
                settings: original,
                eligible: false,
                userHasChosen: false,
                ownsCurrentValue: true
            ) == .restoreAuto
        )
        #expect(
            NativeMTPSelectionDefault.action(
                settings: original,
                eligible: false,
                userHasChosen: false,
                ownsCurrentValue: false
            ) == .keep
        )
        var changed = original
        changed.draftTokenLimit = 1
        #expect(
            NativeMTPSelectionDefault.action(
                settings: changed,
                eligible: false,
                userHasChosen: false,
                ownsCurrentValue: true
            ) == .keep
        )
    }
}
