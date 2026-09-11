import Foundation
import MLXLMCommon

/// Family defaults do not replace an explicit UI or configuration choice.
enum NativeMTPSelectionDefault {
    static let userChoseKey = "nativeMTPSegmentUserChose"
    static let familyDefaultKey = "nativeMTPSegmentIsFamilyDefault"

    /// Called only after the runtime settings write succeeds. A sampler or
    /// network edit must not turn a factory MTP default into a user choice.
    static func recordSavedChoice(
        previous: VMLXServerMTPSettings,
        next: VMLXServerMTPSettings,
        isFamilyDefault: Bool,
        defaults: UserDefaults = .standard
    ) {
        if isFamilyDefault {
            defaults.set(
                next.mode == .forceOn && next.explicitDepth == 3 && next.draftTokenLimit == nil,
                forKey: familyDefaultKey
            )
        } else if previous.mode != next.mode || previous.explicitDepth != next.explicitDepth
            || previous.draftTokenLimit != next.draftTokenLimit
        {
            defaults.set(true, forKey: userChoseKey)
            defaults.set(false, forKey: familyDefaultKey)
        }
    }

    enum Action: Equatable {
        case keep
        case selectDepthThree
        case restoreAuto
    }

    /// Reuse the runtime's family and activation gates. In particular, the
    /// Flash-Next legacy-layout advisory is not a Qwen27B eligibility test.
    static func isEligible(bundleDirectory: URL) -> Bool {
        guard let config = try? Data(contentsOf: bundleDirectory.appendingPathComponent("config.json")),
            let status = try? MTPBundleInspector.inspect(modelDirectory: bundleDirectory)
        else { return false }
        return isEligible(configData: config, status: status)
    }

    static func isEligible(configData: Data, status: MTPBundleStatus) -> Bool {
        guard ModelRuntime.modelTypeIsMTPControlTarget(configData: configData) else { return false }
        return NativeMTPAutoDecodePolicy.manualRecommendation(
            depth: 3,
            configData: configData,
            jangConfig: nil,
            status: status
        ) != nil
    }

    static func action(
        settings: VMLXServerMTPSettings,
        eligible: Bool,
        userHasChosen: Bool,
        ownsCurrentValue: Bool
    ) -> Action {
        guard !userHasChosen else { return .keep }
        if eligible {
            return settings.mode == .auto && settings.explicitDepth == nil
                && settings.draftTokenLimit == nil ? .selectDepthThree : .keep
        }
        return ownsCurrentValue && settings.mode == .forceOn && settings.explicitDepth == 3
            && settings.draftTokenLimit == nil ? .restoreAuto : .keep
    }
}
