//
//  WorkspacesDeepLinkRouter.swift
//  osaurus
//
//  Parses the two Workspaces deep links and stages them on `WorkspacesService` for the
//  Workspaces tab to confirm and redeem (never automatically):
//
//    osaurus://workspaces/activate?code=<code>[&name=<workspace name>][&plan=<label>]
//        — hand-off of an activation code: a subscription bought on
//          osaurus.ai before the buyer had a wallet, or an admin comp.
//          (In-app purchases don't use this: they go through Stripe
//          Checkout and land by webhook, see `WorkspacesService`.)
//    osaurus://workspaces/join?code=<code>
//        — an invite link minted by a workspace owner/admin
//
//  The feature shipped briefly as "Teams", so `osaurus://teams/...` is still
//  accepted as a legacy host: invite links the router minted under the old
//  name stay valid for their 14-day lifetime, and the web/router flip to the
//  new host independently of the app release.
//

import Foundation

@MainActor
enum WorkspacesDeepLinkRouter {
    nonisolated static let host = "workspaces"
    /// Host used before the rename; still routed here so already-minted
    /// links keep working.
    nonisolated static let legacyHost = "teams"
    nonisolated static let hosts: Set<String> = [host, legacyHost]
    nonisolated static let activatePath = "/activate"
    nonisolated static let joinPath = "/join"

    /// True when `url` is an `osaurus://` link on the current or legacy host.
    nonisolated static func claims(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "osaurus"
            && hosts.contains(url.host?.lowercased() ?? "")
    }

    /// Rewrites a legacy `osaurus://teams/...` link to the current host so
    /// links the router still mints under the old name are displayed and
    /// copied in the new form. Anything else is returned untouched.
    nonisolated static func normalized(_ link: String) -> String {
        let prefix = "osaurus://\(legacyHost)/"
        guard link.lowercased().hasPrefix(prefix) else { return link }
        return "osaurus://\(host)/" + link.dropFirst(prefix.count)
    }

    /// Pure parse so the shape can be unit-tested without the main-actor
    /// service. `nil` for anything that isn't a well-formed activation link.
    nonisolated static func parseActivation(_ url: URL) -> PendingWorkspaceActivation? {
        guard isWorkspacesLink(url, path: activatePath),
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let code = plausibleCode(in: items)
        else { return nil }

        let name = value("name", in: items).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
        let plan = value("plan", in: items).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        return PendingWorkspaceActivation(code: code, suggestedName: name, planLabel: plan)
    }

    /// `nil` for anything that isn't a well-formed invite link.
    nonisolated static func parseJoin(_ url: URL) -> PendingWorkspaceJoin? {
        guard isWorkspacesLink(url, path: joinPath),
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let code = plausibleCode(in: items)
        else { return nil }
        return PendingWorkspaceJoin(code: code)
    }

    /// Returns true when the URL was claimed by this router (host `workspaces`),
    /// even if malformed — a bad Workspaces link must not fall through to the
    /// default pairing handler. Malformed links surface a toast.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard claims(url) else { return false }

        if let activation = parseActivation(url) {
            ManagementStateManager.shared.selectedTab = .workspaces
            WorkspacesService.shared.pendingActivation = activation
            return true
        }
        if let join = parseJoin(url) {
            ManagementStateManager.shared.selectedTab = .workspaces
            WorkspacesService.shared.pendingJoin = join
            return true
        }

        ToastManager.shared.error(
            L("Invalid Workspaces link"),
            message: url.path == joinPath
                ? L("The invite link is incomplete. Ask your teammate to share it again.")
                : L("The activation link is incomplete. Open osaurus.ai/workspaces and try again.")
        )
        return true
    }

    // MARK: - Helpers

    private nonisolated static func isWorkspacesLink(_ url: URL, path: String) -> Bool {
        claims(url) && url.path == path
    }

    private nonisolated static func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name.lowercased() == name }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func plausibleCode(in items: [URLQueryItem]) -> String? {
        guard let code = value("code", in: items), OsaurusRouterWorkspaceCode.isPlausible(code) else {
            return nil
        }
        return code
    }
}
