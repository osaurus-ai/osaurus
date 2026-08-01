//
//  PluginCapabilityProjectionTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for #2039: the Plugins UI shows both native and
//  imported Claude plugins, so agent-readable configuration tools must use the
//  same combined projection while preserving each plugin's execution kind.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite
@MainActor
struct PluginCapabilityProjectionTests {
    @Test
    func combinesNativeAndClaudePluginsWithoutChangingTheirExecutionKind() {
        let native = PluginState(
            pluginId: "xlsx",
            name: "XLSX",
            pluginDescription: nil,
            authors: nil,
            license: nil,
            capabilities: nil,
            installedVersion: SemanticVersion.parse("1.2.3"),
            latestVersion: SemanticVersion.parse("1.3.0")
        )
        let claude = makeClaudePlugin(
            id: "github:business/plugins/bm-prd-creator",
            name: "BM PRD Creator",
            declaredSkills: 1,
            skills: [InstalledClaudeSkill(name: "Create PRD", enabled: true)]
        )

        let rows = PluginCapabilityProjection.build(
            nativePlugins: [native],
            claudePlugins: [claude]
        )

        #expect(rows.count == 2)
        #expect(rows.map(\.pluginId).contains("xlsx"))
        #expect(rows.map(\.pluginId).contains("github:business/plugins/bm-prd-creator"))

        let nativeRow = rows.first { $0.pluginId == "xlsx" }
        #expect(nativeRow?.kind == .native)
        #expect(nativeRow?.installed == true)
        #expect(nativeRow?.installationHealthy == true)
        #expect(nativeRow?.enabledArtifactCount == 0)
        #expect(nativeRow?.dictionary["installed_version"] as? String == "1.2.3")
        #expect(nativeRow?.dictionary["latest_version"] as? String == "1.3.0")
        #expect(nativeRow?.dictionary["has_load_error"] as? Bool == false)

        let claudeRow = rows.first { $0.pluginId.contains("bm-prd-creator") }
        #expect(claudeRow?.kind == .claude)
        #expect(claudeRow?.installed == true)
        #expect(claudeRow?.installationHealthy == true)
        #expect(claudeRow?.enabledArtifactCount == 1)
        #expect(claudeRow?.artifactCounts?.skill == 1)
    }

    @Test
    func reportsIncompleteClaudeImportAsInstalledButNeedingAttention() {
        let plugin = makeClaudePlugin(
            id: "github:business/plugins/partial",
            name: "Partial",
            declaredSkills: 2,
            skills: [InstalledClaudeSkill(name: "Only Skill", enabled: false)]
        )

        let row = PluginCapabilityProjection.build(
            nativePlugins: [],
            claudePlugins: [plugin]
        ).first

        #expect(row?.installed == true)
        #expect(row?.status == .needsAttention)
        #expect(row?.installationHealthy == false)
        #expect(row?.dictionary["attention_class"] as? String == "partial_import")
        #expect(row?.dictionary["failure_class"] == nil)
        #expect(row?.dictionary["attention_reason"] as? String != nil)
    }

    @Test
    func doesNotExposeNativeLoadErrorDetails() {
        let tokenCanary = "ghp_DO_NOT_EXPOSE"
        let native = PluginState(
            pluginId: "broken",
            name: "Broken",
            pluginDescription: nil,
            authors: nil,
            license: nil,
            capabilities: nil,
            installedVersion: SemanticVersion.parse("1.0.0"),
            loadError: "dlopen /Users/alice/private/plugin.dylib failed with \(tokenCanary)"
        )

        let row = PluginCapabilityProjection.build(
            nativePlugins: [native],
            claudePlugins: []
        )[0]
        let serialized = String(describing: row.dictionary)

        #expect(row.status == .failed)
        #expect(!serialized.contains(tokenCanary))
        #expect(!serialized.contains("/Users/alice"))
        #expect(serialized.contains("failed to load"))
        #expect(row.dictionary["has_load_error"] as? Bool == true)
        #expect(row.dictionary["load_error"] as? String == "The native plugin failed to load.")
    }

    @Test
    func includesManifestOnlyClaudePluginWithoutClaimingAgentAvailability() {
        let plugin = makeClaudePlugin(
            id: "github:business/plugins/manifest-only",
            name: "Manifest Only",
            declaredSkills: 0,
            skills: []
        )

        let row = PluginCapabilityProjection.build(
            nativePlugins: [],
            claudePlugins: [plugin]
        )[0]

        #expect(row.installed)
        #expect(!row.installationHealthy)
        #expect(row.status == .needsAttention)
        #expect(row.artifactCounts?.total == 0)
        #expect(row.dictionary["attention_reason"] as? String == "No plugin artifacts are currently installed.")
    }

    @Test
    func scheduleAndCommandArtifactsAreCountedWithoutClaimingAgentAvailability() {
        let id = "github:business/plugins/automation"
        let snapshot = makeSnapshot(id: id, name: "Automation", declaredSkills: 0)
        let plugin = ClaudePluginInstalled(
            pluginId: id,
            snapshot: snapshot,
            counts: .init(schedule: 1, command: 1),
            schedules: [
                InstalledClaudeSchedule(
                    id: UUID(),
                    name: "Daily brief",
                    frequencyText: "daily",
                    nextRunText: nil,
                    isEnabled: true
                ),
            ],
            commands: [
                InstalledClaudeCommand(
                    id: UUID(),
                    name: "brief",
                    icon: "doc.text",
                    description: "",
                    templatePreview: nil
                ),
            ]
        )

        let row = PluginCapabilityProjection.build(nativePlugins: [], claudePlugins: [plugin])[0]

        #expect(row.installationHealthy)
        #expect(row.enabledArtifactCount == 2)
        #expect(row.dictionary["available_to_agent"] == nil)
        #expect(row.status == .installed)
    }

    @Test
    func reportsSafePostInstallAttentionCategory() {
        let id = "github:business/plugins/oauth"
        let snapshot = ClaudePluginManifestSnapshot(
            pluginId: id,
            name: "oauth",
            displayName: "OAuth",
            description: nil,
            version: "1.0.0",
            sourceOwner: "business",
            sourceRepo: "plugins",
            installedAt: Date(),
            declaredCounts: .init(skills: 1, agents: 0, commands: 0, mcp: 1),
            installOutcome: .init(oauthProvidersNeedingSignIn: ["private-provider-name"])
        )
        let plugin = ClaudePluginInstalled(
            pluginId: id,
            snapshot: snapshot,
            counts: .init(skill: 1, mcp: 1),
            skills: [InstalledClaudeSkill(name: "OAuth helper", enabled: true)]
        )

        let row = PluginCapabilityProjection.build(nativePlugins: [], claudePlugins: [plugin])[0]
        let reason = row.dictionary["attention_reason"] as? String

        #expect(reason == "An imported MCP provider requires sign-in.")
        #expect(!(reason ?? "").contains("private-provider-name"))
        #expect(row.dictionary["attention_class"] as? String == "oauth_required")
        #expect(row.dictionary["failure_class"] == nil)
        #expect(row.dictionary["latest_version"] == nil)
    }

    @Test
    func configurationToolPluginSummaryAndFiltersUseTheCombinedTruthfulProjection() {
        let native = PluginState(
            pluginId: "broken",
            name: "Broken",
            pluginDescription: nil,
            authors: nil,
            license: nil,
            capabilities: nil,
            installedVersion: SemanticVersion.parse("1.0.0"),
            loadError: "private loader detail"
        )
        let claude = makeClaudePlugin(
            id: "github:business/plugins/partial",
            name: "Partial",
            declaredSkills: 2,
            skills: [InstalledClaudeSkill(name: "One", enabled: true)]
        )
        let rows = PluginCapabilityProjection.build(nativePlugins: [native], claudePlugins: [claude])

        let summary = OsaurusStatusTool.pluginSummary(rows)
        #expect(summary["installed"] as? Int == 2)
        #expect(summary["failed"] as? Int == 1)
        #expect(summary["needs_attention"] as? Int == 1)
        #expect(summary["installation_healthy"] as? Int == 0)

        let failed = OsaurusListTool.filteredPluginItems(rows, filter: "failed")
        let attention = OsaurusListTool.filteredPluginItems(rows, filter: "needs_attention")
        #expect(failed.count == 1)
        #expect(failed.first?["plugin_id"] as? String == "broken")
        #expect(attention.count == 1)
        #expect(attention.first?["kind"] as? String == "claude")
        #expect(attention.first?["available_to_agent"] == nil)
    }

    private func makeClaudePlugin(
        id: String,
        name: String,
        declaredSkills: Int,
        skills: [InstalledClaudeSkill]
    ) -> ClaudePluginInstalled {
        ClaudePluginInstalled(
            pluginId: id,
            snapshot: makeSnapshot(id: id, name: name, declaredSkills: declaredSkills),
            counts: .init(skill: skills.count),
            skills: skills
        )
    }

    private func makeSnapshot(
        id: String,
        name: String,
        declaredSkills: Int
    ) -> ClaudePluginManifestSnapshot {
        ClaudePluginManifestSnapshot(
            pluginId: id,
            name: name.lowercased(),
            displayName: name,
            description: nil,
            version: "1.0.0",
            sourceOwner: "business",
            sourceRepo: "plugins",
            installedAt: Date(),
            declaredCounts: .init(
                skills: declaredSkills,
                agents: 0,
                commands: 0,
                mcp: 0
            )
        )
    }
}

private extension InstalledClaudeSkill {
    init(name: String, enabled: Bool) {
        self.init(
            id: UUID(),
            name: name,
            description: "",
            category: nil,
            enabled: enabled
        )
    }
}
