//
//  SandboxEnvironmentsSection.swift
//  osaurus
//
//  Sandbox page → Agents & Environments: every agent environment on disk
//  (its own container in the pod while running), with its Linux user,
//  network, packages and size, and a per-agent Reset Environment.
//

import AppKit
import SwiftUI

struct SandboxEnvironmentEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case agent(UUID)
        case workflow
        /// Neither an agent's nor a workflow's, e.g. left by an older build.
        case unused
    }

    /// Linux name: the agent's lowercased UUID, or `wf-<template id>`.
    let name: String
    let kind: Kind
    /// Agent name; nil for a workflow or an agent that no longer exists.
    let displayName: String?
    let isRunning: Bool
    let allocatedBytes: Int64?
    let lastUsedAt: Date?

    var id: String { name }
    var linuxUser: String { "agent-\(name)" }

    /// Running containers first, then most recently used.
    static func entries(
        environments: [(name: String, lastUsedAt: Date?)],
        runningMembers: Set<String>,
        agentNames: [UUID: String],
        allocatedBytes: (String) -> Int64?
    ) -> [SandboxEnvironmentEntry] {
        environments
            .filter { SandboxPodLayout.isAgentName($0.name) }
            .map { env in
                let id = UUID(uuidString: env.name)
                return SandboxEnvironmentEntry(
                    name: env.name,
                    kind: id.map(Kind.agent) ?? (env.name.hasPrefix("wf-") ? .workflow : .unused),
                    displayName: id.flatMap { agentNames[$0] },
                    isRunning: runningMembers.contains(env.name),
                    allocatedBytes: allocatedBytes(env.name),
                    lastUsedAt: env.lastUsedAt
                )
            }
            .sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                return ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
    }
}

struct SandboxEnvironmentsSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var sandboxState = SandboxManager.State.shared

    @State private var entries: [SandboxEnvironmentEntry] = []
    @State private var pendingReset: SandboxEnvironmentEntry?
    @State private var resettingName: String?

    var body: some View {
        SettingsSection(
            title: "Agents & Environments",
            subtitle: "Each agent gets its own Linux container and user. Its home folder is on this Mac; the rest of its environment, such as apk packages, lives in the sandbox.",
            anchorId: "sandbox.environments"
        ) {
            VStack(alignment: .leading, spacing: theme.space.s0) {
                if entries.isEmpty {
                    SettingsEmptyState(
                        inline: "person.2",
                        title: "No agent environments yet",
                        hint: "An agent gets one the first time it runs a command in the sandbox."
                    )
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                        if entry.id != entries.last?.id {
                            SettingsGroupDivider()
                        }
                    }
                }
            }
        }
        .task(id: sandboxState.status) { await reload() }
        .alert(
            Text(verbatim: resetTitle),
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } })
        ) {
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            Button(role: .destructive) {
                if let entry = pendingReset { reset(entry) }
            } label: {
                Text("Reset Environment", bundle: .module)
            }
        } message: {
            Text(verbatim: resetMessage)
        }
    }

    private func row(_ entry: SandboxEnvironmentEntry) -> some View {
        SettingsRow(
            title: title(for: entry),
            description: detail(for: entry),
            verbatimTitle: true,
            verbatimDescription: true
        ) {
            HStack(spacing: theme.space.s8) {
                if entry.isRunning {
                    StatusChip(L("Running"), tone: .success, showsDot: true)
                }
                SettingsIconButton("folder", help: "Open in Finder") {
                    OsaurusPaths.revealInFinder(OsaurusPaths.containerAgentDir(entry.name))
                }
                if case .agent = entry.kind {
                    SettingsButton(
                        .secondary,
                        "Reset…",
                        isLoading: resettingName == entry.name,
                        size: .compact
                    ) { pendingReset = entry }
                    .disabled(resettingName != nil)
                }
            }
        }
    }

    private func title(for entry: SandboxEnvironmentEntry) -> String {
        switch entry.kind {
        case .agent: return entry.displayName ?? L("Deleted agent")
        case .workflow: return L("Workflow environment")
        case .unused: return L("Unused environment")
        }
    }

    private func detail(for entry: SandboxEnvironmentEntry) -> String {
        var parts = [entry.linuxUser]
        if case .agent(let id) = entry.kind {
            parts.append(Self.networkLabel(SandboxManager.egressMode(forAgentId: id)))
            let installed = SandboxPackageManifest.shared.installed(agentId: id)
            let count = installed.apk.count + installed.pip.count + installed.npm.count
            if count > 0 { parts.append(count == 1 ? L("1 package") : L("\(count) packages")) }
        }
        if let bytes = entry.allocatedBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let used = entry.lastUsedAt {
            parts.append(L("used \(used.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    static func networkLabel(_ mode: SandboxEgressMode) -> String {
        switch mode {
        case .open: return L("Network on")
        case .allowlist(let domains):
            return domains.count == 1 ? L("Network: 1 domain") : L("Network: \(domains.count) domains")
        case .none: return L("Network off")
        }
    }

    private var resetTitle: String {
        guard let entry = pendingReset else { return "" }
        return L("Reset \(title(for: entry))'s environment?")
    }

    private var resetMessage: String {
        guard let entry = pendingReset else { return "" }
        let base = L(
            "Removes apk packages and anything else this agent changed outside its home folder. Its home folder stays, including its files, SOUL.md, and pip and npm packages."
        )
        guard entry.isRunning else { return base }
        return base + " " + L("The sandbox restarts once running commands finish.")
    }

    private func reset(_ entry: SandboxEnvironmentEntry) {
        pendingReset = nil
        resettingName = entry.name
        Task {
            do {
                try await SandboxManager.shared.resetAgentEnvironmentNow(agentName: entry.name)
                _ = ToastManager.shared.success(L("Reset \(title(for: entry))'s environment"))
            } catch {
                _ = ToastManager.shared.error(
                    L("Couldn't reset \(title(for: entry))'s environment"),
                    message: error.localizedDescription
                )
            }
            resettingName = nil
            await reload()
        }
    }

    private func reload() async {
        let members = await SandboxManager.shared.podMemberNames
        let running = sandboxState.status.isRunning ? Set(members) : []
        let agentNames = Dictionary(
            AgentManager.shared.agents.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        // Listing and sizing both hit the disk (sizing is a getattrlist per
        // clone that APFS answers by walking extents), so do all of it off
        // the main actor and hand back plain data.
        let (loaded, sizes) = await Task.detached(priority: .utility) {
            let environments = SandboxRootfsTemplateStore.listEnvironments().map {
                (name: $0.name, lastUsedAt: $0.stamp?.lastUsedAt)
            }
            var sizes: [String: Int64] = [:]
            for env in environments where SandboxPodLayout.isAgentName(env.name) {
                sizes[env.name] = SandboxRootfsTemplateStore.allocatedBytes(agentName: env.name)
            }
            return (environments, sizes)
        }.value
        entries = SandboxEnvironmentEntry.entries(
            environments: loaded,
            runningMembers: running,
            agentNames: agentNames,
            allocatedBytes: { sizes[$0] }
        )
    }
}
