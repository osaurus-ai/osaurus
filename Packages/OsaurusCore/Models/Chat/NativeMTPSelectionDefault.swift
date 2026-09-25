import Foundation
import MLXLMCommon

/// Native MTP is opt-in. Selecting a model only discovers capability; it never
/// activates speculation. Retain the old provenance keys so an automatic
/// family default can be retired without overwriting an explicit choice.
enum NativeMTPSelectionDefault {
    static let userChoseKey = "nativeMTPSegmentUserChose"
    static let familyDefaultKey = "nativeMTPSegmentIsFamilyDefault"

    /// Called only after the runtime settings write succeeds. An unrelated
    /// sampler or network edit must not become an explicit MTP choice.
    static func recordSavedChoice(
        previous: VMLXServerMTPSettings,
        next: VMLXServerMTPSettings,
        isFamilyDefault: Bool,
        defaults: UserDefaults = .standard
    ) {
        if isFamilyDefault {
            defaults.set(next == .init(mode: .off), forKey: familyDefaultKey)
        } else if previous.mode != next.mode || previous.explicitDepth != next.explicitDepth
            || previous.draftTokenLimit != next.draftTokenLimit
        {
            defaults.set(true, forKey: userChoseKey)
            defaults.set(false, forKey: familyDefaultKey)
        }
    }

    /// Runs in the shared settings load path, including API-only startup.
    /// Only provenance-tagged, unmodified values from the old family selector
    /// are ours to replace. A persisted Auto with unknown provenance is kept.
    static func retiringOwnedDefault(
        _ settings: VMLXServerMTPSettings,
        defaults: UserDefaults = .standard
    ) -> VMLXServerMTPSettings {
        guard !defaults.bool(forKey: userChoseKey),
            defaults.bool(forKey: familyDefaultKey),
            settings == .init(mode: .forceOn, explicitDepth: 3)
                || settings == .init(mode: .auto)
        else { return settings }
        return .init(mode: .off)
    }
}
