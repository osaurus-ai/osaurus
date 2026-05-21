//
//  ThemesDeepLinkRouter.swift
//  osaurus
//
//  Parses `osaurus://themes-install?hash=<sha256>` deep links and stages
//  the requested install on the management UI for ThemesView to pick up.
//

import Foundation

@MainActor
public enum ThemesDeepLinkRouter {

    /// Returns true when the URL was claimed by this router. Returns false
    /// for any URL not in the `osaurus://themes-install` shape so the
    /// caller can keep dispatching to other handlers.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ThemeShareService.deepLinkScheme,
            url.host?.lowercased() == ThemeShareService.deepLinkHost
        else { return false }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let raw = comps?.queryItems?.first(where: {
            $0.name.lowercased() == ThemeShareService.deepLinkHashParam
        })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let raw, ThemeShareService.isValidHash(raw) else { return false }

        ManagementStateManager.shared.selectedTab = .themes
        ManagementStateManager.shared.pendingThemeInstallHash = raw.lowercased()
        return true
    }
}
