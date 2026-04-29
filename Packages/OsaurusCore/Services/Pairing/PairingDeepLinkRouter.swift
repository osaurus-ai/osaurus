//
//  PairingDeepLinkRouter.swift
//  osaurus
//
//  Parses `osaurus://<addr>?pair=<base64url(invite)>` deeplinks and stages
//  the decoded invite for the receiver's UI to approve.
//

import Foundation

@MainActor
public enum PairingDeepLinkRouter {

    /// Returns true when the URL was claimed by the pairing router (regardless
    /// of decode success — bad URLs surface as a toast). Returns false for any
    /// URL not in the `osaurus://` scheme so other handlers (e.g. Hugging Face)
    /// can take over.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "osaurus" else { return false }

        do {
            let invite = try AgentInvite.decode(from: url)
            // Validate signature + expiry early so the receiver UI doesn't
            // even render an obviously-broken invite.
            try invite.verifySignature()
            guard !invite.isExpired else {
                ToastManager.shared.error(
                    "Invite expired",
                    message: "This invite expired \(invite.expirationDate.formatted())."
                )
                return true
            }
            IncomingPairCoordinator.shared.pendingInvite = invite
        } catch let error as AgentInviteError {
            ToastManager.shared.error("Invalid invite", message: error.errorDescription)
        } catch {
            ToastManager.shared.error(
                "Invalid invite",
                message: error.localizedDescription
            )
        }
        return true
    }
}
