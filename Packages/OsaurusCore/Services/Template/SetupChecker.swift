//
//  SetupChecker.swift
//  osaurus
//
//  One readiness check for agents and installed workflows: "can this run
//  the way it is configured, on this Mac?" It looks only at machine-local
//  things a template can name but not grant: a working folder without a
//  bookmark, a model that is not installed, a knowledge grant with no
//  collections, a system permission the OS has not given, an MCP server or
//  plugin that is missing, a secret with no Keychain value, a model slot
//  bound to a model that cannot enforce the node schema.
//
//  Agents are checked on first show and before spawn; workflows before
//  every call. The same report feeds the setup wizard and the import
//  review, so a template's requirement and its check never drift apart.
//
//  Pure core (`check(_:environment:)`) so tests need no live services; the
//  `check(_:)` convenience wires the real ones.
//

import Foundation

public struct SetupItem: Identifiable, Equatable, Sendable {
    public enum Severity: Sendable {
        /// The agent cannot do what it was configured for until fixed.
        case blocking
        /// Worth confirming, but the agent runs without it.
        case advisory
    }

    public let kind: TemplateRequirement.Kind
    public let severity: Severity
    /// Short label, e.g. "Working folder".
    public let title: String
    /// What is wrong and what fixes it.
    public let detail: String
    /// The value involved (path, model id, permission raw value, tool names).
    public let value: String
    /// A key with no value for whoever runs the workflow, which Keys fills
    /// (not a sign-in, a connection, or a value to confirm again).
    public var isMissingKey: Bool = false
    /// A model slot that runs on nothing: its model is not here and no
    /// default model stands in.
    public var hasNoModel: Bool = false

    public var id: String { "\(kind.rawValue):\(value)" }
    public var isBlocking: Bool { severity == .blocking }
}

public struct SetupReport: Equatable, Sendable {
    /// The agent or installed workflow checked.
    public let subjectId: UUID
    public let items: [SetupItem]

    public init(subjectId: UUID, items: [SetupItem]) {
        self.subjectId = subjectId
        self.items = items
    }

    public var isClean: Bool { items.isEmpty }
    public var blocking: [SetupItem] { items.filter(\.isBlocking) }
    public var hasBlockers: Bool { !blocking.isEmpty }

    /// One-line summary for tool envelopes and toasts.
    public var summary: String {
        items.map { "\($0.title): \($0.detail)" }.joined(separator: " ")
    }
}

public enum SetupChecker {

    /// Whose Keys a workflow's secrets are checked against. Workflows are
    /// not tied to an agent: a run with no agent uses the keys shared by
    /// all agents, and an agent's run uses its own value first.
    public enum SecretAudience: Equatable, Sendable {
        /// Installing or listing. A missing key is advisory: the workflow
        /// installs, and Vault → Missing Keys lists it until a value exists.
        /// Sign-ins and connections still block.
        case install
        /// A run by this agent (nil: no agent, shared keys only).
        case caller(UUID?)

        var agentId: UUID? {
            if case .caller(let id) = self { return id }
            return nil
        }
    }

    /// Everything the check reads from the machine, injectable for tests.
    struct Environment {
        var registeredToolNames: Set<String>
        var modelCatalog: ConfigModelReference.Catalog
        var isPermissionGranted: (SystemPermission) -> Bool
        var bookmarkResolves: (Data) -> Bool
        var knowledgeCollectionExists: (UUID) -> Bool
        /// Tools per MCP server / plugin registered here.
        var toolGroups: [PortableToolGroup: [String]] = [:]
        /// The MCP servers / plugins the named source template turns on.
        var templateToolGroups: (String) -> [PortableToolGroup] = { _ in [] }
        /// Whether a Keychain value exists under a workflow secret account
        /// (`WorkflowSecretsKeychain.secretAccount(scope:key:)`).
        var secretPresent: (String) -> Bool = { _ in false }
        /// Whether the agent has its own value for that account's key, which
        /// overrides the shared one when the agent runs the workflow.
        var agentSecretPresent: (String, UUID) -> Bool = { _, _ in false }
        /// What a secret bound to a shared connection
        /// (`WorkflowSecretsKeychain.connectionBinding`) can use: `.ready`,
        /// `.signInNeeded(name)`, or `.missing` when the connection is gone.
        var connectionState: (String) -> ConnectionState = { _ in .missing }
        /// The connection a caller agent reads for a secret bound to one:
        /// its own session for that service, else the bound connection.
        var callerConnection: (String, UUID?) -> String = { bound, _ in bound }
        /// Native schema enforcement for a resolved model id over the
        /// output schemas its slot must produce (empty when unknown).
        var structuredOutput: (String, [JSONValue]) -> StructuredOutputSupport = { _, _ in .supported }
        /// The user's default model, used by `.preferred` slots left unbound.
        var defaultModel: String? = nil
        /// Whether a resolved model id can call tools; nil when unknown.
        var toolCalling: (String) -> Bool? = { _ in nil }
        /// Whether the code-node runtime (the JavaScriptCore helper) exists.
        var codeRuntimeAvailable: Bool = true
        /// Why a registered tool cannot run from a workflow (its policy is
        /// Deny, or it is a dynamic tool turned off), or nil when it can.
        var toolBlockReason: (String) -> String? = { _ in nil }
        /// Why a step's tool that runs its own model (AppleScript, image,
        /// video) has none to run on here, or nil.
        var capabilityBlockReason: (String) -> String? = { _ in nil }
        /// The system permissions a registered tool needs before it runs.
        var toolSystemPermissions: (String) -> [SystemPermission] = { _ in [] }
        /// Image and video models media steps could run on here.
        var mediaCandidates: [MediaModelCandidate] = []
        /// False until the model cache's first build finishes; until then
        /// `mediaCandidates` is empty for every machine.
        var mediaCandidatesLoaded: Bool = true
        /// The sandbox every dependency-declaring workflow runs in.
        var sandboxStatus: ContainerStatus = .notProvisioned
        /// `SandboxConfiguration.network`: "outbound", "proxy" or "none".
        var sandboxNetworkMode: String = "outbound"
        /// Whether a declared dependency is installed in the workflow's
        /// environment, keyed by template id.
        var dependencyStatus: (UUID, WorkflowDependency) -> WorkflowDependencyStatus = { _, _ in .notInstalled }
        /// The blocking setup problems of the installed workflow answering
        /// to this name (a `workflow` step's target), or nil when none is
        /// installed. A child's problems are the parent's too: the step
        /// cannot run until the child can.
        var installedWorkflowSetup: (String) -> [String]? = { _ in nil }
        /// Whether a bound workflow folder is a folder on disk.
        var folderExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        /// Skills installed here; nil skips the skill allow-list check.
        var installedSkills: [Skill]? = nil
        /// Why an agent step's agent (with the one chosen for it at setup)
        /// cannot be reached from this Mac, or nil when it can.
        var agentBlockReason: (AgentRequirement, String?) -> String? = { _, _ in nil }
        /// False until the workspace rosters have loaded once; until then a
        /// shared agent is only "not known yet".
        var workspacesLoaded: Bool = true
        /// The agent a tool step's `tool.agent` names, or nil when none here
        /// answers to it.
        var stepAgent: (String) -> WorkflowStepAgent.Match? = { _ in nil }
        /// The person is there to answer a macOS dialog: listing, the run
        /// page, a run from chat. Automations are not.
        var attended: Bool = false

        @MainActor
        static func live(secrets: SecretAudience = .caller(nil), attended: Bool = false) -> Environment {
            WorkflowToolCatalog.ensureRegistered()
            // Reading the collections folder blocks; the draft pane builds
            // this on every redraw.
            let knowledge = KnowledgeManager.shared
            let collections = Set(
                (knowledge.isRegistryLoaded ? knowledge.collections : KnowledgeCollectionStore.loadAll()).map(\.id))
            let mediaLoaded = ModelPickerItemCache.shared.isLoaded
            if !mediaLoaded { ModelPickerItemCache.shared.prewarm() }
            var env = Environment(
                registeredToolNames: Set(ToolRegistry.shared.listTools().map(\.name)),
                modelCatalog: ConfigModelReference.liveCatalog(),
                // Cached: a live Automation probe can itself trigger a system prompt.
                isPermissionGranted: { SystemPermissionService.shared.cachedIsGranted($0) },
                bookmarkResolves: { FolderContextService.resolveSecurityScopedURL(from: $0) != nil },
                knowledgeCollectionExists: { collections.contains($0) },
                toolGroups: ToolRegistry.shared.portableToolGroups(),
                templateToolGroups: { TemplateStore.shared.template(named: $0, kind: .agent)?.toolGroups ?? [] },
                secretPresent: { WorkflowCredentials.isSetUp(account: $0) },
                connectionState: { liveConnectionState($0) },
                structuredOutput: { StructuredOutputCapability.support(for: $0, schemas: $1) },
                defaultModel: ChatConfigurationStore.load().defaultModel
                    ?? DefaultAgentConfigurationStore.load().defaultModel,
                toolCalling: { id in ModelPickerItemCache.shared.items.first { $0.id == id }?.supportsToolCalling },
                codeRuntimeAvailable: JSHostLocator.executableURL() != nil,
                toolBlockReason: { liveToolBlockReason($0) },
                capabilityBlockReason: { liveCapabilityBlockReason($0) },
                toolSystemPermissions: { ToolRegistry.shared.policyInfo(for: $0)?.systemPermissions ?? [] },
                mediaCandidates: MediaModelResolver.liveCandidates(),
                sandboxStatus: SandboxManager.State.shared.status,
                sandboxNetworkMode: SandboxConfigurationStore.load().network,
                dependencyStatus: { WorkflowSandboxEnvironment.shared.status(of: $1, environmentID: $0) },
                installedWorkflowSetup: { liveSubworkflowSetup($0, secrets: secrets) },
                installedSkills: SkillManager.shared.skills
            )
            env.agentSecretPresent = { WorkflowCredentials.isSetUp(account: $0, agentId: $1) }
            env.callerConnection = { WorkflowConnectionSessions.binding(for: $0, agentId: $1) }
            env.mediaCandidatesLoaded = mediaLoaded
            let directory = AgentNodeExecutor.Directory.live()
            env.agentBlockReason = { req, binding in
                switch AgentNodeExecutor.resolve(req, binding: binding, in: directory) {
                case .unavailable(let reason): return reason
                case .target(let target):
                    return AgentNodeExecutor.isAllowed(target)
                        ? nil : AgentNodeExecutor.notAllowedMessage(target.name, isDefault: true)
                }
            }
            env.workspacesLoaded = WorkspaceRosterStore.shared.lastRefreshedAt != nil
            env.stepAgent = { WorkflowStepAgent.resolveLive($0) }
            env.attended = attended
            return env
        }

        /// Checks the named installed workflow in turn. A chain that comes
        /// back to a workflow already being checked, or runs deeper than a
        /// run may, stops reporting rather than recursing; the executor
        /// refuses those at run time.
        @MainActor
        private static func liveSubworkflowSetup(_ name: String, secrets: SecretAudience) -> [String]? {
            guard let child = InstalledWorkflowStore.shared.workflow(named: name) else { return nil }
            guard !checkingChain.contains(child.id), checkingChain.count < SubworkflowSpec.maximumDepth else {
                return []
            }
            return check(child, secrets: secrets).blocking.map { "\($0.title): \($0.detail)" }
        }
    }

    /// Workflows whose setup is being checked right now, outermost first.
    @MainActor private static var checkingChain: [UUID] = []

    enum ConnectionState: Equatable {
        case ready
        case signInNeeded(String)
        case missing
    }

    @MainActor
    static func liveConnectionState(_ binding: String) -> ConnectionState {
        let store = WorkflowConnectionStore.shared
        guard let connection = store.connection(binding: binding) else { return .missing }
        if connection.kind == .oauth2, connection.needsSignIn() { return .signInNeeded(connection.name) }
        return store.hasValue(connection) ? .ready : .missing
    }

    @MainActor
    static func liveToolBlockReason(_ name: String) -> String? {
        let registry = ToolRegistry.shared
        if registry.policyInfo(for: name)?.effectivePolicy == .deny {
            return L("\(name) is set to Deny in Tools. Change it to Ask or Auto to run this workflow.")
        }
        if registry.isDynamicRegisteredTool(named: name), !registry.isGlobalEnabled(name) {
            return L("\(name) is turned off in Tools. Turn it on to run this workflow.")
        }
        return nil
    }

    @MainActor
    static func liveCapabilityBlockReason(_ name: String) -> String? {
        let items = ModelPickerItemCache.shared.items
        switch name {
        case AppleScriptTool.toolName, MacQueryTool.toolName:
            guard !ModelPickerItemCache.shared.hasReadyAppleScriptModel else { return nil }
            return L("No AppleScript model is installed. Download one in Settings → Local Models → AppleScript.")
        case "image":
            guard items.imageGenerationDelegateCandidates.isEmpty else { return nil }
            return L("No image generation model is installed or connected. Download one in Local Models → Image.")
        case "video":
            guard items.videoGenerationDelegateCandidates.isEmpty else { return nil }
            return L("No video generation model is connected. Choose one in Model Defaults → Images & Video.")
        default:
            return nil
        }
    }

    // MARK: - Workflows

    /// `attended`: the person is there to answer a macOS dialog, so a
    /// permission a step's named agent still needs is advisory; the call
    /// asks for it. Automations keep it blocking.
    @MainActor
    public static func check(
        _ workflow: InstalledWorkflow, secrets: SecretAudience = .caller(nil), attended: Bool = false
    ) -> SetupReport {
        checkingChain.append(workflow.id)
        defer { checkingChain.removeLast() }
        let report = check(
            workflow.template, bindings: workflow.bindings, subjectId: workflow.id, secrets: secrets,
            environment: .live(secrets: secrets, attended: attended))
        guard InstalledWorkflowStore.shared.modifiedOutsideApp.contains(workflow.id) else { return report }
        return SetupReport(subjectId: report.subjectId, items: [integrityItem] + report.items)
    }

    /// The workflow's file no longer matches what Osaurus last saved, so
    /// its steps may not be the ones approved in setup.
    static var integrityItem: SetupItem {
        SetupItem(
            kind: .integrity, severity: .blocking, title: L("Changed outside Osaurus"),
            detail: L(
                "This workflow's file was edited outside Osaurus since it was last saved here. Review its steps in setup before it runs again."
            ),
            value: "file")
    }

    /// A template with candidate bindings, before anything is installed.
    /// The install wizard and test runs use this; `Next` on review is only
    /// enabled when it has no blockers. `agentsByName` is for an Architect
    /// draft built on this Mac, whose agent steps resolve as it names them.
    /// `attended` as for an installed workflow.
    @MainActor
    public static func check(
        _ template: Template, bindings: InstallBindings, subjectId: UUID, reconfirmSecrets: [String: String] = [:],
        secrets: SecretAudience = .caller(nil), agentsByName: Bool = false, attended: Bool = false
    ) -> SetupReport {
        check(
            template, bindings: bindings, subjectId: subjectId, reconfirmSecrets: reconfirmSecrets, secrets: secrets,
            agentsByName: agentsByName, environment: .live(secrets: secrets, attended: attended))
    }

    /// Whether every blocker is a key the caller lacks, which Keys fills
    /// rather than the setup wizard.
    public static func onlyKeysMissing(_ report: SetupReport) -> Bool {
        !report.blocking.isEmpty && report.blocking.allSatisfy(isMissingKey)
    }

    public static func isMissingKey(_ item: SetupItem) -> Bool { item.isMissingKey }

    /// The keys a report says are missing.
    public static func missingKeys(_ report: SetupReport) -> [String] {
        report.items.filter(\.isMissingKey).map(\.value)
    }

    /// The model id a slot runs on. An `always` slot runs only on its
    /// required model, whatever is bound. Otherwise: the binding, else the
    /// template's preferred model when present, else the default model.
    static func resolvedModel(
        for slot: ModelRequirement, bindings: InstallBindings, environment env: Environment
    ) -> String? {
        if let required = slot.requiredModel { return resolve(required, env) }
        if let bound = bindings.models[slot.slot] { return resolve(bound, env) }
        if let preferred = resolve(slot.preferred, env) { return preferred }
        return resolve(env.defaultModel, env)
    }

    private static func resolve(_ raw: String?, _ env: Environment) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if case .resolved(let id) = ConfigModelReference.resolve(raw, catalog: env.modelCatalog) { return id }
        return nil
    }

    /// The bound model when it is not the one an `always` slot requires.
    static func mismatchedBinding(
        for slot: ModelRequirement, bindings: InstallBindings, environment env: Environment
    ) -> String? {
        guard let required = slot.requiredModel, let bound = bindings.models[slot.slot] else { return nil }
        let boundID = resolve(bound, env) ?? bound
        let requiredID = resolve(required, env) ?? required
        return boundID.caseInsensitiveCompare(requiredID) == .orderedSame ? nil : bound
    }

    /// Whether `model` could be bound to `slot` without a blocking item:
    /// it resolves here, respects the slot's locality, and can enforce a
    /// response schema.
    static func canBind(_ model: String, to slot: ModelRequirement, environment env: Environment) -> Bool {
        var probe = InstallBindings()
        probe.models[slot.slot] = model
        guard let id = resolvedModel(for: slot, bindings: probe, environment: env),
            mismatchedBinding(for: slot, bindings: probe, environment: env) == nil
        else { return false }
        if slot.needsToolUse, env.toolCalling(id) == false { return false }
        if slot.locality == .localOnly, !isLocalModel(id, catalog: env.modelCatalog) { return false }
        if case .unsupported = env.structuredOutput(id, []) { return false }
        return true
    }

    static func isLocalModel(_ id: String, catalog: ConfigModelReference.Catalog) -> Bool {
        id == "foundation" || catalog.localModelIds.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Whether the slot's steps may reach a cloud model: false when it is
    /// local-only or requires a model that runs on this Mac.
    static func mayUseCloud(_ slot: ModelRequirement, catalog: ConfigModelReference.Catalog) -> Bool {
        if slot.locality == .localOnly { return false }
        if let required = slot.requiredModel { return !isLocalModel(required, catalog: catalog) }
        return true
    }

    /// `reconfirmSecrets` lists secret keys (with the reason) the person
    /// must confirm again even though a value is stored: an update that
    /// lets the workflow reach new hosts or tools asks before the old
    /// value travels there.
    static func check(
        _ template: Template, bindings: InstallBindings, subjectId: UUID, reconfirmSecrets: [String: String] = [:],
        secrets audience: SecretAudience = .caller(nil), agentsByName: Bool = false, environment env: Environment
    ) -> SetupReport {
        var items: [SetupItem] = []
        let reqs = template.requirements
        let def = template.workflow

        for slot in reqs.models {
            let label =
                WorkflowSummary.slotSteps(slot.slot, in: def).isEmpty
                ? L("Model slot \"\(slot.slot)\"") : WorkflowSummary.slotLabel(slot.slot, in: def)
            if let bound = mismatchedBinding(for: slot, bindings: bindings, environment: env),
                let required = slot.requiredModel
            {
                items.append(
                    SetupItem(
                        kind: .model, severity: .blocking, title: label,
                        detail: L("This workflow requires \(required), so \(bound) cannot be used. Choose \(required) for this slot."),
                        value: slot.slot))
                continue
            }
            guard let model = resolvedModel(for: slot, bindings: bindings, environment: env) else {
                let wanted = slot.requiredModel ?? bindings.models[slot.slot] ?? slot.preferred
                let detail: String
                if let required = slot.requiredModel {
                    detail = L("This workflow requires \(required). Install it or connect its provider.")
                } else if let wanted, wanted.caseInsensitiveCompare("default") != .orderedSame {
                    detail = L("\(wanted) is not available here and no default model is set. Choose a model for this slot.")
                } else {
                    detail = L("No default model is set. Choose a model for this slot.")
                }
                items.append(
                    SetupItem(
                        kind: .model, severity: .blocking, title: label, detail: detail, value: slot.slot,
                        hasNoModel: slot.requiredModel == nil))
                continue
            }
            if slot.locality == .localOnly, !isLocalModel(model, catalog: env.modelCatalog) {
                items.append(
                    SetupItem(
                        kind: .model, severity: .blocking, title: label,
                        detail: L("This slot is local only, so \(model) (a cloud model) cannot be bound to it. Choose a model that runs on this Mac."),
                        value: slot.slot))
                continue
            }
            if slot.needsToolUse, env.toolCalling(model) == false {
                items.append(
                    SetupItem(
                        kind: .model, severity: .blocking, title: label,
                        detail: L("\(model) can't call tools, and a step on this slot uses tools. Choose a model that can."),
                        value: slot.slot))
                continue
            }
            if case .unsupported(let reason) = env.structuredOutput(model, def?.outputSchemas(forSlot: slot.slot) ?? []) {
                items.append(
                    SetupItem(
                        kind: .model, severity: .blocking, title: label,
                        detail: L("\(model) cannot enforce the node output schema: \(reason) Choose a model with native structured output."),
                        value: slot.slot))
            }
        }

        for secret in reqs.secrets {
            // The account is the subject's own; a binding that points
            // elsewhere does not count as present.
            let account = WorkflowSecretsKeychain.secretAccount(scope: subjectId, key: secret.key)
            let bound = bindings.secrets[secret.key] ?? account
            if WorkflowSecretsKeychain.isConnectionAccount(bound) {
                switch env.connectionState(env.callerConnection(bound, audience.agentId)) {
                case .ready:
                    if let reason = reconfirmSecrets[secret.key] {
                        items.append(
                            SetupItem(kind: .secret, severity: .blocking, title: secret.label, detail: reason, value: secret.key))
                    }
                case .signInNeeded(let name):
                    items.append(
                        SetupItem(
                            kind: .secret, severity: .blocking, title: secret.label,
                            detail: L("The sign-in for \"\(name)\" has expired. Sign in again or choose another connection."),
                            value: secret.key))
                case .missing:
                    items.append(
                        SetupItem(
                            kind: .secret, severity: .blocking, title: secret.label,
                            detail: L("The connection this secret used is gone. Enter a value for \(secret.key) or choose another connection."),
                            value: secret.key))
                }
                continue
            }
            let ownAccount = WorkflowSecretsKeychain.isSecretAccount(bound, scope: subjectId, key: secret.key)
            let present =
                ownAccount
                && (env.secretPresent(account)
                    || audience.agentId.map { env.agentSecretPresent(account, $0) } == true)
            if !present {
                // A plain key a binding does not misdirect is a Keys entry:
                // it never stops an install, only a run that lacks it.
                let isKey = ownAccount && secret.oauth2 == nil
                let detail: String
                if secret.oauth2 != nil {
                    detail = L("Sign in for \(secret.key), or enter a token. The sign-in is kept in the Keychain on this Mac.")
                } else if case .install = audience {
                    detail = L("Enter a value for \(secret.key), or add it later in Settings → Vault. Until then, runs that need it stop.")
                } else {
                    detail = L("No value for \(secret.key). Add it in Settings → Vault, shared by all agents or only for the agent that runs this workflow.")
                }
                items.append(
                    SetupItem(
                        kind: .secret, severity: isKey && audience == .install ? .advisory : .blocking,
                        title: secret.label, detail: detail, value: secret.key, isMissingKey: isKey))
            } else if let reason = reconfirmSecrets[secret.key] {
                items.append(
                    SetupItem(kind: .secret, severity: .blocking, title: secret.label, detail: reason, value: secret.key))
            }
        }

        let connected = MCPServerResolution.connectedServers(in: env.toolGroups)
        let servers = MCPServerResolution.effectiveServers(
            for: template, bindings: bindings.mcpServers, connected: connected)
        for name in reqs.mcpServers {
            if servers[name] == nil {
                items.append(
                    SetupItem(
                        kind: .mcpServer, severity: .blocking, title: L("MCP Server"),
                        detail: L("\(name) is not connected on this Mac. Add or connect it in MCP Servers."),
                        value: name))
            }
        }
        for id in reqs.plugins {
            let local = bindings.plugins[id] ?? id
            if env.toolGroups[.plugin(local)] == nil {
                items.append(
                    SetupItem(
                        kind: .plugin, severity: .blocking, title: L("Plugin"),
                        detail: L("\(id) is not installed on this Mac. Install it in Plugins."),
                        value: id))
            }
        }
        for permission in reqs.systemPermissions where !env.isPermissionGranted(permission) {
            items.append(
                SetupItem(
                    kind: .systemPermission, severity: .blocking, title: permission.displayName,
                    detail: L("Grant \(permission.displayName) in System Settings."),
                    value: permission.rawValue))
        }

        items += dependencyItems(reqs.dependencies, environmentID: template.id, environment: env)
        items += folderItems(reqs.folders, bindings: bindings, environment: env)
        items += agentItems(
            def?.agentCalls.map(\.requirement) ?? reqs.agents, bindings: bindings, choiceRequired: !agentsByName,
            environment: env)
        for media in reqs.mediaModels {
            guard let reason = MediaModelResolver.blockReason(media, candidates: env.mediaCandidates) else { continue }
            // The step itself waits for the cache, so an unread cache only
            // means "not known yet".
            items.append(
                env.mediaCandidatesLoaded
                    ? SetupItem(kind: .mediaModel, severity: .blocking, title: media.label, detail: reason, value: media.id)
                    : SetupItem(
                        kind: .mediaModel, severity: .advisory, title: media.label,
                        detail: L("Still checking the installed models. The step looks again when it runs."),
                        value: media.id))
        }

        if let def, !def.javaScriptCodeNodes.isEmpty, !env.codeRuntimeAvailable {
            items.append(
                SetupItem(
                    kind: .network, severity: .blocking, title: L("Code Runtime"),
                    detail: L("This workflow has code nodes, but the JavaScript runtime helper is missing from this Osaurus build."),
                    value: "osaurus-js-host"))
        }
        // Shell and Python steps run in the workflow's sandbox even without
        // declared dependencies, so the sandbox must exist.
        if let def, def.hasSandboxSteps, reqs.dependencies.isEmpty, case .notProvisioned = env.sandboxStatus {
            let detail =
                def.hasPythonNodes
                ? L("This workflow has Python steps, which run in the Sandbox. Set it up in Settings → Sandbox.")
                : L("This workflow runs shell commands, which run in the Sandbox. Set it up in Settings → Sandbox.")
            items.append(
                SetupItem(
                    kind: .dependency, severity: .blocking, title: L("Sandbox"),
                    detail: detail,
                    value: "sandbox"))
        }
        for name in def?.subworkflowNames ?? [] {
            guard let problems = env.installedWorkflowSetup(name) else {
                items.append(
                    SetupItem(
                        kind: .tool, severity: .blocking, title: L("Workflow"),
                        detail: L("A step runs the workflow \"\(name)\", which is not installed on this Mac. Install it first."),
                        value: "workflow:" + name))
                continue
            }
            if !problems.isEmpty {
                items.append(
                    SetupItem(
                        kind: .tool, severity: .blocking, title: L("Workflow"),
                        detail: L(
                            "A step runs the workflow \"\(name)\", which needs setup first: \(problems.joined(separator: "; "))"
                        ),
                        value: "workflow:" + name))
            }
        }
        if let def = def.map({ MCPServerResolution.applying(servers, to: $0) }) {
            for tool in def.calledTools {
                let provider = tool.server ?? tool.plugin
                guard env.registeredToolNames.contains(tool.name) else {
                    if let provider, env.toolGroups[.mcpServer(provider)] == nil, env.toolGroups[.plugin(provider)] == nil {
                        continue  // Already reported as a missing server or plugin.
                    }
                    items.append(
                        SetupItem(
                            kind: provider == nil ? .tool : .mcpServer, severity: .blocking, title: L("Tool"),
                            detail: L("The tool \(tool.name) is not available on this Mac."),
                            value: tool.name))
                    continue
                }
                if let reason = env.toolBlockReason(tool.name) {
                    items.append(
                        SetupItem(kind: .tool, severity: .blocking, title: L("Tool"), detail: reason, value: tool.name))
                } else if let reason = capabilityBlockReason(tool.name, environment: env) {
                    items.append(
                        SetupItem(kind: .tool, severity: .blocking, title: L("Tool"), detail: reason, value: tool.name))
                }
            }
            items += stepAgentItems(def, environment: env)
            items += toolPermissionItems(
                def.calledTools.map(\.name), declared: Set(reqs.systemPermissions),
                askable: env.attended ? def.agentKeyedToolNames : [], environment: env)
        }
        return SetupReport(subjectId: subjectId, items: items)
    }

    /// Tool steps that run as a named agent: the agent must be here and,
    /// for an Apple app tool, have that app on.
    static func stepAgentItems(_ def: WorkflowDefinition, environment env: Environment) -> [SetupItem] {
        var items: [SetupItem] = []
        var seen = Set<String>()
        for call in def.agentKeyedToolCalls where seen.insert("\(call.agent)\u{0}\(call.tool)").inserted {
            guard let agent = env.stepAgent(call.agent) else {
                if seen.insert("missing\u{0}\(call.agent)").inserted {
                    items.append(
                        SetupItem(
                            kind: .agent, severity: .blocking, title: L("Agent"),
                            detail: WorkflowStepAgent.missingMessage(call.agent), value: call.agent))
                }
                continue
            }
            if let app = AppleApp.app(forTool: call.tool), !agent.enabledAppleApps.contains(app) {
                items.append(
                    SetupItem(
                        kind: .agent, severity: .blocking, title: agent.name,
                        detail: L("A step reads \(app.displayName) as \(agent.name), and \(app.displayName) is off for \(agent.name). Turn it on in the agent's Abilities."),
                        value: "\(call.agent):\(app.rawValue)"))
            }
        }
        return items
    }

    /// Why a step's tool that runs its own model cannot start on this Mac:
    /// the model it needs is missing. These tools need no agent toggle inside
    /// a workflow (the step authorizes them), so this is the only thing
    /// setup can check for them.
    static func capabilityBlockReason(_ name: String, environment env: Environment) -> String? {
        switch name {
        case BrowserUseTool.toolName, ComputerUseTool.toolName:
            guard env.defaultModel == nil else { return env.capabilityBlockReason(name) }
            return L("\(name) needs a chat model to drive it. Pick a default model in Settings → Models.")
        default:
            return env.capabilityBlockReason(name)
        }
    }

    /// System permissions the steps' tools need that the OS has not given
    /// (Accessibility for `computer_use`, an Apple app's access for its
    /// tools), each once. Permissions the template declares are reported
    /// with the template's own items.
    /// `askable` tools run where the person can answer the macOS dialog, so a
    /// permission only they need, and that macOS asks for, is advisory.
    static func toolPermissionItems(
        _ tools: [String], declared: Set<SystemPermission>, askable: Set<String> = [], environment env: Environment
    ) -> [SetupItem] {
        var needs: [(permission: SystemPermission, tool: String)] = []
        var blockingPermissions = Set<SystemPermission>()
        for tool in tools {
            for permission in env.toolSystemPermissions(tool)
            where !declared.contains(permission) && !env.isPermissionGranted(permission) {
                if !needs.contains(where: { $0.permission == permission }) { needs.append((permission, tool)) }
                if !askable.contains(tool) || !permission.promptsWhenMissing { blockingPermissions.insert(permission) }
            }
        }
        return needs.map { need in
            let blocking = blockingPermissions.contains(need.permission)
            return SetupItem(
                kind: .systemPermission, severity: blocking ? .blocking : .advisory,
                title: need.permission.displayName,
                detail: blocking
                    ? L("\(need.tool) needs \(need.permission.displayName). Grant it in System Settings.")
                    : L("\(need.tool) needs \(need.permission.displayName). macOS asks the first time the step runs."),
                value: need.permission.rawValue)
        }
    }

    /// Agent steps: each agent must be one this Mac can reach (its own, or
    /// shared in a workspace the person belongs to). Whether a shared
    /// agent is online is checked when the step runs. With
    /// `choiceRequired` (anything not built here), a step waits until the
    /// person picks its agent: a name in a template must not pick one of
    /// their agents for them.
    static func agentItems(
        _ agents: [AgentRequirement], bindings: InstallBindings, choiceRequired: Bool = true,
        environment env: Environment
    ) -> [SetupItem] {
        agents.compactMap { req in
            let bound = bindings.agents[req.id]
            if choiceRequired, bound == nil {
                return SetupItem(
                    kind: .agent, severity: .blocking, title: req.name,
                    detail: L("Choose which agent this step asks. The workflow names “\(req.name)”; pick it or another agent."),
                    value: req.id)
            }
            guard let reason = env.agentBlockReason(req, bound) else { return nil }
            if req.isShared, !env.workspacesLoaded, bound == nil || bound == InstallBindings.agentByName {
                return SetupItem(
                    kind: .agent, severity: .advisory, title: req.name,
                    detail: L("Still loading your workspaces. The step looks again when it runs."), value: req.id)
            }
            return SetupItem(kind: .agent, severity: .blocking, title: req.name, detail: reason, value: req.id)
        }
    }

    /// Declared folders: each must be bound to a folder that exists here.
    static func folderItems(
        _ folders: [FolderRequirement], bindings: InstallBindings, environment env: Environment
    ) -> [SetupItem] {
        folders.compactMap { folder in
            guard let path = bindings.folders[folder.key], !path.isEmpty else {
                let detail =
                    folder.hint.map { L("Choose the folder to use for \(folder.label), like \($0.path).") }
                    ?? L("Choose the folder to use for \(folder.label).")
                return SetupItem(kind: .folder, severity: .blocking, title: folder.label, detail: detail, value: folder.key)
            }
            guard env.folderExists(path) else {
                return SetupItem(
                    kind: .folder, severity: .blocking, title: folder.label,
                    detail: L("\(path) is not a folder on this Mac anymore. Choose the folder again."),
                    value: folder.key)
            }
            return nil
        }
    }

    /// Declared dependencies: the sandbox must exist, the package manager
    /// must be supported by this backend, every package must be installed
    /// in the workflow's environment, and the sandbox must have network
    /// unless everything is already installed.
    static func dependencyItems(
        _ dependencies: [WorkflowDependency], environmentID: UUID, environment env: Environment
    ) -> [SetupItem] {
        guard !dependencies.isEmpty else { return [] }
        var items: [SetupItem] = []
        let title = L("Dependency")

        if case .notProvisioned = env.sandboxStatus {
            items.append(
                SetupItem(
                    kind: .dependency, severity: .blocking, title: L("Sandbox"),
                    detail: L("This workflow installs its dependencies in the sandbox, which is not set up yet. Provision it in Settings → Sandbox."),
                    value: "sandbox"))
        } else if case .error(let message) = env.sandboxStatus {
            items.append(
                SetupItem(
                    kind: .dependency, severity: .blocking, title: L("Sandbox"),
                    detail: L("The sandbox is not working: \(message) Fix it in Settings → Sandbox."),
                    value: "sandbox"))
        }

        var needsInstall = false
        for dependency in dependencies {
            let packages = dependency.packages.joined(separator: ", ")
            switch env.dependencyStatus(environmentID, dependency) {
            case .installed:
                continue
            case .unsupportedHere:
                items.append(
                    SetupItem(
                        kind: .dependency, severity: .blocking, title: title,
                        detail: L("\(packages) needs the Linux sandbox (\(dependency.manager.displayName)), which this Mac does not have. Only pip and npm packages install here."),
                        value: dependency.id))
            case .notInstalled:
                needsInstall = true
                items.append(
                    SetupItem(
                        kind: .dependency, severity: .blocking, title: title,
                        detail: L("\(packages) (\(dependency.manager.displayName)) is not installed in this workflow's sandbox. Install it in the Dependencies step."),
                        value: dependency.id))
            case .stale:
                needsInstall = true
                items.append(
                    SetupItem(
                        kind: .dependency, severity: .blocking, title: title,
                        detail: L("\(packages) (\(dependency.manager.displayName)) was installed in an earlier sandbox. Install it again in the Dependencies step."),
                        value: dependency.id))
            case .reinstallOnRun:
                needsInstall = true
                items.append(
                    SetupItem(
                        kind: .dependency, severity: .advisory, title: title,
                        detail: L("\(packages) (\(dependency.manager.displayName)) was removed when the sandbox made room for other agents and workflows. The next run installs it again."),
                        value: dependency.id))
            }
        }

        if needsInstall {
            switch env.sandboxNetworkMode {
            case "none":
                items.append(
                    SetupItem(
                        kind: .dependency, severity: .blocking, title: L("Sandbox Network"),
                        detail: L("The sandbox has no network, so packages cannot be downloaded. Allow outbound network in Settings → Sandbox, then install."),
                        value: "sandbox-network"))
            case "proxy":
                items.append(
                    SetupItem(
                        kind: .dependency, severity: .advisory, title: L("Sandbox Network"),
                        detail: L("The sandbox only reaches allowed domains. If an install fails, add the package registry (pypi.org, files.pythonhosted.org, registry.npmjs.org) in Settings → Sandbox."),
                        value: "sandbox-network"))
            default:
                break
            }
        }
        return items
    }

    @MainActor
    public static func check(_ agent: Agent) -> SetupReport {
        check(agent, environment: .live())
    }

    static func check(_ agent: Agent, environment env: Environment) -> SetupReport {
        var items: [SetupItem] = []

        // Working folder: a path with no usable bookmark is the "orchestrator
        // said it has folder access but it loops forever" case.
        if let path = agent.workingFolderPath, !path.isEmpty {
            let ok = agent.workingFolderBookmark.map(env.bookmarkResolves) ?? false
            if !ok {
                items.append(
                    SetupItem(
                        kind: .workingFolder, severity: .blocking,
                        title: L("Working Folder"),
                        detail: L("The agent points at \(path) but Osaurus has no access to it. Pick the folder to grant access."),
                        value: path))
            }
        }

        // Model: pinned to something this Mac cannot route.
        if let model = agent.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            if case .invalid = ConfigModelReference.resolve(model, catalog: env.modelCatalog) {
                items.append(
                    SetupItem(
                        kind: .model, severity: .blocking,
                        title: L("Model"),
                        detail: L("\(model) is not installed or its provider is not connected. Install it or choose another model."),
                        value: model))
            }
        }

        // Knowledge: enabled with nothing to search, or grants pointing at
        // collections that do not exist here (a template from another Mac).
        if agent.settings.knowledgeEnabled {
            let granted = agent.settings.knowledgeCollectionIds
            let present = granted.filter(env.knowledgeCollectionExists)
            if present.isEmpty {
                items.append(
                    SetupItem(
                        kind: .knowledgeCollection, severity: .advisory,
                        title: L("Knowledge"),
                        detail: L("Knowledge is on but no collection is granted. Grant or create one so the agent has something to search."),
                        value: "knowledge"))
            }
        }

        // System permissions the runtime gate will refuse on first call.
        if agent.settings.computerUseEnabled, !env.isPermissionGranted(.accessibility) {
            items.append(
                SetupItem(
                    kind: .systemPermission, severity: .blocking,
                    title: L("Accessibility"),
                    detail: L("Computer Use needs the Accessibility permission. Grant it in System Settings."),
                    value: SystemPermission.accessibility.rawValue))
        }
        if agent.settings.appleScriptEnabled, !env.isPermissionGranted(.automation) {
            items.append(
                SetupItem(
                    kind: .systemPermission, severity: .advisory,
                    title: L("Automation"),
                    detail: L("AppleScript will ask for Automation permission the first time it controls an app."),
                    value: SystemPermission.automation.rawValue))
        }

        // Manual tool list naming tools no server or plugin here provides.
        if agent.toolSelectionMode == .manual {
            let missing = (agent.manualToolNames ?? []).filter { !env.registeredToolNames.contains($0) }
            if !missing.isEmpty {
                let joined = missing.sorted().joined(separator: ", ")
                items.append(
                    SetupItem(
                        kind: .mcpServer, severity: .advisory,
                        title: L("Tools"),
                        detail: L("Not available on this Mac: \(joined). Add the MCP server or plugin that provides them, or remove them from the agent."),
                        value: joined))
            }
        }

        // MCP servers / plugins the source template turns on that this Mac
        // does not have. They add no tool names to the agent, so the check
        // above cannot see them.
        if agent.toolSelectionMode == .manual, let source = agent.sourceTemplateName {
            for group in env.templateToolGroups(source) where env.toolGroups[group] == nil {
                switch group {
                case .mcpServer(let name):
                    items.append(
                        SetupItem(
                            kind: .mcpServer, severity: .advisory,
                            title: L("MCP Server"),
                            detail: L("The \(source) template uses the \(name) MCP server, which is not set up on this Mac. Add it in MCP Servers to give the agent its tools."),
                            value: name))
                case .plugin(let id):
                    items.append(
                        SetupItem(
                            kind: .plugin, severity: .advisory,
                            title: L("Plugin"),
                            detail: L("The \(source) template uses the \(id) plugin, which is not installed on this Mac. Install it in Plugins to give the agent its tools."),
                            value: id))
                }
            }
        }

        // Skill allow-list naming skills that are not installed here. The
        // agent runs; it just cannot load those skills.
        if let installed = env.installedSkills {
            let missing = agent.missingAllowListedSkills(in: installed)
            if !missing.isEmpty {
                let joined = missing.joined(separator: ", ")
                items.append(
                    SetupItem(
                        kind: .skill, severity: .advisory,
                        title: L("Skills"),
                        detail: L("Not installed on this Mac: \(joined). Install them in Skills, or remove them from the agent's skill list."),
                        value: joined))
            }
        }

        return SetupReport(subjectId: agent.id, items: items)
    }

    /// The agent with every tool of its source template's MCP servers and
    /// plugins that exist here now, for a group added after the agent was
    /// drafted or created. Groups already partly selected are left alone so
    /// a deliberate trim survives.
    static func addingTemplateGroupTools(
        to agent: Agent, groups: [PortableToolGroup], available: [PortableToolGroup: [String]]
    ) -> Agent {
        guard agent.toolSelectionMode == .manual else { return agent }
        var names = agent.manualToolNames ?? []
        var selected = Set(names)
        for group in groups {
            guard let tools = available[group], !tools.contains(where: selected.contains) else { continue }
            for tool in tools where selected.insert(tool).inserted { names.append(tool) }
        }
        var copy = agent
        copy.manualToolNames = names
        return copy
    }
}
