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
            || previous.bundledDrafter != next.bundledDrafter
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

    static let bundledDrafterMigratedKey = "bundledDrafterFollowsExplicitOff"

    /// A drafter that ships inside a bundle drafts by default and has its own
    /// switch. Before that switch existed, choosing Off meant no speculation
    /// at all, so an explicit Off is carried over to it — once, so a user who
    /// later turns the bundled drafter back on keeps that choice.
    static func carryingExplicitOffToBundledDrafter(
        _ settings: VMLXServerMTPSettings,
        defaults: UserDefaults = .standard
    ) -> VMLXServerMTPSettings {
        guard !defaults.bool(forKey: bundledDrafterMigratedKey) else { return settings }
        defaults.set(true, forKey: bundledDrafterMigratedKey)
        guard defaults.bool(forKey: userChoseKey), settings.mode == .off else { return settings }
        var carried = settings
        carried.bundledDrafter = .off
        return carried
    }
}
