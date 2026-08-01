//
//  PluginCapabilityProjection.swift
//  osaurus
//
//  One read-only projection for every plugin surface shown in the Plugins UI.
//  Native plugins and imported Claude plugins have different execution models;
//  keeping that distinction prevents an imported skill package from being
//  misreported as a loadable native plugin.
//

import Foundation

enum PluginCapabilityKind: String, Sendable {
    case native
    case claude
}

enum PluginCapabilityStatus: String, Sendable {
    case available
    case installed
    case needsAttention = "needs_attention"
    case failed
}

struct PluginCapabilityProjectionRow: Equatable, Sendable {
    let pluginId: String
    let name: String
    let kind: PluginCapabilityKind
    let status: PluginCapabilityStatus
    let installed: Bool
    let installationHealthy: Bool
    let enabledArtifactCount: Int
    let version: String?
    let latestVersion: String?
    let nativeLoadFailed: Bool
    let artifactCounts: ClaudePluginArtifactCounts?
    let attentionReason: String?
    let attentionClass: String?

    var needsAttention: Bool { status == .needsAttention }
    var failed: Bool { status == .failed }

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "plugin_id": pluginId,
            "name": name,
            "kind": kind.rawValue,
            "status": status.rawValue,
            "installed": installed,
            "installation_healthy": installationHealthy,
            "enabled_artifact_count": enabledArtifactCount,
            // Compatibility aliases retained for existing agent workflows.
            "has_load_error": nativeLoadFailed,
            "installed_version": version ?? "",
            "load_error": nativeLoadFailed ? "The native plugin failed to load." : "",
        ]
        if let version { result["version"] = version }
        if let latestVersion { result["latest_version"] = latestVersion }
        if nativeLoadFailed {
            result["failure_reason"] = "The native plugin failed to load."
            result["failure_class"] = "native_load_failed"
        }
        if let artifactCounts {
            result["artifacts"] = [
                "skills": artifactCounts.skill,
                "schedules": artifactCounts.schedule,
                "commands": artifactCounts.command,
                "mcp": artifactCounts.mcp,
            ]
        }
        if let attentionReason {
            result["attention_reason"] = attentionReason
        }
        if let attentionClass {
            result["attention_class"] = attentionClass
        }
        return result
    }
}

@MainActor
enum PluginCapabilityProjection {
    static func current() -> [PluginCapabilityProjectionRow] {
        let claudePlugins = InstalledClaudePluginsAggregator.buildPlugins(
            snapshots: ClaudePluginManifestStore.all(),
            skills: SkillManager.shared.skills,
            schedules: ScheduleManager.shared.schedules,
            commands: SlashCommandRegistry.shared.customCommands,
            providers: MCPProviderManager.shared.configuration.providers
        )
        return build(
            nativePlugins: PluginRepositoryService.shared.plugins,
            claudePlugins: claudePlugins
        )
    }

    static func build(
        nativePlugins: [PluginState],
        claudePlugins: [ClaudePluginInstalled]
    ) -> [PluginCapabilityProjectionRow] {
        let nativeRows = nativePlugins.map { plugin in
            let installed = plugin.installedVersion != nil
            let loadFailed = installed && plugin.loadError != nil
            return PluginCapabilityProjectionRow(
                pluginId: plugin.pluginId,
                name: plugin.displayName,
                kind: .native,
                status: loadFailed ? .failed : (installed ? .installed : .available),
                installed: installed,
                installationHealthy: installed && !loadFailed,
                enabledArtifactCount: 0,
                version: plugin.installedVersion?.description,
                latestVersion: plugin.latestVersion?.description,
                nativeLoadFailed: loadFailed,
                artifactCounts: nil,
                attentionReason: nil,
                attentionClass: nil
            )
        }

        let claudeRows = claudePlugins.map { plugin in
            let needsAttention = plugin.needsPostInstallAttention || plugin.totalCount == 0
            let enabledArtifactCount = plugin.skills.filter(\.enabled).count
                + plugin.mcps.filter(\.enabled).count
                + plugin.schedules.filter(\.isEnabled).count
                + plugin.commands.count
            return PluginCapabilityProjectionRow(
                pluginId: plugin.pluginId,
                name: plugin.displayName,
                kind: .claude,
                status: needsAttention ? .needsAttention : .installed,
                installed: true,
                installationHealthy: !needsAttention,
                enabledArtifactCount: enabledArtifactCount,
                version: plugin.version,
                latestVersion: plugin.availableVersion,
                nativeLoadFailed: false,
                artifactCounts: plugin.counts,
                attentionReason: attentionReason(for: plugin),
                attentionClass: attentionClass(for: plugin)
            )
        }

        return (nativeRows + claudeRows).sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.pluginId < $1.pluginId
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func attentionReason(for plugin: ClaudePluginInstalled) -> String? {
        if plugin.totalCount == 0 {
            return "No plugin artifacts are currently installed."
        }
        if plugin.hasPartialImport {
            return "Some declared plugin components were not imported."
        }
        guard let outcome = plugin.snapshot?.installOutcome else { return nil }
        if !outcome.errors.isEmpty {
            return "The plugin import reported errors."
        }
        if !outcome.oauthProvidersNeedingSignIn.isEmpty {
            return "An imported MCP provider requires sign-in."
        }
        if !outcome.placeholderTokensSkipped.isEmpty
            || !outcome.stdioProvidersNeedingConfiguration.isEmpty
        {
            return "An imported MCP provider requires credential or environment configuration."
        }
        if !outcome.stdioProvidersBlockedNoSandbox.isEmpty {
            return "An imported stdio MCP provider requires the sandbox."
        }
        if !outcome.skippedStdioMCPServers.isEmpty {
            return "An imported stdio MCP provider was skipped."
        }
        if !outcome.schedulesNeedingCron.isEmpty {
            return "An imported schedule requires review."
        }
        return nil
    }

    private static func attentionClass(for plugin: ClaudePluginInstalled) -> String? {
        if plugin.totalCount == 0 { return "empty_import" }
        if plugin.hasPartialImport { return "partial_import" }
        guard let outcome = plugin.snapshot?.installOutcome else { return nil }
        if !outcome.errors.isEmpty { return "import_error" }
        if !outcome.oauthProvidersNeedingSignIn.isEmpty { return "oauth_required" }
        if !outcome.placeholderTokensSkipped.isEmpty
            || !outcome.stdioProvidersNeedingConfiguration.isEmpty
        { return "credential_configuration_required" }
        if !outcome.stdioProvidersBlockedNoSandbox.isEmpty { return "sandbox_required" }
        if !outcome.skippedStdioMCPServers.isEmpty { return "stdio_provider_skipped" }
        if !outcome.schedulesNeedingCron.isEmpty { return "schedule_review_required" }
        return nil
    }
}
