//
//  SandboxAgentProvisioner.swift
//  osaurus
//
//  Coordinates per-agent sandbox provisioning and cleanup.
//

import Foundation

public struct SandboxCleanupNotice: Sendable {
    /// Severity of the cleanup outcome, so a non-modal surface (toast)
    /// can pick the right styling without re-deriving it from the title.
    public enum Kind: Sendable {
        /// Every requested cleanup step succeeded.
        case completed
        /// Some step was skipped or failed (warnings / container not running).
        case incomplete
    }

    public let kind: Kind
    public let title: String
    public let message: String
}

public struct SandboxAgentCleanupResult: Sendable {
    public let removedMapping: Bool
    public let removedPluginState: Bool
    public let removedHostWorkspace: Bool
    public let removedContainerUser: Bool
    public let skippedContainerUserCleanup: Bool
    public let warnings: [String]

    public var notice: SandboxCleanupNotice? {
        let changedState =
            removedMapping || removedPluginState || removedHostWorkspace || removedContainerUser
            || skippedContainerUserCleanup || !warnings.isEmpty
        guard changedState else { return nil }

        var lines: [String] = []
        if removedMapping || removedPluginState || removedHostWorkspace || removedContainerUser {
            lines.append("Removed sandbox resources associated with this agent.")
        }
        if skippedContainerUserCleanup {
            lines.append("The sandbox container was not running, so Linux-user cleanup was skipped.")
        }
        if !warnings.isEmpty {
            lines.append("Some cleanup steps could not be completed: \(warnings.joined(separator: " "))")
        }

        let incomplete = skippedContainerUserCleanup || !warnings.isEmpty
        let title =
            incomplete
            ? L("Sandbox Cleanup Incomplete")
            : L("Sandbox Resources Removed")
        return SandboxCleanupNotice(
            kind: incomplete ? .incomplete : .completed,
            title: title,
            message: lines.joined(separator: "\n\n")
        )
    }
}

@MainActor
public final class SandboxAgentProvisioner {
    public static let shared = SandboxAgentProvisioner()

    /// In-flight provisioning tasks keyed by agent id (uuidString form).
    /// Coalesces concurrent `ensureProvisioned` calls for the same agent so
    /// the notification-driven path (`SandboxToolRegistrar.handleAgentUpdated`)
    /// and any direct caller share one attempt instead of racing each other
    /// through `ensureAgentUser` (which is not itself coalesced and can fail
    /// with confusing "user already being created" symptoms when interleaved).
    private var inFlight: [String: Task<Void, Error>] = [:]

    private init() {}

    public static func linuxName(for agentId: String) -> String {
        let name =
            agentId
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return name.isEmpty ? "agent" : name
    }

    public func ensureProvisioned(agentId: UUID) async throws {
        try await ensureProvisioned(agentId: agentId.uuidString)
    }

    public func ensureProvisioned(agentId: String) async throws {
        if let existing = inFlight[agentId] {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { [agentId] in
            let agentName = Self.linuxName(for: agentId)
            let linuxName = "agent-\(agentName)"
            Self.ensureHostWorkspace(for: agentName)
            try await SandboxManager.shared.startContainer()
            // One idempotent guest script covers what used to be four to
            // six sequential vsock execs: agent user + home, plugins dir,
            // bridge-token dir + token file (the shim reads it to
            // authenticate to the host bridge — without it plugin calls
            // fail closed), and the first-run `~/SOUL.md` seed (guarded
            // by `test -f` so accumulated agent edits are never
            // overwritten).
            try await SandboxManager.shared.bootstrapAgent(
                agentName: agentName,
                agentId: UUID(uuidString: agentId),
                soulSeedBody: Self.soulSeedBody
            )
            SandboxAgentMap.register(linuxName: linuxName, agentId: agentId)
            // Lazy reconcile: one cheap pip/npm listing per provision so the
            // installed-packages prompt line reflects real container state
            // (including packages a previous session added). Non-throwing —
            // a failed listing just leaves the manifest as-is.
            await Self.reconcilePackageManifest(agentId: agentId, agentName: agentName)
        }
        inFlight[agentId] = task
        defer { inFlight[agentId] = nil }
        try await task.value
        // Stamp boot → first-agent-ready on the current boot's local
        // metrics sample. The store only accepts the first stamp per
        // sample, so later agents (or re-provisions) are no-ops.
        if let readyAt = await SandboxManager.shared.lastBootReadyAt {
            SandboxStartupMetricsStore.recordFirstAgentReady(
                seconds: Date().timeIntervalSince(readyAt)
            )
        }
    }

    public func unprovision(agentId: UUID) async -> SandboxAgentCleanupResult {
        await unprovision(agentId: agentId.uuidString)
    }

    public func unprovision(agentId: String) async -> SandboxAgentCleanupResult {
        let agentName = Self.linuxName(for: agentId)
        let hostWorkspace = OsaurusPaths.containerAgentDir(agentName)

        let removedMapping = SandboxAgentMap.unregister(agentId: agentId)
        let removedPluginState = SandboxPluginManager.shared.removeAgentState(for: agentId)
        let removedHostWorkspace = removeHostWorkspace(at: hostWorkspace)
        // Drop any tracked background-job pids — `removeAgentUser`
        // pkill's the user's processes a few lines below, so the pids
        // we still hold in memory are immediately invalid. Clearing
        // them keeps `sandbox_process` honest and prevents stale
        // entries from accumulating across re-provisions.
        await SandboxBackgroundJobs.shared.clear(agentName: agentName)
        // Same hygiene for the install-lock queue — entries are tiny
        // but accumulate across long sessions if we don't clear them.
        await SandboxInstallLock.shared.clear(agentName: agentName)
        // Drop the installed-package manifest so a re-provisioned agent
        // (or one whose container was rebuilt) starts from observed truth
        // rather than a stale list.
        SandboxPackageManifest.shared.clear(agentId: agentId)

        var removedContainerUser = false
        var skippedContainerUserCleanup = false
        var warnings: [String] = []

        let sandboxRunning = await SandboxManager.shared.status().isRunning
        if sandboxRunning {
            do {
                removedContainerUser = try await SandboxManager.shared.removeAgentUser(agentName)
            } catch {
                warnings.append(error.localizedDescription)
            }
        } else if removedMapping || removedPluginState || removedHostWorkspace {
            skippedContainerUserCleanup = true
        }

        return SandboxAgentCleanupResult(
            removedMapping: removedMapping,
            removedPluginState: removedPluginState,
            removedHostWorkspace: removedHostWorkspace,
            removedContainerUser: removedContainerUser,
            skippedContainerUserCleanup: skippedContainerUserCleanup,
            warnings: warnings
        )
    }

    /// Make the on-host workspace directory for an agent. Static + nonisolated
    /// so the provisioning task can call it from the cooperative thread pool
    /// without hopping back to MainActor for what is just a `mkdir -p`.
    nonisolated private static func ensureHostWorkspace(for agentName: String) {
        let fm = FileManager.default
        let agentDir = OsaurusPaths.containerAgentDir(agentName)
        let pluginsDir = agentDir.appendingPathComponent("plugins", isDirectory: true)
        try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
    }

    // MARK: - SOUL.md Bootstrap

    /// First-run seed body for `~/SOUL.md`. Identity-only on purpose:
    /// it tells the agent what the file is, that editing is sanctioned,
    /// and the next-session cadence. The detailed what-goes /
    /// what-does-not-go boundary lives once in the always-present
    /// `## Self-improvement` prompt section, so the seed does not repeat
    /// it.
    ///
    /// An empty SOUL.md would leave the agent unsure whether the file
    /// is meaningful or accidental — the seed is what makes editing
    /// sanctioned. Stable across versions; do not bump opportunistically.
    nonisolated static let soulSeedBody: String = """
        # SOUL

        This file is your space to record stable preferences and patterns you
        learn about working with the user. It persists across sessions, and you
        can edit it freely with sandbox_write_file. Edits apply on the
        next session.
        """

    // The seed write itself lives in the batched per-agent bootstrap —
    // see `SandboxManager.agentBootstrapScript`, which guards it with
    // `[ ! -f .../SOUL.md ]` and a single-quoted heredoc so the body
    // lands byte-exact and accumulated edits are never overwritten.

    // MARK: - Installed-package manifest reconcile

    /// pip/setuptools/wheel are venv plumbing, not something the agent
    /// "installed" — drop them so the prompt line lists only real deps.
    nonisolated private static let pipReconcileIgnore: Set<String> = ["pip", "setuptools", "wheel"]

    /// Refresh the host-side installed-package manifest from real container
    /// state. Lists the agent's pip venv and reads its npm workspace
    /// `package.json`; `apk` is intentionally skipped — the base image
    /// carries hundreds of system packages (already named in the prompt's
    /// environment block), and `apk add` can't succeed unprivileged via
    /// `sandbox_exec`, so apk only ever enters the manifest through the
    /// root-running `sandbox_install` tool, which records itself.
    ///
    /// Non-throwing: a missing venv / `package.json` (the common first-run
    /// case) leaves that manager untouched (`nil`) rather than wiping a
    /// tool-recorded list.
    nonisolated static func reconcilePackageManifest(agentId: String, agentName: String) async {
        let home = OsaurusPaths.inContainerAgentHome(agentName)
        let venv = "\(home)/.venv"
        let nodeWorkdir = "\(home)/.osaurus/node_workspace"

        // The two probes are independent — run them concurrently so the
        // provision path pays one exec round-trip of latency, not two.
        async let pipFuture = try? await SandboxManager.shared.execAsAgent(
            agentName,
            command: "'\(venv)/bin/pip' list --format=freeze"
        )
        async let npmFuture = try? await SandboxManager.shared.execAsAgent(
            agentName,
            command: "cat '\(nodeWorkdir)/package.json'"
        )

        var pip: [String]? = nil
        // No `|| true`: when the venv doesn't exist the command exits
        // non-zero, so we leave `pip` nil and don't clobber prior records.
        if let result = await pipFuture, result.succeeded {
            pip = result.stdout
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return nil }
                    // `name==version`, `name @ file://…`, or editable installs.
                    let name =
                        trimmed
                        .split(whereSeparator: { $0 == "=" || $0 == " " || $0 == "@" })
                        .first
                        .map(String.init)
                    guard let name, !pipReconcileIgnore.contains(name.lowercased()) else { return nil }
                    return name
                }
        }

        var npm: [String]? = nil
        if let result = await npmFuture, result.succeeded,
            let data = result.stdout.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var keys: [String] = []
            for field in ["dependencies", "devDependencies"] {
                if let deps = object[field] as? [String: Any] {
                    keys.append(contentsOf: deps.keys)
                }
            }
            npm = keys
        }

        guard pip != nil || npm != nil else { return }
        SandboxPackageManifest.shared.reconcile(agentId: agentId, apk: nil, pip: pip, npm: npm)
    }

    private func removeHostWorkspace(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        try? fm.removeItem(at: url)
        return true
    }
}
