import Foundation
import MLXLMCommon

/// Retire automatic activation without replacing an explicit UI/configuration choice.
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
        case restoreOff
    }

    /// Used only by the one-shot settings migration, never by model selection.
    /// Match the entire old default, including drafter/cache fields, so unknown
    /// custom configurations are not mistaken for an untouched factory value.
    static func action(
        settings: VMLXServerMTPSettings,
        userHasChosen: Bool,
        ownsCurrentValue: Bool
    ) -> Action {
        guard !userHasChosen else { return .keep }
        if settings == .init(mode: .auto) {
            return .restoreOff
        }
        return ownsCurrentValue && settings == .init(mode: .forceOn, explicitDepth: 3)
            ? .restoreOff : .keep
    }
}
