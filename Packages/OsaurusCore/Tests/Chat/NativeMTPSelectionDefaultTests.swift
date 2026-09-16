import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

@Suite struct NativeMTPSelectionDefaultTests {
    @Test func onlyOwnedUnmodifiedDefaultsAreRetired() throws {
        let name = "MTPChoiceProof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for chosen in [false, true] {
            for owned in [false, true] {
                defaults.set(chosen, forKey: NativeMTPSelectionDefault.userChoseKey)
                defaults.set(owned, forKey: NativeMTPSelectionDefault.familyDefaultKey)
                for settings in [
                    VMLXServerMTPSettings(mode: .off), .init(mode: .auto),
                    .init(mode: .forceOn, explicitDepth: 1),
                    .init(mode: .forceOn, explicitDepth: 2),
                    .init(mode: .forceOn, explicitDepth: 3),
                    .init(mode: .auto, draftTokenLimit: 1),
                    .init(mode: .forceOn, dflash2DrafterPath: "/explicit/drafter", explicitDepth: 3),
                ] {
                    let oldDefault = settings == .init(mode: .auto)
                        || settings == .init(mode: .forceOn, explicitDepth: 3)
                    let expected: VMLXServerMTPSettings = !chosen && owned && oldDefault
                        ? .init(mode: .off) : settings
                    #expect(NativeMTPSelectionDefault.retiringOwnedDefault(
                        settings, defaults: defaults) == expected)
                }
            }
        }
    }

    @Test func explicitChoicesOutrankDefaultProvenance() throws {
        let name = "MTPChoiceProof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        NativeMTPSelectionDefault.recordSavedChoice(
            previous: .init(mode: .off), next: .init(mode: .off),
            isFamilyDefault: false, defaults: defaults)
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))
        NativeMTPSelectionDefault.recordSavedChoice(
            previous: .init(mode: .forceOn, explicitDepth: 3), next: .init(mode: .off),
            isFamilyDefault: true, defaults: defaults)
        #expect(defaults.bool(forKey: NativeMTPSelectionDefault.familyDefaultKey))
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))
        NativeMTPSelectionDefault.recordSavedChoice(
            previous: .init(mode: .off), next: .init(mode: .auto),
            isFamilyDefault: false, defaults: defaults)
        #expect(defaults.bool(forKey: NativeMTPSelectionDefault.userChoseKey))
        #expect(!defaults.bool(forKey: NativeMTPSelectionDefault.familyDefaultKey))
        #expect(NativeMTPSelectionDefault.retiringOwnedDefault(
            .init(mode: .auto), defaults: defaults).mode == .auto)
    }
}
