//
//  OsaurusConfigTool.swift
//  osaurus
//
//  `osaurus_config` — THE configuration surface for the Default agent.
//  One declarative YAML document describes Osaurus (memory, default
//  agent, custom agents, tools, delegation, commands, knowledge
//  collections, channels, MCP servers, models, plugins, cloud providers,
//  search providers, schedules, watchers); the tool exports it, plans a
//  diff against current state, and applies it. Server runtime, chat
//  behavior, and app shell settings are Settings-UI-only (scope
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

public final class OsaurusConfigTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_config"
    // The first sentence must stay ≤180 chars: the Default agent's compact
    // bootstrap schema keeps only that sentence.
    public let description =
        "Configure Osaurus with one declarative YAML document: export current config, "
        + "plan a diff, and apply it (agents, models, plugins, MCP, providers, schedules, "
        + "watchers, tools, memory, delegation, commands, knowledge, channels). "
        + "`action`: schema (the YAML reference — read it before writing a document), "
        + "export (current state as YAML; optional `sections` filter and `save_as` template name), "
        + "plan (dry-run diff of `yaml` or `template` against current state; ALWAYS plan before apply "
        + "and show the user the summary), "
        + "apply (validate + plan + execute; same inputs as plan, plus optional `prune` to delete "
        + "entries not listed in the document's declared sections — destructive, use only when the "
        + "user wants an exact mirror), "
        + "templates (list saved templates in ~/.osaurus/templates). "
        + "Documents are merge-by-default: absent keys stay untouched, explicit null clears an "
        + "override. Entities match by name. plan/apply accept YAML or JSON; export/schema take "
        + "format: \"json\" for machine-readable output. "
        + "Secrets never travel through the document — creating a "
        + "cloud provider opens the secure credential sheet, and keyed MCP/search providers report "
        + "needs_user_action for Settings. Never put an API key, token, or password in the YAML."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("schema"), .string("export"), .string("plan"),
                    .string("apply"), .string("templates"),
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
                    "Saved template name (in ~/.osaurus/templates) for plan / apply."),
            ]),
            "sections": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "For export / schema: only include these sections "
                        + "(e.g. [\"agents\", \"schedules\"])."),
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
            args, allowed: ["schema", "export", "plan", "apply", "templates"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "schema": return handleSchema(args)
        case "export": return await handleExport(args)
        case "plan": return await handlePlan(args)
        case "apply": return await handleApply(args)
        case "templates": return handleTemplates()
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
            guard let id = ConfigSectionID(rawValue: candidate.lowercased()) else {
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
            "schedule": "schedules",
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
        switch loadDocument(args) {
        case .failure(let envelope): return envelope
        case .success(let doc): document = doc
        }

        do {
            let plan = try await MainActor.run {
                try ConfigPlanner.plan(document: document, prune: prune)
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
            result["next_step"] =
                plan.isEmpty
                ? "No changes — the current state already matches this document."
                : "Dry run only — NOTHING was changed. If the plan is right, call action "
                    + "`apply` with this same document NOW, in this same turn. The user "
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
        switch loadDocument(args) {
        case .failure(let envelope): return envelope
        case .success(let doc): document = doc
        }

        let plan: ConfigPlan
        do {
            plan = try await MainActor.run {
                try ConfigPlanner.plan(document: document, prune: prune)
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
        let approved: Bool
        if ChatExecutionContext.autoApproveToolPrompts {
            approved = true
        } else if ChatExecutionContext.denyUnapprovedToolPrompts
            || ChatExecutionContext.isExternalSurface
            || ChatExecutionContext.isUnattendedDispatch
        {
            approved = false
        } else {
            approved = await ConfigApprovalService.requestApproval(plan: plan, prune: prune)
        }
        if !approved {
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "User declined the configuration changes. Nothing was applied.",
                tool: name,
                retryable: false
            )
        }

        let results = await ConfigApplier.apply(document: document, prune: prune)
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
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - templates

    private func handleTemplates() -> String {
        let templates = ConfigTemplateStore.list()
        return ToolEnvelope.success(
            tool: name,
            result: [
                "templates": templates,
                "directory": OsaurusPaths.configTemplates().path,
            ]
        )
    }

    // MARK: - Document loading

    private enum DocumentLoad {
        case success(OsaurusConfigDocument)
        case failure(String)
    }

    private func loadDocument(_ args: [String: Any]) -> DocumentLoad {
        let inlineYAML = (args["yaml"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let templateName = (args["template"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let yaml: String
        if let inlineYAML, !inlineYAML.isEmpty {
            if let templateName, !templateName.isEmpty {
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "Pass `yaml` OR `template`, not both.",
                        tool: name))
            }
            yaml = inlineYAML
        } else if let templateName, !templateName.isEmpty {
            switch ConfigTemplateStore.load(name: templateName) {
            case .success(let contents): yaml = contents
            case .failure(let message):
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs, message: message, field: "template", tool: name))
            }
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
            return .success(try ConfigYAML.decode(yaml))
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
