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

    @Test func untouchedFactoryAutoRetiresToOff() {
        #expect(
            NativeMTPSelectionDefault.action(
                settings: .init(mode: .auto),
                userHasChosen: false,
                ownsCurrentValue: false
            ) == .restoreOff
        )
        for settings in [
            VMLXServerMTPSettings(mode: .off), .init(mode: .forceOn, explicitDepth: 2),
            .init(mode: .auto, draftTokenLimit: 1),
            .init(mode: .auto, keepDraftCacheSeparate: false),
            .init(mode: .auto, acceptedTokensOnlyEnterBaseCache: false),
            .init(mode: .auto, dflash2DrafterPath: "/explicit/drafter"),
            .init(mode: .auto, dflash2BlockSize: 8),
        ] {
            #expect(
                NativeMTPSelectionDefault.action(
                    settings: settings,
                    userHasChosen: false,
                    ownsCurrentValue: false
                ) == .keep
            )
        }
    }

    @Test func everyExplicitUserChoiceIsPreserved() {
        for owned in [true, false] {
            for settings in [
                VMLXServerMTPSettings(mode: .auto), .init(mode: .off),
                .init(mode: .forceOn, explicitDepth: 1),
                .init(mode: .forceOn, explicitDepth: 2),
                .init(mode: .forceOn, explicitDepth: 3),
            ] {
                #expect(
                    NativeMTPSelectionDefault.action(
                        settings: settings,
                        userHasChosen: true,
                        ownsCurrentValue: owned
                    ) == .keep
                )
            }
        }
    }

    @Test func previousFamilyOwnedDepthThreeRetiresToOff() {
        #expect(
            NativeMTPSelectionDefault.action(
                settings: .init(mode: .forceOn, explicitDepth: 3),
                userHasChosen: false,
                ownsCurrentValue: true
            ) == .restoreOff
        )
    }

    @Test func migrationRestoresOnlyAnUnmodifiedOwnedDefault() {
        let original = VMLXServerMTPSettings(mode: .forceOn, explicitDepth: 3)
        #expect(
            NativeMTPSelectionDefault.action(
                settings: original,
                userHasChosen: false,
                ownsCurrentValue: true
            ) == .restoreOff
        )
        #expect(
            NativeMTPSelectionDefault.action(
                settings: original,
                userHasChosen: false,
                ownsCurrentValue: false
            ) == .keep
        )
        var changed = original
        changed.draftTokenLimit = 1
        #expect(
            NativeMTPSelectionDefault.action(
                settings: changed,
                userHasChosen: false,
                ownsCurrentValue: true
            ) == .keep
        )
    }
}
