//
//  WhatsNewGate.swift
//  osaurus
//
//  Decides when to show the "What's New" modal automatically.
//  Shown exactly once per user per version only after an update
//  (never on fresh installs)
//

import Foundation
import OsaurusRepository

public enum WhatsNewGate {
    private static let defaultsKey = "lastShownWhatsNewVersion"

    /// Set to true once we've checked in the current launch, so multiple
    /// chat windows don't each try to present the modal.
    @MainActor private static var didCheckThisLaunch = false

    /// Current app version from Info.plist.
    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The release to present automatically on first launch after an update,
    /// or `nil` if nothing should be shown.
    ///
    /// When a user skips one or more versions (e.g. 0.15 → 0.17), every
    /// intermediate release that has notes is aggregated into a single
    /// carousel, ordered oldest → newest. The synthesized release carries
    /// the current version as its `version` so the header reads naturally.
    ///
    /// `hasSandbox` and `hasLegacyPairedKeys` toggle conditional pages in
    /// the security release: users who never used the sandbox should not see
    /// the "restart sandbox" page, and users with no legacy keys should not
    /// see the "review paired devices" page. Defaults are `true` so callers
    /// that don't yet know skip nothing.
    ///
    /// Rules:
    /// - Fresh install (no stored version): record current, return nil.
    /// - Stored < current AND one or more intermediate releases have notes:
    ///   return a combined release with all of their pages.
    /// - Otherwise: record current and return nil.
    @MainActor
    public static func pendingAutoShowRelease(
        hasSandbox: Bool = true,
        hasLegacyPairedKeys: Bool = true
    ) -> WhatsNewRelease? {
        guard !didCheckThisLaunch else { return nil }
        didCheckThisLaunch = true

        let defaults = UserDefaults.standard
        let current = currentVersion

        guard let stored = defaults.string(forKey: defaultsKey) else {
            // fresh install: record without prompting
            defaults.set(current, forKey: defaultsKey)
            return nil
        }

        guard stored != current else { return nil }

        // require both sides to parse as semver so we can safely aggregate
        // intermediate releases. if either side is unparseable, fall back
        // to showing notes for the current version only
        guard
            let lhs = SemanticVersion.parse(stored),
            let rhs = SemanticVersion.parse(current),
            lhs < rhs
        else {
            let fallback = WhatsNewContent.release(for: current)
                .map { Self.filterPages($0, hasSandbox: hasSandbox, hasLegacyPairedKeys: hasLegacyPairedKeys) }
            if fallback == nil || fallback?.pages.isEmpty == true {
                defaults.set(current, forKey: defaultsKey)
                return nil
            }
            return fallback
        }

        let intermediate = WhatsNewContent.releases(after: lhs, upTo: rhs)
        let pages =
            intermediate
            .map { Self.filterPages($0, hasSandbox: hasSandbox, hasLegacyPairedKeys: hasLegacyPairedKeys) }
            .flatMap { $0.pages }
        guard !pages.isEmpty else {
            // no notes in the skipped range (or all pages filtered out);
            // still advance the marker so we don't keep re-checking on every launch
            defaults.set(current, forKey: defaultsKey)
            return nil
        }

        // flatten all pages into a single carousel. Header shows current.
        return WhatsNewRelease(version: current, pages: pages)
    }

    /// Drop pages whose `id` is gated on a runtime condition (e.g. the
    /// "restart sandbox" page only makes sense if the user actually has a
    /// provisioned sandbox). Page ids gating on `hasSandbox` use the suffix
    /// `:sandbox`; pages gating on `hasLegacyPairedKeys` use `:legacy-keys`.
    /// Pages without a gate suffix always pass through.
    /// Internal so tests can exercise the predicate without touching
    /// UserDefaults or the once-per-launch guard.
    static func filterPages(
        _ release: WhatsNewRelease,
        hasSandbox: Bool,
        hasLegacyPairedKeys: Bool
    ) -> WhatsNewRelease {
        let filtered = release.pages.filter { page in
            if page.id.hasSuffix(":sandbox") { return hasSandbox }
            if page.id.hasSuffix(":legacy-keys") { return hasLegacyPairedKeys }
            return true
        }
        return WhatsNewRelease(version: release.version, pages: filtered)
    }

    /// Record that the user has seen the notes for `version`.
    public static func markShown(version: String) {
        UserDefaults.standard.set(version, forKey: defaultsKey)
    }
}
