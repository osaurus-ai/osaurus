import Foundation

enum ChatErrorMessages {
    static func assistantMessage(for error: Error) -> String {
        let description = error.localizedDescription
        // Workspace check first: the personal matcher explicitly excludes the
        // workspace code, but ordering here keeps the intent obvious. A dry workspace
        // pool must never suggest a personal top-up — there is no fallback
        // from workspace billing to personal credits.
        if OsaurusRouter.isWorkspaceInsufficientFundsError(description) {
            // The router fires an auto-reload attempt on this very failure when
            // the owner armed one, so "try again shortly" is real advice.
            return
                "Error: This workspace's pool is out of credits. If the owner turned on auto-reload it refills in a moment — send again shortly. Otherwise ask the owner to add credits, or turn off workspace billing for this agent in Settings → Workspaces."
        }
        // Stale workspace billing: the pref pointed at a workspace/agent the router no
        // longer recognizes (left/removed, workspace deleted, agent unshared).
        // Self-heal by refreshing the workspace list, whose reconcile drops the
        // dead preference — the next send bills personal credits again.
        if isStaleWorkspaceBillingError(description) {
            WorkspacesService.scheduleBillingReconciliation()
            return
                "Error: This agent was set to bill a workspace that no longer accepts it (you may have left the workspace, or the agent was unshared). Workspace billing for it is being reset — send again to use your personal credits."
        }
        if isWorkspaceSubscriptionInactiveError(description) {
            return
                "Error: This workspace isn't active (its subscription lapsed), so workspace-billed inference is paused. Ask the workspace owner to reactivate it, or turn off workspace billing for this agent in Settings → Workspaces."
        }
        if OsaurusRouter.isInsufficientFundsError(description) {
            return "Error: You're out of credits. Add credits to continue."
        }
        if isSystemResourceExhaustion(description) {
            return
                "Error: Ran out of system resources while running this model. Free memory, unload other models, or choose a smaller/more-quantized model, then try again."
        }
        return "Error: \(description)"
    }

    /// Concise, user-facing reason for a failed remote-agent connect, shown in
    /// the chat's connection-status pill. No "Error:" prefix — the pill styles
    /// it. `RemoteProviderServiceError` (and any `LocalizedError`) already
    /// carries a friendly `errorDescription` (e.g. the Secure-Channel handshake
    /// failure copy), so the localized description is the right surface here.
    static func remoteConnectFailure(_ error: Error) -> String {
        // The transport wraps its reason as "Request failed: <reason>"; the
        // notice already says the agent isn't connected, so surface just the
        // reason ("Could not reach the remote agent (…)") instead of a
        // double preamble.
        if let service = error as? RemoteProviderServiceError {
            switch service {
            case .requestFailed(let reason), .requestFailedWithDiagnostics(let reason, _):
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            default: break
            }
        }
        let description = error.localizedDescription
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Couldn't connect to the remote agent.")
        }
        return description
    }

    /// Same as `remoteConnectFailure` for a message that already went through
    /// `localizedDescription` (e.g. `RemoteProviderConnectionState.lastError`).
    static func remoteConnectFailure(message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L("Couldn't connect to the remote agent.") }
        // Strip a leading "Request failed:" preamble from wrapped transport errors.
        let prefixes = ["Request failed: ", "Request failed:"]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }

    /// Router chat errors carrying these codes only arise when the request
    /// included `workspace_context` (or a caller attestation for a
    /// since-removed member) — plain personal chat never produces them.
    static func isStaleWorkspaceBillingError(_ message: String) -> Bool {
        OsaurusRouterWorkspaceErrorCode.notAMember.appears(in: message)
            || OsaurusRouterWorkspaceErrorCode.workspaceNotFound.appears(in: message)
    }

    static func isWorkspaceSubscriptionInactiveError(_ message: String) -> Bool {
        message.range(of: "SUBSCRIPTION_INACTIVE", options: .caseInsensitive) != nil
    }

    static func isSystemResourceExhaustion(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("not enough memory")
            || normalized.contains("out of memory")
            || normalized.contains("ran out of memory")
            || normalized.contains("failed to allocate memory")
        {
            return true
        }

        if normalized.contains("metal"),
            normalized.contains("memory") || normalized.contains("allocation")
                || normalized.contains("resource")
        {
            return true
        }

        if normalized.contains("mlx"),
            normalized.contains("memory") || normalized.contains("allocation")
                || normalized.contains("resource")
        {
            return true
        }

        return false
    }
}
