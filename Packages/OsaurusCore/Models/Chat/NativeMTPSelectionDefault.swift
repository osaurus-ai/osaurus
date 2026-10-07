import Foundation
import MLXLMCommon

/// Selecting a model discovers the family-default capability without loading it.
/// Preserve explicit Off/Adaptive and historical provenance; never infer that a
/// persisted Off was unintentional.
enum NativeMTPSelectionDefault {
    static let userChoseKey = "nativeMTPSegmentUserChose"
    static let familyDefaultKey = "nativeMTPSegmentIsFamilyDefault"

    /// Product controls expose only Off (AR) and On (Adaptive). Keep the
    /// engine's legacy fields decodable, but never persist a native depth cap.
    /// External DFlash selection and its block size are independent.
    static func adaptiveSelection(_ settings: VMLXServerMTPSettings) -> VMLXServerMTPSettings {
        var result = settings
        // Off and the family default are kept as-is; everything else is On (Adaptive).
        result.mode = (settings.mode == .off || settings.mode == .familyDefault) ? settings.mode : .auto
        result.explicitDepth = nil
        result.draftTokenLimit = nil
        return result
    }

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
