//
//  OsaurusConfigTool.swift
//  osaurus
//
//  `osaurus_config` — THE configuration surface for the Default agent.
//  One declarative YAML document describes Osaurus (memory, default
//  agent, custom agents, tools, delegation, commands, knowledge
//  collections, channels, MCP servers, models, plugins, cloud providers,
//  search providers, automations, model defaults, chat switches, app
//  basics); the tool exports it, plans a diff against current state, and
//  applies it. Server runtime settings are Settings-UI-only (scope
//  reduction 2).
//
//  Security invariants:
//   - Secrets NEVER travel through the document, the tool arguments, or
//     the results. Creating a cloud provider opens the native credential
//     sheet; keyed MCP/search providers come back `needs_user_action`
//     pointing at the right Settings pane.
//   - Named templates live ONLY in `~/.osaurus/templates/` — names are
//     sanitised and resolved paths are confined to that directory, so
//     neither the model nor a poisoned document can read or write
//     arbitrary files.
//   - `apply` runs under the standard `.ask` permission policy, and any
//     plan carrying high-risk changes (auto tool policies,
//     computer/browser use, relay exposure, channel write enables,
//     prune deletions, new MCP endpoints/stdio commands) forces an
//     explicit user approval that lists those risks — even if the user
//     set the tool to auto.
//   - Only Default-agent chat turns may call it (runtime gate), same as
//     every configure write before it.
//

import Foundation
import Yams

public final class OsaurusConfigTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_config"
    // The first sentence must stay ≤180 chars: the Default agent's compact
    // bootstrap schema keeps only that sentence.
    public let description =
        "Configure Osaurus by applying a declarative YAML document: agents, models, "
        + "plugins, MCP, providers, automations, tools, memory, delegation, commands, "
        + "knowledge, channels. "
        + "`action`: schema (the YAML reference — read it when unsure of a key), "
        + "export (current state as YAML; optional `sections` filter and `save_as` template name), "
        + "apply (validate + plan + execute in one step, gated by the native one-tap approval "
        + "card — the normal way to make a change; plus optional `prune` to delete entries not "
        + "listed in the document's declared sections — destructive, use only when the user wants "
        + "an exact mirror), "
        + "plan (dry-run diff of `yaml` or `template` against current state; changes nothing — "
        + "use it to preview a big or destructive change, then apply), "
        + "templates (list whole-config YAML templates in ~/.osaurus/templates plus library templates; "
        + "optional `kind`: agent, workflow, or all). Workflow templates are installed and run through "
        + "the `workflows` area, not applied here. "
        + "workflows (every installed workflow: name, input schema, setup status, orchestrator_can_run, agents; "
        + "bind one to a trigger in `automations` or give an agent it with `agents[].workflows`). "
        + "history (recorded configuration versions: when, who, which sections, the request; optional "
        + "`limit`, `section`, `since`), diff (exact changes between `from` and `to` — a version number, a "
        + "version's name, or `current`), revert (go back to version `to`, optionally only `sections`; "
        + "raises the same approval card as apply). "
        + "To create an agent from an agent template, pass its name as `template` with optional "
        + "`overrides` {name, description, system_prompt, model, capabilities}; prefer this over hand-picking tools "
        + "whenever the user names a template or one fits the request. "
        + "Documents are merge-by-default: absent keys stay untouched, explicit null clears an "
        + "override. Entities match by name. plan/apply accept YAML or JSON; export/schema take "
        + "format: \"json\" for machine-readable output. "
        + "Secrets never travel through the document — creating a "
        + "cloud provider opens the secure credential sheet, and keyed MCP/search providers report "
        + "needs_user_action for Settings. Never put an API key, token, or password in the YAML. "
        + "Setup text the user pasted (an MCP config block, an install command, a SKILL.md or agent "
        + "file), or a link to a page that says what to install, goes to `osaurus_import`; a server "
        + "address or plugin the user names directly is applied here."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("schema"), .string("export"), .string("plan"),
                    .string("apply"), .string("templates"), .string("workflows"),
                    .string("history"), .string("diff"), .string("revert"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "yaml": .object([
                "type": .string("string"),
                "description": .string(
                    "The YAML document for plan / apply. Mutually exclusive with `template`."),
            ]),
            "template": .object([
                "type": .string("string"),
                "description": .string(
                    "Saved template name (in ~/.osaurus/templates) for plan / apply. Accepts a "
                        + "whole-config YAML template or an agent template's name (see `templates`)."),
            ]),
            "kind": .object([
                "type": .string("string"),
                "enum": .array([.string("agent"), .string("workflow"), .string("all")]),
                "description": .string("For templates: which library templates to list. Default all."),
            ]),
            "overrides": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Name for the new agent (defaults to the template's)."),
                    ]),
                    "description": .object(["type": .string("string")]),
                    "system_prompt": .object(["type": .string("string")]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Model id; omit to keep the template's model."),
                    ]),
                    "capabilities": .object([
                        "type": .string("object"),
                        "additionalProperties": .object(["type": .string("boolean")]),
                        "description": .string("e.g. {calculator_enabled: true}"),
                    ]),
                ]),
                "description": .string(
                    "With an AGENT `template`: name, system prompt, capabilities merged onto its agent."),
            ]),
            "sections": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "For export / schema: only include these sections "
                        + "(e.g. [\"agents\", \"automations\"]). For revert: only put these sections back."),
            ]),
            "save_as": .object([
                "type": .string("string"),
                "description": .string(
                    "For export: also save the YAML as a named template in ~/.osaurus/templates."),
            ]),
            "prune": .object([
                "type": .string("boolean"),
                "description": .string(
                    "For plan / apply: delete entries NOT listed in the document's declared "
                        + "sections. Destructive — defaults to false."),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("For history: how many versions, newest first. Default 10, max 50."),
            ]),
            "section": .object([
                "type": .string("string"),
                "description": .string("For history: only versions that changed this section (e.g. agents)."),
            ]),
            "since": .object([
                "type": .string("string"),
                "description": .string("For history: only versions from this date on (e.g. 2026-11-04)."),
            ]),
            "from": .object([
                "type": .string("string"),
                "description": .string("For diff: the earlier version number or name."),
            ]),
            "to": .object([
                "type": .string("string"),
                "description": .string(
                    "For diff: the later version number, name, or `current` (default). For revert: the "
                        + "version number or name to go back to."),
            ]),
            "format": .object([
                "type": .string("string"),
                "enum": .array([.string("yaml"), .string("json")]),
                "description": .string(
                    "For export / schema: output format. Default yaml. plan / apply "
                        + "auto-accept both (JSON is a YAML subset)."),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    /// Apply can open user-paced credential sheets and approval prompts,
    /// so the tool opts out of the registry's 120s wall-clock budget.
    public var bypassRegistryTimeout: Bool { true }

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }
    /// Applies are gated by the dedicated in-chat plan-review card (see
    /// `handleApply`), which shows the actual diff — so the generic
    /// args-JSON approval panel is skipped to avoid a double prompt.
    var handlesOwnApproval: Bool { true }

    /// Documents larger than this are rejected outright.
    static let maxDocumentBytes = 512 * 1024

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(
            args,
            allowed: ["schema", "export", "plan", "apply", "templates", "workflows", "history", "diff", "revert"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "schema": return handleSchema(args)
        case "export": return await handleExport(args)
        case "plan": return await handlePlan(args)
        case "apply": return await handleApply(args)
        case "templates": return await handleTemplates(args)
        case "workflows": return await handleWorkflows()
        case "history": return await handleHistory(args)
        case "diff": return await handleDiff(args)
        case "revert": return await handleRevert(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    // MARK: - schema

    private enum SectionsFilterParse {
        case success(Set<ConfigSectionID>?)
        case failure(String)
    }

    /// Parse an optional `sections` array argument into section ids, with a
    /// closest-match suggestion on unknown names. `nil` means no filter.
    private func parseSectionsFilter(
        _ args: [String: Any]
    ) -> SectionsFilterParse {
        // Models send both `["agents"]` and the bare string `"agents"` (or
        // `"agents, schedules"`); silently ignoring the string form hands a
        // small model the full schema blob it was trying to avoid.
        let names: [String]
        if let raw = args["sections"] as? [Any] {
            names = raw.compactMap { $0 as? String }
        } else if let raw = args["sections"] as? String {
            names = raw.split(whereSeparator: { ", ".contains($0) }).map(String.init)
        } else {
            return .success(nil)
        }
        var resolved = Set<ConfigSectionID>()
        for candidate in names {
            guard let id = ConfigSectionID.parse(candidate) else {
                var message = "Unknown section `\(candidate)`."
                if let suggestion = Self.closestSectionName(to: candidate) {
                    message += " Did you mean `\(suggestion)`?"
                } else {
                    message += " Valid: " + ConfigSectionID.allNames.joined(separator: ", ") + "."
                }
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs, message: message, field: "sections", tool: name))
            }
            resolved.insert(id)
        }
        return .success(resolved.isEmpty ? nil : resolved)
    }

    /// Best section-name suggestion for a miss. Curated aliases first (the
    /// misses models actually make), then prefix containment.
    static func closestSectionName(to candidate: String) -> String? {
        let lowered = candidate.lowercased()
        let aliases: [String: String] = [
            "mcp": "mcp_servers",
            "mcps": "mcp_servers",
            "provider": "providers",
            "model": "models",
            "agent": "agents",
            "automation": "automations",
            "event": "automations",
            "events": "automations",
            "schedule": "automations",
            "schedules": "automations",
            "watcher": "automations",
            "watchers": "automations",
            "trigger": "automations",
            "triggers": "automations",
            "webhook": "automations",
            "command": "commands",
            "channel": "channels",
            "knowledge": "knowledge_collections",
        ]
        if let alias = aliases[lowered] { return alias }
        return ConfigSectionID.allNames.first {
            $0.hasPrefix(lowered) || lowered.hasPrefix($0)
        }
    }

    private static let schemaNextStep =
        "Compose the YAML for the section(s) you need and call action `apply` "
        + "(plan first is optional — apply plans and asks the user itself)."

    private func handleSchema(_ args: [String: Any]) -> String {
        guard let format = ConfigDocumentFormat.parse(args["format"] as? String) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`format` must be yaml or json.",
                field: "format", tool: name)
        }
        // Models routinely scope the ask ("sections": ["models"]); honoring
        // the filter keeps the reply inside a small model's budget instead
        // of returning the full multi-section blob it then re-requests.
        let filter: Set<ConfigSectionID>?
        switch parseSectionsFilter(args) {
        case .failure(let envelope): return envelope
        case .success(let resolved): filter = resolved
        }
        switch format {
        case .yaml:
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "schema": ConfigSchemaReference.text(sections: filter),
                    "sections": ConfigSectionID.allNames,
                    "next_step": Self.schemaNextStep,
                ]
            )
        case .json:
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "json_schema": ConfigManifest.jsonSchema(),
                    "sections": ConfigSectionID.allNames,
                    "next_step": Self.schemaNextStep,
                ]
            )
        }
    }

    // MARK: - export

    private func handleExport(_ args: [String: Any]) async -> String {
        let filter: Set<ConfigSectionID>?
        switch parseSectionsFilter(args) {
        case .failure(let envelope): return envelope
        case .success(let resolved): filter = resolved
        }

        guard let format = ConfigDocumentFormat.parse(args["format"] as? String) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`format` must be yaml or json.",
                field: "format", tool: name)
        }

        let document = await MainActor.run { ConfigExporter.export(sections: filter) }
        var result: [String: Any] = [:]
        let yaml: String
        do {
            // Templates are always saved as canonical YAML, even for a JSON
            // export — plan/apply accept both, and one on-disk format keeps
            // `templates` listings and hand edits predictable.
            yaml = try ConfigYAML.encode(document)
            switch format {
            case .yaml: result["yaml"] = yaml
            case .json: result["json"] = try ConfigJSON.encode(document)
            }
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to render the document: \(error.localizedDescription)",
                tool: name
            )
        }

        if let rawName = args["save_as"] as? String {
            switch ConfigTemplateStore.save(yaml: yaml, name: rawName) {
            case .success(let url):
                result["saved_to"] = url.path
            case .failure(let message):
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: message, field: "save_as", tool: name)
            }
        }
        // The settings-section read path (inspect's unknown-scope redirect)
        // lands here; without an outright next move small models re-export
        // or ask the user instead of applying.
        result["next_step"] =
            "These are the CURRENT values. To change them, call action `apply` with a "
            + "minimal document containing only the keys to change (same shape as this "
            + "export). If the user only asked a question, answer from these values."
        // A scoped export also carries the section's full key roster: the
        // exported YAML omits empty maps (e.g. `tools.policies` with no
        // entries), and models read that omission as "the key doesn't
        // exist" and invent alternatives.
        if let filter {
            result["yaml_shape"] = ConfigManifest.renderedSchemaSections(only: filter)
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - plan

    private func handlePlan(_ args: [String: Any]) async -> String {
        let prune = coerceBool(args["prune"]) ?? false
        let document: OsaurusConfigDocument
        let basedOn: AgentTemplate?
        let autoNamed: String?
        switch await loadDocument(args) {
        case .failure(let envelope): return envelope
        case .success(let doc, let template, let generatedName):
            document = doc
            basedOn = template
            autoNamed = generatedName
        }

        do {
            let plan = try await MainActor.run { [document] in
                var plan = try ConfigPlanner.plan(document: document, prune: prune)
                Self.annotate(&plan, basedOn: basedOn, autoNamed: autoNamed)
                return plan
            }
            var result = plan.payload()
            // The dry-run marker rides on the summary itself: models read
            // the summary, mistake it for an outcome, and narrate success
            // without ever calling apply. `status` is the typed twin.
            result["summary"] =
                plan.isEmpty
                ? plan.summaryText()
                : "[DRY RUN — nothing changed yet] " + plan.summaryText()
            result["status"] = plan.isEmpty ? "no_changes" : "dry_run_not_applied"
            result["prune"] = prune
            if plan.hasHighRiskChanges {
                result["note"] =
                    "This plan contains high-risk changes — apply will require explicit user approval."
            }
            // Small models stall here, re-planning the same document
            // instead of executing it (or asking the user "shall I?" —
            // approval is a native one-tap card, never a chat question);
            // say the next move outright.
            let sameInput =
                basedOn == nil
                ? "this same document"
                : "the same `template` and `overrides` (not a hand-written `agents:` entry, "
                    + "which would drop the template's settings)"
            result["next_step"] =
                plan.isEmpty
                ? "No changes — the current state already matches this document."
                : "Dry run only — NOTHING was changed. If the plan is right, call action "
                    + "`apply` with \(sameInput) NOW, in this same turn. The user "
                    + "approves via a native one-tap card — do not ask for confirmation in chat."
            return ToolEnvelope.success(tool: name, result: result)
        } catch let issues as ConfigPlanIssues {
            return invalidDocumentEnvelope(issues)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: error.localizedDescription, tool: name)
        }
    }

    // MARK: - apply

    private func handleApply(_ args: [String: Any]) async -> String {
        let prune = coerceBool(args["prune"]) ?? false
        let document: OsaurusConfigDocument
        let basedOn: AgentTemplate?
        let autoNamed: String?
        switch await loadDocument(args) {
        case .failure(let envelope): return envelope
        case .success(let doc, let template, let generatedName):
            document = doc
            basedOn = template
            autoNamed = generatedName
        }
        return await applyDocument(
            document, prune: prune, basedOn: basedOn, autoNamed: autoNamed,
            caller: Self.historyCaller(template: basedOn), requestText: ChatExecutionContext.currentUserRequest)
    }

    /// Plan, card, apply, report: the one path `apply` and `revert` share.
    func applyDocument(
        _ document: OsaurusConfigDocument, prune: Bool, basedOn: AgentTemplate?, autoNamed: String?,
        caller: ConfigChangeCaller, requestText: String?, leadingNotes: [String] = []
    ) async -> String {
        let plan: ConfigPlan
        do {
            plan = try await MainActor.run { [document] in
                var plan = try ConfigPlanner.plan(document: document, prune: prune)
                Self.annotate(&plan, basedOn: basedOn, autoNamed: autoNamed)
                plan.notes.insert(contentsOf: leadingNotes, at: 0)
                return plan
            }
        } catch let issues as ConfigPlanIssues {
            return invalidDocumentEnvelope(issues)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: error.localizedDescription, tool: name)
        }

        if plan.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "status": "no_changes",
                    "summary": plan.summaryText(),
                ]
            )
        }

        // EVERY apply gets the dedicated plan-review approval — the in-chat
        // card renders the structured diff (with risks highlighted and a
        // prune warning) and its answer resolves this await. This is the
        // single human gate for config changes: the tool opts out of the
        // generic registry approval panel (`handlesOwnApproval`), so the
        // headless task locals are re-checked HERE, mirroring
        // `ToolRegistry.runPermissionGate`: the default_agent eval lane
        // auto-approves, external/headless surfaces and unattended
        // schedule/watcher dispatches auto-deny (never park a card nobody
        // can answer, and never let an unattended run reconfigure the app).
        // The owner's paired phone is attended: its runs park the plan for
        // the phone to answer (`GET /config/approvals`, MOBILE_PROTOCOL
        // §16.3), with longer to read it than the Mac's card gives.
        let approval: ConfigApprovalOutcome
        var approvalId: UUID?
        if ChatExecutionContext.autoApproveToolPrompts {
            approval = .approved
        } else if ChatExecutionContext.denyUnapprovedToolPrompts
            || ChatExecutionContext.isUnattendedDispatch
            || (ChatExecutionContext.isExternalSurface && !ChatExecutionContext.hasRemoteReviewer)
        {
            // Nobody was asked, so the model must not be told the user said
            // no: that reads as a decision and ends the setup it was doing.
            return ToolEnvelope.failure(
                kind: .permissionDenied,
                message: "Configuration changes need the user's approval in the Osaurus app, "
                    + "and this run has no way to show it. Nothing was applied.",
                tool: name,
                retryable: false
            )
        } else if ChatExecutionContext.hasRemoteReviewer {
            let id = UUID()
            approvalId = id
            approval = await ConfigApprovalQueue.shared.requestApproval(
                plan: plan,
                prune: prune,
                fromPairedPhone: true,
                timeout: .seconds(300),
                id: id
            )
        } else {
            let id = UUID()
            approvalId = id
            approval = await ConfigApprovalService.requestApproval(plan: plan, prune: prune, id: id)
        }
        switch approval {
        case .approved:
            break
        case .denied:
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "User declined the configuration changes. Nothing was applied.",
                tool: name,
                retryable: false
            )
        case .timedOut:
            return ToolEnvelope.failure(
                kind: .timeout,
                message: "Configuration review timed out. Nothing was applied.",
                tool: name,
                retryable: false
            )
        case .cancelled:
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "Configuration review was cancelled. Nothing was applied.",
                tool: name,
                retryable: false
            )
        }

        let results = await ConfigApplier.apply(
            document: document, prune: prune, caller: caller, approvalId: approvalId, requestText: requestText)
        if let template = basedOn, let actions = template.quickActions,
            let name = document.agents?.first?.name,
            plan.actions.contains(where: { $0.section == "agents" && $0.target == name && $0.kind == .create })
        {
            // Quick actions ride on the template envelope, not the config
            // schema, so a freshly created agent picks them up here.
            await MainActor.run {
                guard var agent = AgentManager.shared.agents.first(where: { $0.name == name && !$0.isBuiltIn })
                else { return }
                agent.chatQuickActions = actions
                AgentManager.shared.update(agent)
            }
        }
        if Task.isCancelled {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Apply was cancelled; some changes may already have been made — "
                    + "run osaurus_config({action: 'plan', ...}) to see the remaining diff.",
                tool: name,
                retryable: false
            )
        }

        let failed = results.filter { $0.status == .failed }
        let cancelled = results.filter { $0.status == .cancelled }
        let needsAction = results.filter { $0.status == .needsUserAction }
        let started = results.filter { $0.status == .started }
        // "applied" must mean everything landed. Long-running work (model
        // downloads) is only STARTED at return time; say so at the top level
        // instead of letting a fire-and-forget download read as complete.
        // A user-cancelled step (e.g. dismissing the credential sheet) is
        // NOT applied either — report partial, never a clean success.
        let status: String
        if !failed.isEmpty || !cancelled.isEmpty {
            status = "partial"
        } else if !started.isEmpty {
            status = "applied_downloads_running"
        } else {
            status = "applied"
        }
        var result: [String: Any] = [
            "status": status,
            "results": results.map { $0.payload },
        ]
        var notes: [String] = []
        // Prune honesty: models remove an imagined entry by applying an
        // imagined keep-list, which CREATES the phantom entries and deletes
        // nothing — then they narrate a removal. Say what really happened.
        if prune {
            let deletes = plan.actions.filter { $0.kind == .delete }
            if deletes.isEmpty {
                notes.append(
                    "prune: true deleted NOTHING — no entry outside your keep-list existed. "
                        + "If you meant to remove an entry, it was not configured; tell the "
                        + "user that instead of reporting a removal.")
            }
            let creates = plan.actions.filter { $0.kind == .create }
            if !creates.isEmpty {
                notes.append(
                    "This apply CREATED \(creates.count) new entr\(creates.count == 1 ? "y" : "ies") "
                        + "(\(creates.map { $0.target }.joined(separator: ", "))) that were in "
                        + "your document but not previously configured — do not describe these "
                        + "as pre-existing or as survivors of a removal.")
            }
        }
        if !failed.isEmpty {
            notes.append("\(failed.count) change(s) failed — see results for messages.")
        }
        if !cancelled.isEmpty {
            notes.append(
                "\(cancelled.count) change(s) were cancelled by the user and did not land.")
        }
        if !needsAction.isEmpty {
            notes.append(
                "\(needsAction.count) change(s) need the user to finish a step in Settings "
                    + "(credentials never travel through this tool).")
        }
        if !started.isEmpty {
            notes.append(
                "\(started.count) download(s) started — poll osaurus_inspect({action: 'status'}).")
        }
        if !notes.isEmpty { result["notes"] = notes }
        // A clean success must SAY it is terminal. Every other action ends
        // with a next_step, and `plan`'s is "apply this document NOW" — so a
        // success with no next move trained small models that every envelope
        // implies another call. Observed live: an 8B orchestrator re-created
        // a just-created Watcher under variant names, twice, after a clean
        // apply. Name what landed and say stop.
        //
        // Gated on needsAction being empty as well: `status` stays "applied"
        // when a change merely needs the user to finish a step in Settings
        // (credentials), and a DONE-and-stop instruction there would tell the
        // model to bury exactly the step the notes surface. That case gets a
        // truthful next_step naming the outstanding user step instead.
        if status == "applied" {
            let landed = results.map { "\($0.section)[\($0.target)]" }
                .joined(separator: ", ")
            if needsAction.isEmpty {
                result["next_step"] =
                    "DONE — all changes landed"
                    + (landed.isEmpty ? "" : " (\(landed))")
                    + ". Report this to the user and stop. Do not plan or apply again "
                    + "unless the user asks for something different."
            } else {
                result["next_step"] =
                    "Changes landed, but \(needsAction.count) of them need the user to "
                    + "finish a step in Settings (see notes). Tell the user exactly which "
                    + "step remains, then stop — do not plan or apply again."
            }
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - templates

    private func handleTemplates(_ args: [String: Any]) async -> String {
        let rawKind = (args["kind"] as? String)?.lowercased() ?? "all"
        let kind: TemplateKind?
        switch rawKind {
        case "agent": kind = .agent
        case "workflow": kind = .workflow
        case "all": kind = nil
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`kind` must be agent, workflow, or all.", field: "kind", tool: name)
        }
        let templates = kind == nil ? ConfigTemplateStore.list() : []
        // Only templates the user flagged for the orchestrator. Hidden ones
        // are not listed at all, so the model cannot discover them by name.
        // `Template` is Sendable; the `[String: Any]` rows are built outside
        // the actor hop.
        let (visible, installed): ([Template], [UUID: InstalledWorkflow]) = await MainActor.run {
            TemplateStore.shared.reload()
            let byTemplate = Dictionary(
                InstalledWorkflowStore.shared.workflows.map { ($0.templateID, $0) }, uniquingKeysWith: { a, _ in a })
            return (TemplateStore.shared.orchestratorVisible(kind: kind), byTemplate)
        }
        let agentTemplates: [[String: Any]] = visible.filter { $0.kind == .agent }.map { template in
            var row: [String: Any] = [
                "name": template.name,
                "kind": "agent",
                "version": template.version,
            ]
            if let summary = template.summary, !summary.isEmpty { row["summary"] = summary }
            if let model = template.agent.model.valueOrNil { row["model"] = model }
            if let tools = template.agent.tools?.enabled, !tools.isEmpty { row["tools"] = tools }
            if let mcp = template.agent.mcpServers?.enabled, !mcp.isEmpty { row["mcp_servers"] = mcp }
            if let plugins = template.agent.plugins?.enabled, !plugins.isEmpty { row["plugins"] = plugins }
            if let sandbox = template.agent.sandbox?.enabled { row["sandbox"] = sandbox }
            if let subagents = template.agent.subagents?.enabled { row["subagents"] = subagents }
            if !template.bundled.isEmpty { row["bundled_workflows"] = template.bundled.map(\.name) }
            if !template.requires.isEmpty {
                row["requires"] = template.requires.map { "\($0.kind.rawValue): \($0.value)" }
            }
            return row
        }
        let workflowTemplates: [[String: Any]] = visible.filter { $0.kind == .workflow }.map { template in
            var row: [String: Any] = [
                "name": template.name,
                "kind": "workflow",
                "version": template.version,
            ]
            if let summary = template.summary, !summary.isEmpty { row["summary"] = summary }
            if let def = template.workflow {
                row["input_schema"] = def.inputSchema.compactJSONString
                row["nodes"] = def.nodes.count
            }
            if !template.requires.isEmpty {
                row["requires"] = template.requires.map { "\($0.kind.rawValue): \($0.value)" }
            }
            if let workflow = installed[template.id] {
                row["installed"] = ["name": workflow.name, "version": workflow.templateVersion]
            } else {
                row["installed"] = false
            }
            return row
        }
        var result: [String: Any] = ["directory": OsaurusPaths.configTemplates().path]
        if kind == nil { result["templates"] = templates }
        if kind != .workflow { result["agent_templates"] = agentTemplates }
        if kind != .agent { result["workflow_templates"] = workflowTemplates }
        if !agentTemplates.isEmpty {
            result["usage"] =
                "To create an agent from an agent template: {action: \"plan\", template: \"<name>\", "
                + "overrides: {name: \"...\", system_prompt: \"...\"}} then apply. The template fixes "
                + "model, tools, MCP servers, sandbox and subagent settings; only override what the "
                + "user asked to change. Opt-in tools are off by default: put "
                + "`capabilities: {calculator_enabled: true}` (math) or "
                + "`{redaction_tools_enabled: true}` (PII detection/redaction) in `overrides` when the "
                + "agent's job needs them."
        }
        if !workflowTemplates.isEmpty {
            result["workflow_usage"] =
                "Workflow templates are installed by the user through the setup wizard. "
                + "List installed workflows with {action: \"workflows\"}; run one with run_workflow."
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - workflows

    private struct WorkflowListing: Sendable {
        let name: String
        let toolName: String
        let summary: String?
        let version: Int
        let inputSchema: String
        let outputSchema: String
        let setupReasons: [String]
        let agents: [String]
        let orchestratorCanRun: Bool
    }

    /// Every installed workflow: automations and `agents[].workflows` can
    /// name any of them, while `run_workflow` only runs the ones the user
    /// marked runnable by Osaurus (`orchestrator_can_run`).
    private func handleWorkflows() async -> String {
        let listings: [WorkflowListing] = await MainActor.run {
            let agents = AgentManager.shared.agents
            return InstalledWorkflowStore.shared.workflows.map { workflow in
                WorkflowListing(
                    name: workflow.name, toolName: workflow.toolName, summary: workflow.summary,
                    version: workflow.templateVersion,
                    inputSchema: workflow.definition.inputSchema.compactJSONString,
                    outputSchema: workflow.definition.outputSchema.compactJSONString,
                    setupReasons: SetupChecker.check(workflow, secrets: .caller(Agent.defaultId)).blocking.map { "\($0.title): \($0.detail)" },
                    agents: agents.filter { $0.settings.enabledWorkflowIDs.contains(workflow.id) }.map(\.name),
                    orchestratorCanRun: workflow.orchestratorVisible)
            }
        }
        let rows: [[String: Any]] = listings.map { w in
            var row: [String: Any] = [
                "name": w.name, "tool_name": w.toolName, "version": w.version,
                "input_schema": w.inputSchema, "output_schema": w.outputSchema,
                "needs_setup": !w.setupReasons.isEmpty,
                "orchestrator_can_run": w.orchestratorCanRun,
            ]
            if let summary = w.summary, !summary.isEmpty { row["summary"] = summary }
            if !w.setupReasons.isEmpty { row["setup_reasons"] = w.setupReasons }
            if !w.agents.isEmpty { row["agents"] = w.agents }
            return row
        }
        let links: [(link: HostedWorkflowLink, agents: [String])] = await MainActor.run {
            let agents = AgentManager.shared.agents
            return HostedWorkflowLinkStore.shared.links.map { link in
                (link, agents.filter { $0.settings.enabledWorkflowIDs.contains(link.id) }.map(\.name))
            }
        }
        let hosted: [[String: Any]] = links.map { entry in
            let link = entry.link
            var row: [String: Any] = [
                "name": link.name, "tool_name": link.toolName, "input_schema": link.inputs.compactJSONString,
                "runs_on": link.hostLabel, "orchestrator_can_run": link.orchestratorVisible,
            ]
            if let summary = link.summary, !summary.isEmpty { row["summary"] = summary }
            if !entry.agents.isEmpty { row["agents"] = entry.agents }
            return row
        }
        await WorkspaceWorkflowCatalog.shared.refreshAll()
        let offered = await MainActor.run { WorkspaceWorkflowCatalog.shared.available() }
        let available: [[String: Any]] = offered.map { item in
            var row: [String: Any] = [
                "name": item.name, "workspace": item.workspaceName, "author": item.author, "kind": item.kind.rawValue,
            ]
            if !item.summary.isEmpty { row["summary"] = item.summary }
            return row
        }
        var result: [String: Any] = ["workflows": rows + hosted]
        if !available.isEmpty {
            result["available_in_workspaces"] = available
            result["available_usage"] =
                "available_in_workspaces are shared in the user's workspaces but not on this Mac yet; none of them "
                + "can run now. kind install: the user installs a copy in Main window → Workflows → Workspaces. "
                + "run_on_their_mac: the user adds it there (Add to My Workflows) and it runs on its owner's Mac "
                + "after they approve. both: either. Tell the user which one fits; never claim you ran it."
        }
        let emptyUsage =
            "No workflows are installed. A trigger that needs no workflow is still an `automations` entry: a "
            + "simple text task (a quote, a reminder) takes `instructions` alone however often it fires, tool "
            + "work an existing agent + `instructions`. Only a new multi-step process (fetch, then summarize, "
            + "then post) is designed with architect_handoff (put its trigger in the brief); the user can also "
            + "add one in Main window → Workflows."
        let runUsage =
            "Run one with orchestrator_can_run now with run_workflow {workflow: \"<name>\", input: {...}} matching "
            + "its input_schema; the others the user must mark \"Osaurus can run this for you\" in Main window → "
            + "Workflows first. A workflow with needs_setup cannot run until the user finishes setup there. To let a "
            + "custom agent call workflows, apply `agents: [{name: \"<agent>\", workflows: [\"<name>\"]}]`."
        let triggerUsage =
            "To run any of them (orchestrator_can_run or not) from a trigger, apply an `automations` entry (or a "
            + "`channels.<platform>.routing` rule) with `workflow: \"<name>\"` and an `input` map that binds EVERY key in input_schema.required to a "
            + "trigger value (e.g. \"{{schedule.scheduled_for}}\", \"{{webhook.body.title}}\", \"{{message.text}}\") "
            + "or fixed text. A required key left out takes its schema default; one with no default must be "
            + "bound, or the plan is refused."
        let hostedUsage =
            hosted.isEmpty
            ? ""
            : " A row with runs_on runs on that teammate's Mac: they approve each run, and an automation can't "
                + "start it."
        result["usage"] = rows.isEmpty && hosted.isEmpty ? emptyUsage : runUsage + " " + triggerUsage + hostedUsage
        return ToolEnvelope.success(tool: name, result: result)
    }

    /// Who configuration history credits with an apply from this tool.
    static func historyCaller(template: AgentTemplate?) -> ConfigChangeCaller {
        if let template { return .templateInstall(templateId: template.slug) }
        if ChatExecutionContext.hasRemoteReviewer {
            return .pairedPhone(
                deviceKey: ChatExecutionContext.syncReviewerScope ?? ChatExecutionContext.currentSessionId ?? "")
        }
        return .configurator(sessionId: ChatExecutionContext.currentSessionId ?? "")
    }

    /// Plan note so the approval card and the model both see the lineage.
    @MainActor
    private static func annotate(
        _ plan: inout ConfigPlan, basedOn template: AgentTemplate?, autoNamed: String? = nil
    ) {
        guard let template else { return }
        plan.notes.insert("Based on template: \(template.name)", at: 0)
        if let autoNamed {
            plan.notes.insert(
                "No `overrides.name` given, so the agent is named `\(autoNamed)`. "
                    + "To use the name the user asked for, pass `overrides: {name: \"...\"}`.",
                at: 1)
        }
        if case .fallbackToDefault(let requested) = template.modelResolution() {
            plan.notes.append(
                "Template prefers model `\(requested)`, which is not installed here; "
                    + "the agent uses the default model instead.")
        }
        let missing = AgentBundlePlan.make(for: template).rows.filter { $0.state == .missingTemplate }
        if !missing.isEmpty {
            plan.notes.append(
                "Workflows this template references but this Mac does not have (the agent is created "
                    + "without them): " + missing.map(\.name).joined(separator: ", ") + ".")
        }
        let unresolved = template.requires.filter { $0.kind != .model }
        if !unresolved.isEmpty {
            plan.notes.append(
                "Template setup to confirm after apply: "
                    + unresolved.map { "\($0.kind.rawValue) \($0.value)" }.joined(separator: ", ") + ".")
        }
    }

    // MARK: - Document loading

    private enum DocumentLoad {
        case success(OsaurusConfigDocument, basedOn: AgentTemplate?, autoNamed: String? = nil)
        case failure(String)
    }

    /// Parses the `overrides` argument into a Sendable entry BEFORE the
    /// main-actor hop (the raw `[String: Any]` cannot cross it).
    private static func parseOverrides(_ raw: Any?) -> Result<AgentEntry?, OverridesError> {
        guard let dict = raw as? [String: Any] else { return .success(nil) }
        let unknownKeys = dict.keys.filter { !overrideKeys.contains($0) }.sorted()
        guard unknownKeys.isEmpty else {
            return .failure(
                OverridesError(
                    "Unknown `overrides` key(s): \(unknownKeys.joined(separator: ", ")). "
                        + "Valid keys: \(overrideKeys.sorted().joined(separator: ", "))."))
        }
        var entry = AgentEntry(name: (dict["name"] as? String) ?? "")
        entry.description = dict["description"] as? String
        entry.systemPrompt = dict["system_prompt"] as? String
        if let model = dict["model"] as? String, !model.isEmpty { entry.model = .value(model) }
        if let caps = dict["capabilities"] {
            let valid = AgentCapabilitiesEntry.CodingKeys.allCases.map(\.rawValue)
            guard let capsDict = caps as? [String: Any] else {
                return .failure(OverridesError("`overrides.capabilities` must be a mapping, e.g. {calculator_enabled: true}."))
            }
            let unknown = capsDict.keys.filter { !valid.contains($0) }.sorted()
            guard unknown.isEmpty else {
                return .failure(
                    OverridesError(
                        "Unknown `overrides.capabilities` key(s): \(unknown.joined(separator: ", ")). "
                            + "Valid keys: \(valid.joined(separator: ", "))."))
            }
            let nonBoolean = capsDict.filter { !Self.isBoolean($0.value) }.keys.sorted()
            guard nonBoolean.isEmpty else {
                return .failure(
                    OverridesError(
                        "`overrides.capabilities` takes on/off toggles (true or false); "
                            + "\(nonBoolean.joined(separator: ", ")) is not one. Set list fields "
                            + "in an `agents:` entry in `yaml` instead."))
            }
            guard let data = try? JSONSerialization.data(withJSONObject: capsDict),
                let decoded = try? JSONDecoder().decode(AgentCapabilitiesEntry.self, from: data)
            else {
                return .failure(OverridesError("`overrides.capabilities` could not be read."))
            }
            entry.capabilities = decoded
        }
        return .success(entry)
    }

    /// `JSONSerialization` hands numbers and booleans back as `NSNumber`, and
    /// `as? Bool` accepts 0 and 1; only a real boolean counts.
    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    struct OverridesError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Builds the one-agent document for an agent template plus `overrides`.
    @MainActor
    private func agentTemplateDocument(
        named templateName: String, overrides: AgentEntry?
    ) -> DocumentLoad? {
        TemplateStore.shared.reload()
        guard let template = TemplateStore.shared.template(named: templateName, kind: .agent) else { return nil }
        guard template.availableToOrchestrator else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Template `\(template.name)` is not available to the orchestrator. "
                        + "The user can enable it from the Templates tab (Show to Orchestrator).",
                    field: "template", tool: name))
        }
        // A template that insists on its model cannot be applied without it.
        // The orchestrator can still pass `overrides.model` to substitute.
        if overrides?.model.isSpecified != true,
            case .blocked(let requested) = template.modelResolution()
        {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Template `\(template.name)` requires model `\(requested)`, which is not "
                        + "installed on this Mac. Ask the user to install it (list it under `models:` "
                        + "for a local model, or connect the provider), or pass `overrides.model` "
                        + "to substitute a model the user chose.",
                    field: "template", tool: name))
        }
        // Workflow installs need the setup wizard (secrets, models, review),
        // so a template whose workflows are not on this Mac yet is refused
        // rather than creating the agent without them.
        let bundle = AgentBundlePlan.make(for: template)
        if !bundle.pending.isEmpty {
            let names = bundle.pending.map(\.name)
            return .failure(
                ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "Template `\(template.name)` needs these workflows installed first: "
                        + names.joined(separator: ", ") + ". Nothing was applied. Ask the user to "
                        + "create the agent from its card in Settings → Agents → Templates; the setup "
                        + "wizard installs the workflows first.",
                    field: "template", tool: name, retryable: false,
                    metadata: ["status": "needs_setup", "workflows": names]))
        }
        var document = OsaurusConfigDocument()
        document.version = 1
        // Knowledge collection names resolve to this Mac's ids here, and a
        // missing `preferred` model becomes null (default model).
        var entry = template.resolvedEntry(overrides: overrides)
        entry.sourceTemplate = template.name
        let workflowNames = bundle.enabledWorkflowIDs.compactMap { InstalledWorkflowStore.shared.workflow(id: $0)?.name }
        if !workflowNames.isEmpty {
            var names = entry.workflows ?? []
            for workflow in workflowNames where !names.contains(workflow) { names.append(workflow) }
            entry.workflows = names
        }
        // Agents match by name, so a second use of the same template without
        // `overrides.name` would silently rewrite the first agent. Give it a
        // free name instead; an explicit name still updates on purpose.
        if (overrides?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let taken = Set(AgentManager.shared.agents.map { AgentTemplate.slug(for: $0.name) })
            entry.name = AgentTemplate.availableName(for: entry.name, takenSlugs: taken)
            document.agents = [entry]
            return .success(document, basedOn: template, autoNamed: entry.name)
        }
        document.agents = [entry]
        return .success(document, basedOn: template)
    }

    /// Models that fill every argument send `yaml: "{}"` next to a
    /// `template`; an empty document carries nothing, so it counts as absent.
    static func isEmptyDocument(_ yaml: String) -> Bool {
        ["", "{}", "null", "~"].contains(yaml.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Keys `overrides` accepts on an agent template.
    static let overrideKeys: Set<String> = ["name", "description", "system_prompt", "model", "capabilities"]

    /// The agent fields in a `yaml` sent next to an agent `template`: a bare
    /// mapping of override keys, or a one-entry `agents:` list of them, with
    /// an `overrides:` mapping inside either folded in. Nil for anything else
    /// (a whole document), which stays a conflict.
    static func agentFields(inYAML yaml: String) -> [String: Any]? {
        guard let tree = try? Yams.load(yaml: yaml),
            JSONSerialization.isValidJSONObject(tree),
            let data = try? JSONSerialization.data(withJSONObject: tree),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var fields = root
        if Set(root.keys) == ["agents"] {
            guard let list = root["agents"] as? [[String: Any]], list.count == 1 else { return nil }
            fields = list[0]
        }
        if let nested = fields.removeValue(forKey: "overrides") {
            guard let nested = nested as? [String: Any] else { return nil }
            fields.merge(nested) { outer, _ in outer }
        }
        guard !fields.isEmpty, Set(fields.keys).isSubset(of: overrideKeys) else { return nil }
        return fields
    }

    private func conflictingYAMLEnvelope() -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Pass `yaml` OR `template`, not both. With an agent `template`, put the agent's "
                + "name, system_prompt, model, and capabilities in `overrides`; without one, send the "
                + "whole `agents:` entry in `yaml`.",
            field: "yaml",
            tool: name,
            retryable: false)
    }

    private func loadDocument(_ args: [String: Any]) async -> DocumentLoad {
        let trimmedYAML = (args["yaml"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let inlineYAML = trimmedYAML.flatMap { Self.isEmptyDocument($0) ? nil : $0 }
        let templateName = (args["template"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let yaml: String
        if let templateName, !templateName.isEmpty {
            var rawOverrides = (args["overrides"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
            let overridesFromYAML = inlineYAML != nil
            if let inlineYAML {
                guard rawOverrides == nil, let fields = Self.agentFields(inYAML: inlineYAML) else {
                    return .failure(conflictingYAMLEnvelope())
                }
                rawOverrides = fields
            }
            let overrides: AgentEntry?
            switch Self.parseOverrides(rawOverrides) {
            case .success(let entry): overrides = entry
            case .failure(let error):
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs, message: error.message, field: "overrides", tool: name,
                        retryable: false))
            }
            // Agent templates (Templates tab) take precedence over whole-config
            // YAML templates of the same name.
            if let load = await agentTemplateDocument(named: templateName, overrides: overrides) {
                return load
            }
            switch ConfigTemplateStore.load(name: templateName) {
            case .success(let contents):
                if overridesFromYAML { return .failure(conflictingYAMLEnvelope()) }
                yaml = contents
            case .failure(let message):
                // The library loads in the background; wait for it (without
                // blocking the main actor) so the hint lists user templates.
                await TemplateStore.shared.libraryLoaded()
                let agentNames = await MainActor.run {
                    TemplateStore.shared.orchestratorVisible(kind: .agent).map(\.name)
                }
                let hint = agentNames.isEmpty
                    ? ""
                    : " Agent templates: \(agentNames.joined(separator: ", "))."
                // `overrides` only applies to agent templates, so the caller is
                // creating an agent; the saved-document hint would mislead it.
                let starterId = templateName.lowercased()
                let fullMessage: String
                if overrides == nil {
                    fullMessage = message + hint
                } else if AgentStarterTemplate.configTemplateIds.contains(starterId) {
                    fullMessage =
                        "`\(templateName)` is a starter prompt, not an agent template. Call this action "
                        + "with `yaml` holding an `agents:` entry that sets `template: \(starterId)`.\(hint)"
                } else {
                    fullMessage =
                        "No agent template named `\(templateName)`.\(hint) To create the agent "
                        + "without a template, call this action with an `agents:` entry in `yaml` instead."
                }
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs, message: fullMessage, field: "template", tool: name))
            }
        } else if let inlineYAML {
            yaml = inlineYAML
        } else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Provide the document as `yaml` (inline) or `template` (saved name). "
                        + "Call {action: 'schema'} for the YAML reference.",
                    tool: name))
        }

        if yaml.utf8.count > Self.maxDocumentBytes {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Document too large (max \(Self.maxDocumentBytes / 1024) KB).",
                    field: "yaml",
                    tool: name))
        }

        do {
            return .success(try ConfigYAML.decode(yaml), basedOn: nil)
        } catch let error as ConfigYAMLError {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Document is invalid — nothing was changed:\n"
                        + error.messages.map { "• \($0)" }.joined(separator: "\n"),
                    field: "yaml",
                    tool: name))
        } catch {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Could not parse YAML: \(error.localizedDescription)",
                    field: "yaml",
                    tool: name))
        }
    }

    private func invalidDocumentEnvelope(_ issues: ConfigPlanIssues) -> String {
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Document is invalid — nothing was changed:\n"
                + issues.issues.map { "• \($0)" }.joined(separator: "\n"),
            field: "yaml",
            tool: name
        )
    }
}

// MARK: - Template store (path-confined)

/// Named YAML templates under `~/.osaurus/templates/`. The ONLY file
/// surface `osaurus_config` has: names are sanitised to a strict character
/// set and the resolved path is verified to stay inside the directory, so
/// neither the model nor a poisoned document can escape it.
enum ConfigTemplateStore {
    private static let allowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    enum Outcome<T> {
        case success(T)
        case failure(String)
    }

    /// Sanitise a template name into `<name>.yaml`, or explain why not.
    static func sanitizedFileName(_ raw: String) -> Outcome<String> {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".yaml", ".yml"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        guard !name.isEmpty, name.count <= 100 else {
            return .failure("Template name must be 1...100 characters.")
        }
        guard name.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return .failure(
                "Template name may only contain letters, digits, `.`, `_`, and `-` "
                    + "(no path separators).")
        }
        guard !name.hasPrefix(".") else {
            return .failure("Template name may not start with a dot.")
        }
        return .success(name + ".yaml")
    }

    /// Resolve a sanitised file name to a URL confined to the templates dir.
    /// Symlinks are resolved BEFORE the prefix check: a symlink planted
    /// inside `~/.osaurus/templates/` (e.g. `foo.yaml -> /etc/hosts`) must
    /// not let template load read files outside the directory.
    private static func confinedURL(fileName: String) -> URL? {
        let dir = OsaurusPaths.configTemplates()
            .resolvingSymlinksInPath().standardizedFileURL
        let url = dir.appendingPathComponent(fileName)
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(dir.path + "/") else { return nil }
        return url
    }

    static func save(yaml: String, name raw: String) -> Outcome<URL> {
        switch sanitizedFileName(raw) {
        case .failure(let message): return .failure(message)
        case .success(let fileName):
            guard let url = confinedURL(fileName: fileName) else {
                return .failure("Template name resolves outside the templates directory.")
            }
            do {
                try OsaurusPaths.ensureExists(OsaurusPaths.configTemplates())
                try Data(yaml.utf8).write(to: url, options: .atomic)
                return .success(url)
            } catch {
                return .failure("Could not save template: \(error.localizedDescription)")
            }
        }
    }

    static func load(name raw: String) -> Outcome<String> {
        switch sanitizedFileName(raw) {
        case .failure(let message): return .failure(message)
        case .success(let fileName):
            guard let url = confinedURL(fileName: fileName) else {
                return .failure("Template name resolves outside the templates directory.")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                let available = list()
                let hint = available.isEmpty
                    ? "No templates saved yet — export with `save_as` to create one."
                    : "Available: \(available.joined(separator: ", "))."
                return .failure("No template named `\(raw)`. \(hint)")
            }
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? Int,
                size <= OsaurusConfigTool.maxDocumentBytes
            else {
                return .failure("Template is too large or unreadable.")
            }
            do {
                return .success(try String(contentsOf: url, encoding: .utf8))
            } catch {
                return .failure("Could not read template: \(error.localizedDescription)")
            }
        }
    }

    static func list() -> [String] {
        let dir = OsaurusPaths.configTemplates()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
