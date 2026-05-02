//
//  SandboxAgentProvisioner.swift
//  osaurus
//
//  Coordinates per-agent sandbox provisioning and cleanup.
//

import Foundation

public struct SandboxCleanupNotice: Sendable {
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

        let title =
            (skippedContainerUserCleanup || !warnings.isEmpty)
            ? "Sandbox Cleanup Incomplete"
            : "Sandbox Resources Removed"
        return SandboxCleanupNotice(title: title, message: lines.joined(separator: "\n\n"))
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
            try await SandboxManager.shared.ensureAgentUser(agentName)
            SandboxAgentMap.register(linuxName: linuxName, agentId: agentId)
            // Mint and write the per-agent bridge token now that the Linux
            // user exists. The shim inside the guest reads this file to
            // authenticate to the host bridge — without it, plugin calls
            // fail closed instead of falling back to a default identity.
            if let uuid = UUID(uuidString: agentId) {
                try await SandboxManager.shared.provisionBridgeToken(
                    linuxName: linuxName,
                    agentId: uuid
                )
            }
        }
        inFlight[agentId] = task
        defer { inFlight[agentId] = nil }
        try await task.value
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

    private func removeHostWorkspace(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        try? fm.removeItem(at: url)
        return true
    }
}
