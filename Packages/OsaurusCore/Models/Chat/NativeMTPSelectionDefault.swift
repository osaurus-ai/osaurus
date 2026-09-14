import Foundation
import MLXLMCommon

/// Flash Next starts Off; eligible Qwen27B retains its existing D3 default.
/// Family defaults never replace an explicit UI or configuration choice.
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
                next == .init(mode: .off)
                    || (next.mode == .forceOn && next.explicitDepth == 3 && next.draftTokenLimit == nil),
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
        case selectOff
        case selectDepthThree
        case restoreAuto
    }

    /// Architecture evidence only: renaming a bundle cannot disable Qwen27B.
    static func startsOff(bundleDirectory: URL) -> Bool {
        guard let config = try? Data(contentsOf: bundleDirectory.appendingPathComponent("config.json"))
        else { return false }
        return startsOff(configData: config)
    }

    static func startsOff(configData: Data) -> Bool {
        guard let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any]
        else { return false }
        let types = [
            config["model_type"] as? String,
            (config["text_config"] as? [String: Any])?["model_type"] as? String,
        ]
        return types.contains("qwen4_exp")
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
        startsOff: Bool = false,
        userHasChosen: Bool,
        ownsCurrentValue: Bool
    ) -> Action {
        guard !userHasChosen else { return .keep }
        let ownedOff = ownsCurrentValue && settings == .init(mode: .off)
        if startsOff {
            let ownedDepthThree = ownsCurrentValue
                && settings == .init(mode: .forceOn, explicitDepth: 3)
            return settings == .init(mode: .auto) || ownedDepthThree ? .selectOff : .keep
        }
        if eligible {
            // Leaving Flash Next must not carry its automatic Off into 27B.
            if ownedOff { return .selectDepthThree }
            return settings.mode == .auto && settings.explicitDepth == nil
                && settings.draftTokenLimit == nil ? .selectDepthThree : .keep
        }
        if ownedOff { return .restoreAuto }
        return ownsCurrentValue && settings.mode == .forceOn && settings.explicitDepth == 3
            && settings.draftTokenLimit == nil ? .restoreAuto : .keep
    }
}
