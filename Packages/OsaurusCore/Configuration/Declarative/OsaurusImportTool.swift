//
//  OsaurusImportTool.swift
//  osaurus
//
//  `osaurus_import`: the Configurator's one call for "set this up" with a
//  link, snippet, command, or file. Code fetches and checks; an isolated
//  reader names what the text sets up; the user picks rows on the import
//  card; the apply is all or nothing. The result is a short summary built
//  from names and fixed wording, never page text.
//

import Foundation

final class OsaurusImportTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    static let toolName = "osaurus_import"
    let name = OsaurusImportTool.toolName
    // The first sentence must stay ≤180 chars (compact schema budget).
    let description =
        "Install what pasted setup text or a linked page sets up: skills, agents, MCP servers, commands, Claude plugins. "
        + "Pass the user's link or text exactly as they wrote it, once. Not for a registry plugin, model, or server "
        + "address the user names directly; apply those with `osaurus_config`. The user reviews every item on a card "
        + "before anything installs; repeat the result's `summary` in one or two sentences."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "description": .string("The user's link, snippet, command, or file text, exactly as written."),
            ])
        ]),
        "required": .array([.string("source")]),
        "additionalProperties": .bool(false),
    ])

    var bypassRegistryTimeout: Bool { true }
    var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }
    /// The import card is the approval; the generic panel would double it.
    var handlesOwnApproval: Bool { true }

    init() {}

    func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) { return gate }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let sourceReq = requireString(args, "source", expected: "the user's link or pasted text", tool: name)
        guard case .value(let source) = sourceReq else { return sourceReq.failureEnvelope ?? "" }

        let targetAgentId = await MainActor.run { ChatImportPipeline.mainChatTargetAgentId() }
        let prepared = await ChatImportPipeline.prepare(
            source: source, userText: ChatExecutionContext.currentUserRequest, surface: .mainChat,
            targetAgentId: targetAgentId)
        defer { prepared.bundle.cleanUp() }
        if let reader = prepared.reader {
            print(
                "[Osaurus][Import] reader model=\(reader.modelName ?? "none") "
                    + "tok/s=\(reader.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "n/a") "
                    + "tokens=\(reader.completionTokens) failure=\(reader.failure ?? "none")")
        }

        let templates = prepared.bundle.storeTemplateLinks
        if !templates.isEmpty {
            await MainActor.run { for link in templates { TemplateImportRouter.handleDeepLink(link) } }
        }

        let review = prepared.review
        guard review.items.contains(where: \.isActionable) else {
            let hadSource = !prepared.bundle.sources.isEmpty || !prepared.bundle.documents.isEmpty
            return nothingToInstall(review, openedTemplates: templates.count, hadSource: hadSource)
        }
        if let installed = Self.alreadyInstalledResult(review) { return installed }

        let approvalId = UUID()
        let outcome: ConfigApprovalOutcome
        var choices = review.defaultChoices
        if ChatExecutionContext.autoApproveToolPrompts {
            outcome = .approved
        } else if ChatExecutionContext.denyUnapprovedToolPrompts
            || ChatExecutionContext.isUnattendedDispatch
            || (ChatExecutionContext.isExternalSurface && !ChatExecutionContext.hasRemoteReviewer)
        {
            return ToolEnvelope.failure(
                kind: .permissionDenied,
                message: "Installing needs the user's approval in the Osaurus app, and this run has no way to show it. "
                    + "Nothing was installed.",
                tool: name, retryable: false)
        } else if ChatExecutionContext.hasRemoteReviewer {
            (outcome, choices) = await ConfigApprovalQueue.shared.requestImportApproval(
                review: review, fromPairedPhone: true, timeout: .seconds(300), id: approvalId)
        } else {
            (outcome, choices) = await ConfigApprovalService.requestImportApproval(review: review, id: approvalId)
        }
        switch outcome {
        case .approved: break
        case .denied, .cancelled:
            return ToolEnvelope.failure(
                kind: .userDenied, message: "The user didn't install it. Nothing was installed.", tool: name,
                retryable: false)
        case .timedOut:
            return ToolEnvelope.failure(
                kind: .timeout, message: "The review timed out. Nothing was installed.", tool: name, retryable: false)
        }

        let context = ChatImportApplier.Context(
            caller: OsaurusConfigTool.historyCaller(template: nil), approvalId: approvalId,
            requestText: ChatExecutionContext.currentUserRequest)
        let applied = await ChatImportApplier.apply(items: review.items, choices: choices, context: context)
        let results = applied.results
        guard results.contains(where: { $0.status != .skipped }) else {
            return ToolEnvelope.success(
                tool: name,
                result: ["status": "nothing_selected", "summary": L("Nothing was selected, so nothing was installed.")])
        }

        var connections: [ChatImportConnectionTest.Result] = []
        if applied.succeeded {
            let servers = results.filter { $0.kind == .mcpServer && ($0.status == .installed || $0.status == .updated) }
                .map(\.name)
            if !servers.isEmpty {
                connections = await ChatImportConnectionTest.run(serverNames: servers, agentId: targetAgentId)
            }
        }
        let summary = ChatImportSummary.text(
            results: results, connections: connections, refusals: review.refusals, openedTemplates: templates.count)
        var payload: [String: Any] = [
            "status": Self.status(results), "summary": summary,
            "items": results.filter { $0.status != .skipped }.map(\.payload),
        ]
        let steps = review.items.filter { $0.kind == .manualStep }.map(\.name)
        if !steps.isEmpty { payload["manual_steps"] = steps }
        guard applied.succeeded else {
            return ToolEnvelope.failure(kind: .executionError, message: summary, tool: name, retryable: false)
        }
        return ToolEnvelope.success(tool: name, result: payload)
    }

    /// Every row is already installed from this same content, so a card
    /// would offer nothing to pick. Plugins still go to the card: installing
    /// one again updates it.
    static func alreadyInstalledResult(_ review: ChatImportReview) -> String? {
        let actionable = review.items.filter(\.isActionable)
        guard !actionable.isEmpty, review.refusals.isEmpty,
            actionable.allSatisfy({ $0.state == .alreadyInstalled && $0.kind != .plugin })
        else { return nil }
        let names = actionable.map(\.name).joined(separator: ", ")
        var payload: [String: Any] = [
            "status": "already_installed",
            "summary": L("Already installed from this source, unchanged: \(names). Nothing new to install."),
        ]
        let steps = review.items.filter { $0.kind == .manualStep }.map(\.name)
        if !steps.isEmpty { payload["manual_steps"] = steps }
        return ToolEnvelope.success(tool: toolName, result: payload)
    }

    static func status(_ results: [ChatImportItemResult]) -> String {
        if results.contains(where: { $0.status == .rolledBack || $0.status == .failed }) { return "failed" }
        if results.contains(where: { $0.status == .needsSetup }) { return "needs_setup" }
        return "installed"
    }

    private func nothingToInstall(_ review: ChatImportReview, openedTemplates: Int, hadSource: Bool) -> String {
        var parts: [String] = []
        if openedTemplates > 0 { parts.append(L("Opened the template review for the store link.")) }
        parts += review.refusals.map(\.message)
        let steps = review.items.filter { $0.kind == .manualStep }.map(\.name)
        if !steps.isEmpty { parts.append(L("Nothing installs here; the steps are for the user: ") + steps.joined(separator: " ")) }
        if parts.isEmpty, !hadSource {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: L(
                    "Nothing was imported: `source` has no link or pasted setup text. A plugin, model, or server the user names directly is a change; call `osaurus_config` to make it."
                ),
                field: "source", expected: "a link or the setup text the user pasted", tool: name, retryable: false)
        }
        if parts.isEmpty { parts.append(L("Osaurus didn't find anything it can install there.")) }
        if openedTemplates > 0 && review.refusals.isEmpty {
            return ToolEnvelope.success(tool: name, result: ["status": "template_review_opened", "summary": parts.joined(separator: " ")])
        }
        return ToolEnvelope.failure(kind: .notFound, message: parts.joined(separator: " "), tool: name, retryable: false)
    }
}
