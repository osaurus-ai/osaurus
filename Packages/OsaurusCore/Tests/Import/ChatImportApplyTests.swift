//
//  ChatImportApplyTests.swift
//  OsaurusCoreTests
//
//  The install half of chat import: sandbox-aware preflight, all-or-nothing
//  apply with rollback, provenance on re-import, the New Agent queue
//  (`agent_draft` import, nothing installed before Create), sandbox copies
//  of skill folders, and Claude plugin agents.
//

import Foundation
import Testing

@testable import OsaurusCore

private func mcpItem(_ json: String) -> ChatImportItem {
    var bundle = ChatImportBundle(userText: json)
    bundle.documents = [ChatImportDocument(id: "d1", origin: "your message", path: nil, text: json)]
    return ChatImportFastPaths.run(bundle).items[0]
}

private func skillItem(_ name: String, package: URL? = nil, hash: String = "h1") -> ChatImportItem {
    ChatImportItem(
        id: "skill:\(name)", kind: .skill, name: name, detail: "", origin: "https://example.com/\(name)",
        payload: .instructions(.init(name: name, description: "Test skill.", instructions: "Do \(name).", packageDirectory: package)),
        contentHash: hash)
}

private func commandItem(_ name: String, hash: String) -> ChatImportItem {
    var entry = CommandEntry(name: name)
    entry.template = "Summarize $ARGUMENTS."
    entry.description = "Test command."
    return ChatImportItem(
        id: "command:\(name)", kind: .command, name: "/\(name)", detail: "", origin: "https://example.com/cmd",
        payload: .command(entry), contentHash: hash)
}

private func choices(_ items: [ChatImportItem]) -> [String: ChatImportItemChoice] {
    ChatImportReview(items: items, refusals: [], notes: [], surface: .mainChat).defaultChoices
}

private func unique(_ base: String) -> String {
    "\(base)-\(UUID().uuidString.prefix(6).lowercased())"
}

struct ChatImportPreflightTests {

    private static let vm = ChatImportPreflight.Environment(stdioSandbox: true, agentNetworkEnabled: true, dockerInstalled: true)

    private func checked(_ json: String, _ environment: ChatImportPreflight.Environment) -> ChatImportItem {
        var item = mcpItem(json)
        guard case .mcpServer(let spec) = item.payload else { return item }
        ChatImportPreflight.runtimeChecks(&item, spec: spec, environment: environment)
        return item
    }

    @Test
    func stdioWithoutTheVMSandbox_isBlocked() {
        var env = Self.vm
        env.stdioSandbox = false
        let item = checked(#"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@acme/fs"]}}}"#, env)
        #expect(item.blockedReason != nil && !item.included && !item.isActionable)
        let remote = checked(#"{"mcpServers": {"r": {"url": "https://mcp.acme.dev/mcp"}}}"#, env)
        #expect(remote.blockedReason == nil, "remote servers don't need the sandbox")
    }

    @Test
    func npxWithSandboxNetworkOff_warns() {
        var env = Self.vm
        env.agentNetworkEnabled = false
        let item = checked(#"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@acme/fs"]}}}"#, env)
        #expect(item.blockedReason == nil)
        #expect(item.warnings.contains { $0.contains("network access is off") })
        #expect(checked(#"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@acme/fs"]}}}"#, Self.vm).warnings.isEmpty)
    }

    @Test
    func dockerRun_arrivesUncheckedAsAHostOptIn() {
        var env = Self.vm
        env.dockerInstalled = false
        env.stdioSandbox = false
        let item = checked(#"{"mcpServers": {"pg": {"command": "docker", "args": ["run", "-i", "mcp/postgres"]}}}"#, env)
        #expect(!item.included)
        #expect(item.blockedReason == nil, "docker runs on the host, so the sandbox backend doesn't matter")
        #expect(item.risks == [ConfigRisk.stdioOnHost("pg")])
        #expect(item.warnings.contains { $0.contains("Docker wasn't found") })
    }

    @Test
    func hostCommandLocator_searchesPathWithoutAShell() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("acme-tool")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        #expect(HostCommandLocator.find("acme-tool", environment: ["PATH": dir.path]) == tool.path)
        #expect(HostCommandLocator.find("acme-missing-\(UUID().uuidString)", environment: ["PATH": dir.path]) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct ChatImportApplyTests {

    init() { ConfigurationDomainBootstrap.registerBuiltIns() }

    private func deleteCommand(_ name: String) {
        if let command = SlashCommandRegistry.shared.customCommands.first(where: { $0.name == name }) {
            _ = SlashCommandRegistry.shared.delete(id: command.id)
        }
        ChatImportProvenanceStore.shared.remove(kind: .command, name: name)
    }

    @Test
    func apply_installsOnlyCheckedRows_andRecordsProvenance() async {
        let kept = unique("imp-kept")
        let skipped = unique("imp-skip")
        defer { deleteCommand(kept); deleteCommand(skipped) }
        let items = [commandItem(kept, hash: "v1"), commandItem(skipped, hash: "v1")]
        var picks = choices(items)
        picks[items[1].id]?.included = false

        let outcome = await ChatImportApplier.apply(items: items, choices: picks, context: .init())
        #expect(outcome.succeeded)
        #expect(outcome.results.map(\.status) == [.skipped, .installed])
        #expect(SlashCommandRegistry.shared.customCommands.contains { $0.name == kept })
        #expect(!SlashCommandRegistry.shared.customCommands.contains { $0.name == skipped })
        #expect(ChatImportProvenanceStore.shared.find(kind: .command, name: kept)?.contentHash == "v1")
    }

    @Test
    func reimport_isAlreadyInstalledOrAnUpdate_andClashesKeepBoth() async {
        let name = unique("imp-re")
        defer { deleteCommand(name); deleteCommand(name + "-2") }
        let first = commandItem(name, hash: "v1")
        _ = await ChatImportApplier.apply(items: [first], choices: choices([first]), context: .init())
        let env = ChatImportPreflight.Environment(stdioSandbox: true, agentNetworkEnabled: true, dockerInstalled: true)

        var same = [commandItem(name, hash: "v1")]
        ChatImportPreflight.annotate(&same, environment: env)
        #expect(same[0].state == .alreadyInstalled && !same[0].included)

        var changed = [commandItem(name, hash: "v2")]
        ChatImportPreflight.annotate(&changed, environment: env)
        #expect(changed[0].state == .updateAvailable && changed[0].clashChoice == .replace)

        ChatImportProvenanceStore.shared.remove(kind: .command, name: name)
        var clash = [commandItem(name, hash: "v3")]
        ChatImportPreflight.annotate(&clash, environment: env)
        #expect(clash[0].state == .nameClash && clash[0].clashChoice == .keepBoth)
        let outcome = await ChatImportApplier.apply(items: clash, choices: choices(clash), context: .init())
        #expect(outcome.finalNames[clash[0].id] == name + "-2")
        #expect(SlashCommandRegistry.shared.customCommands.contains { $0.name == name + "-2" })
    }

    @Test
    func failedItem_rollsBackEverythingThisApplyInstalled() async throws {
        let good = unique("Imp Good")
        let bad = unique("Imp Bad")
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("imp-pkg-\(UUID().uuidString)")
        let scripts = package.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "print(1)".write(to: scripts.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scripts.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.path)
            try? FileManager.default.removeItem(at: package)
        }
        let items = [skillItem(good), skillItem(bad, package: package)]

        let outcome = await ChatImportApplier.apply(items: items, choices: choices(items), context: .init())
        #expect(!outcome.succeeded)
        #expect(outcome.results.first { $0.name == good }?.status == .rolledBack)
        #expect(outcome.results.first { $0.name == bad }?.status == .failed)
        #expect(SkillManager.shared.skill(named: good) == nil, "the skill installed first was removed again")
        #expect(ChatImportProvenanceStore.shared.find(kind: .skill, name: good) == nil)
    }

    @Test
    func invalidConfig_failsBeforeAnythingInstalls() async {
        let skill = unique("Imp Early")
        let command = unique("imp-early")
        var badServer = mcpItem(#"{"mcpServers": {"x": {"url": "https://mcp.acme.dev/mcp"}}}"#)
        if case .mcpServer(var spec) = badServer.payload {
            spec.entry.transport = "carrier-pigeon"
            badServer.payload = .mcpServer(spec)
        }
        let items = [skillItem(skill), commandItem(command, hash: "x"), badServer]
        let outcome = await ChatImportApplier.apply(items: items, choices: choices(items), context: .init())
        #expect(!outcome.succeeded)
        #expect(outcome.results.allSatisfy { $0.status == .failed })
        #expect(SkillManager.shared.skill(named: skill) == nil)
        #expect(!SlashCommandRegistry.shared.customCommands.contains { $0.name == command })
    }
}

@Suite(.serialized)
@MainActor
struct AgentDraftImportTests {

    private func freshDraft() -> AgentDraft {
        ConfigurationDomainBootstrap.registerBuiltIns()
        return AgentDraftStore.shared.create(sessionID: UUID().uuidString)
    }

    private func review(package: URL?) -> ChatImportReview {
        let agent = ChatImportItem(
            id: "agent:reviewer", kind: .agent, name: "Reviewer", detail: "Reviews diffs.", origin: "https://x/agents/r.md",
            payload: .instructions(
                .init(name: "Reviewer", description: "Reviews diffs.", instructions: "You review code.",
                      capabilities: ["calculator"])))
        var installed = skillItem("Already There")
        installed.state = .alreadyInstalled
        installed.included = false
        var blocked = mcpItem(#"{"mcpServers": {"local": {"command": "npx", "args": ["-y", "@acme/local"]}}}"#)
        blocked.blockedReason = "needs the VM sandbox"
        blocked.included = false
        let step = ChatImportItem(
            id: "step:account", kind: .manualStep, name: "Create an Acme account", detail: "", origin: "",
            payload: .manualStep("Create an Acme account"), included: false)
        let items = [
            agent, skillItem("Acme Helper", package: package),
            mcpItem(#"{"mcpServers": {"acme": {"url": "https://mcp.acme.dev/mcp"}}}"#), installed, blocked, step,
        ]
        return ChatImportReview(items: items, refusals: [], notes: [], surface: .agentCreation)
    }

    @Test
    func import_fillsTheDraftKeepsUserEditsAndQueuesTheRest() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        let agentsBefore = AgentManager.shared.agents.count
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("draft-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "print(1)".write(to: package.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8)
        AgentDraftStore.shared.applyUserEdit(draft.id, .name) { $0.name = "My Reviewer" }

        let envelope = AgentDraftTool.queueImport(review(package: package), draftId: draft.id, tool: "agent_draft")
        try? FileManager.default.removeItem(at: package)

        let result = try #require(ToolEnvelope.successPayload(envelope) as? [String: Any])
        #expect(result["status"] as? String == "queued")
        #expect((result["kept_user_edits"] as? [String]) == ["name"])
        #expect((result["already_installed"] as? [String]) == ["Already There"])
        #expect((result["blocked"] as? [[String: Any]])?.first?["name"] as? String == "local")

        let updated = try #require(AgentDraftStore.shared.draft(id: draft.id))
        #expect(updated.agent.name == "My Reviewer")
        #expect(updated.agent.systemPrompt == "You review code.")
        #expect(AgentDraftTool.enabledCapabilities(updated.agent).contains("calculator_enabled"))
        #expect(updated.queuedImports.map(\.kind) == [.skill, .mcpServer, .manualStep])
        #expect(AgentManager.shared.agents.count == agentsBefore, "nothing is created before Create")
        #expect(SkillManager.shared.skill(named: "Acme Helper") == nil, "nothing is installed before Create")

        guard case .instructions(let spec) = updated.queuedImports[0].payload, let kept = spec.packageDirectory else {
            Issue.record("the queued skill lost its folder")
            return
        }
        #expect(kept.path.hasPrefix(AgentDraftStore.importsDirectory(draft.id).path))
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("scripts/run.py").path))
    }

    @Test
    func queuedMCPNames_areAcceptedByPatch_andRemovalLeavesANote() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        _ = AgentDraftTool.queueImport(review(package: nil), draftId: draft.id, tool: "agent_draft")

        var entry = AgentEntry(name: "")
        var groups = AgentToolGroupsEntry()
        groups.enabled = ["acme"]
        entry.mcpServers = groups
        let patch = try AgentDraftStore.shared.applyConfiguratorPatch(draft.id, entry: entry)
        #expect(patch.notes.contains { $0.contains("Installs when the user clicks Create") && $0.contains("acme") })
        #expect(!patch.notes.contains { $0.contains("Not set up on this Mac") })

        let mcp = try #require(AgentDraftStore.shared.draft(id: draft.id)?.queuedImports.first { $0.kind == .mcpServer })
        AgentDraftStore.shared.removePendingImport(draft.id, itemId: mcp.id)
        let after = try #require(AgentDraftStore.shared.draft(id: draft.id))
        #expect(!after.queuedImports.contains { $0.kind == .mcpServer })
        #expect(after.pendingUserEdits.contains { $0.contains("removed acme") })
    }

    @Test
    func queue_survivesReload() throws {
        let draft = freshDraft()
        defer { AgentDraftStore.shared.delete(draft.id) }
        _ = AgentDraftTool.queueImport(review(package: nil), draftId: draft.id, tool: "agent_draft")
        let before = try #require(AgentDraftStore.shared.draft(id: draft.id)?.queuedImports)
        AgentDraftStore.shared.reload()
        #expect(AgentDraftStore.shared.draft(id: draft.id)?.queuedImports == before)
    }

    @Test
    func import_withoutADraft_isUnavailable() async {
        let envelope = await AgentDraftTool.importSource("https://x/SKILL.md", sessionID: UUID().uuidString, tool: "agent_draft")
        #expect(ToolEnvelope.isError(envelope))
        #expect(envelope.contains("no open New Agent draft"))
    }
}

@Suite(.serialized)
@MainActor
struct OsaurusImportToolResultTests {

    @Test
    func bareName_isRejectedAsArgsAndPointsAtOsaurusConfig() async throws {
        let args = #"{"source":"osaurus.standup-notes"}"#
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.configuratorId) {
            try await OsaurusImportTool().execute(argumentsJSON: args)
        }
        #expect(result.contains("\"kind\":\"invalid_args\""))
        #expect(result.contains("\"field\":\"source\""))
        #expect(result.contains("osaurus_config"))
        let call = HandoffToolCall(name: OsaurusImportTool.toolName, argumentsJSON: args, result: result)
        #expect(ConfiguratorHandoffTool.classify([call], digest: "d") == .answer("d"))
    }

    @Test
    func reimportOfUnchangedItems_answersWithoutACard() throws {
        func review(_ items: [ChatImportItem]) -> ChatImportReview {
            ChatImportReview(items: items, refusals: [], notes: [], surface: .mainChat)
        }
        var tempo = skillItem("Tempo")
        tempo.state = .alreadyInstalled
        tempo.included = false
        let step = ChatImportItem(
            id: "step:cli", kind: .manualStep, name: "Install the Tempo CLI", detail: "", origin: "",
            payload: .manualStep("Install the Tempo CLI"), included: false)

        let result = try #require(OsaurusImportTool.alreadyInstalledResult(review([tempo, step])))
        #expect(result.contains("\"status\":\"already_installed\""))
        #expect(result.contains("Tempo") && result.contains("Install the Tempo CLI"))

        #expect(OsaurusImportTool.alreadyInstalledResult(review([tempo, skillItem("Wallet")])) == nil)
        var plugin = ChatImportItem(
            id: "plugin:acme", kind: .plugin, name: "acme/tools", detail: "", origin: "",
            payload: .plugin(ChatImportPluginRepo(url: "https://github.com/acme/tools", owner: "acme", name: "tools")))
        plugin.state = .alreadyInstalled
        #expect(OsaurusImportTool.alreadyInstalledResult(review([plugin])) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct ChatImportSandboxAndPluginTests {

    @Test
    func skillFolder_isCopiedIntoTheSandboxHome() throws {
        let agent = "import-test-\(UUID().uuidString.prefix(6).lowercased())"
        let home = OsaurusPaths.containerAgentDir(agent)
        let skill = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: skill.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "print(1)".write(to: skill.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: skill)
        }
        #expect(SkillManager.mirrorSkillPackage(from: skill, slug: "pdf", agentName: agent) == nil, "no home, no copy")

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let guest = SkillManager.mirrorSkillPackage(from: skill, slug: "pdf", agentName: agent)
        #expect(guest == "/workspace/agents/\(agent)/skills/pdf")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("skills/pdf/scripts/run.py").path))
    }

    @Test
    func pluginAgentFiles_becomeTaggedAgents_updateInPlace_andUninstall() async throws {
        let pluginId = "github:acme/tools/\(UUID().uuidString.prefix(6).lowercased())"
        let installer = ClaudePluginInstaller.shared
        let first = try #require(
            installer.upsertPluginAgent(
                pluginId: pluginId, name: "Reviewer", frontmatter: ["description": "Reviews.", "tools": "Read, Grep"],
                body: "You review code."))
        #expect(first.pluginId == pluginId)
        #expect(first.autonomousExec?.enabled == false)
        #expect(first.autonomousExec?.sandboxNetworkEnabled == false)

        let second = try #require(
            installer.upsertPluginAgent(
                pluginId: pluginId, name: "Reviewer", frontmatter: ["description": "Reviews better."],
                body: "You review code thoroughly."))
        #expect(second.id == first.id, "an update replaces the agent in place")
        #expect(AgentManager.shared.agent(for: first.id)?.systemPrompt == "You review code thoroughly.")
        #expect(installer.upsertPluginAgent(pluginId: pluginId, name: "Empty", frontmatter: [:], body: "  ") == nil)

        let summary = await installer.uninstall(pluginId: pluginId)
        #expect(summary.importedAgentCount >= 1)
        #expect(AgentManager.shared.agent(for: first.id) == nil)
    }
}
