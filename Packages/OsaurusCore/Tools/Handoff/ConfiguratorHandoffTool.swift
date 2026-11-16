//
//  ConfiguratorHandoffTool.swift
//  osaurus
//
//  `configurator_handoff`: the Orchestrator's only way to explain or change
//  Osaurus itself. Runs the hidden Configurator inline in the same turn on
//  `HiddenAgentHandoffRunner`, seeded with the user's exact words, a
//  one-line brief, the session state, and the settings catalog rows and
//  guide sections that match the message. Returns a `HandoffResult`.
//

import Foundation

final class ConfiguratorHandoffTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "configurator_handoff"
    let name = ConfiguratorHandoffTool.toolName
    let description =
        "Hand a request about Osaurus itself to Osaurus's settings helper: how a feature works, where a "
        + "setting is, what is configured, or a change to models, agents, providers, tools, automations, "
        + "or app settings, including installing a skill, MCP server, or agent from a link, snippet, or "
        + "command the user shared. It answers or makes the change (the user approves changes on a card) and "
        + "returns the result to present."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "user_message": .object([
                "type": .string("string"),
                "description": .string("The user's message, exactly as they wrote it."),
            ]),
            "brief": .object([
                "type": .string("string"),
                "description": .string("One line: what to explain or change."),
            ]),
        ]),
        "required": .array([.string("user_message"), .string("brief")]),
    ])

    var bypassRegistryTimeout: Bool { true }

    /// Steps and time for one handoff. An approval card can hold the run
    /// while the user reads it.
    static let maxSteps = 8
    static let wallClockSeconds: TimeInterval = 600

    /// Test seams.
    private let evalModel: String?
    private let dispatchOverride: (@Sendable (ServiceToolInvocation) async -> String)?
    private let streamProvider: AgentSubagentRunner.ResponsesStreamProvider?

    init(
        evalModel: String? = nil,
        dispatchOverride: (@Sendable (ServiceToolInvocation) async -> String)? = nil,
        streamProvider: AgentSubagentRunner.ResponsesStreamProvider? = nil
    ) {
        self.evalModel = evalModel
        self.dispatchOverride = dispatchOverride
        self.streamProvider = streamProvider
    }

    /// The only agents that hand off to Osaurus settings: the Orchestrator,
    /// and the Onboarding agent during the first-run walkthrough.
    static let allowedCallerIds: Set<UUID> = [Agent.defaultId, Agent.onboardingId]

    func execute(argumentsJSON: String) async throws -> String {
        guard let caller = ChatExecutionContext.currentAgentId, Self.allowedCallerIds.contains(caller) else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "Only the Orchestrator hands off to Osaurus settings.", tool: name,
                retryable: false)
        }
        let kind = await makeKind(argumentsJSON: argumentsJSON)
        guard let kind else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`user_message` must carry the user's message.", field: "user_message",
                tool: name)
        }
        return await HiddenAgentHandoffRunner.run(kind, tool: name)
    }

    /// The kind for one call: the verbatim handoff and its seed. Internal for
    /// tests (verbatim overwrite, fresh context).
    func makeKind(argumentsJSON: String) async -> HiddenAgentHandoffKind? {
        let caller = CallerContext.current()
        let seed: String? = await MainActor.run {
            let state = SessionStateRegistry.shared.state(for: caller.sessionId)
            guard
                let handoff = Handoff.fromToolArguments(
                    argumentsJSON,
                    turnUserText: ChatExecutionContext.currentUserRequest,
                    state: state,
                    caller: caller)
            else { return nil }
            return Self.seedContent(for: handoff)
        }
        guard let seed else { return nil }
        return HiddenAgentHandoffKind(
            target: Self.target,
            seedUserContent: seed,
            evalModel: evalModel,
            dispatchOverride: dispatchOverride,
            streamProvider: streamProvider
        )
    }

    static let target = HiddenAgentTarget(
        agentId: Agent.configuratorId,
        capability: SubagentCapabilityRegistry.configuratorHandoff,
        feedTitle: "Osaurus settings",
        maxSteps: maxSteps,
        wallClockSeconds: wallClockSeconds,
        systemPrompt: {
            let model = AgentManager.shared.effectiveModel(for: Agent.configuratorId)
            let compact = model.map { ContextSizeResolver.prefersCompactPrompt(forModelId: $0) } ?? false
            return ConfiguratorSystemPromptBuilder.render(
                compact: compact,
                instructions: ConfiguratorConfigurationStore.load().systemPrompt)
        },
        toolNames: { ToolRegistry.configuratorAllowedToolNames.sorted() },
        configuredModel: { ConfiguratorConfigurationStore.load().resolvedModel },
        temperature: { ConfiguratorConfigurationStore.load().temperature },
        classify: { calls, digest, exposed in classify(calls, digest: digest, exposedToolNames: exposed) },
        endsRun: { importFinished($0) }
    )

    // MARK: - Seed

    /// The handoff's one user message: the request, the session state, and
    /// the catalog rows and guide sections retrieved for the message.
    @MainActor
    static func seedContent(for handoff: Handoff) -> String {
        var parts: [String] = []
        var request = "[Request]\nuser_message: \(handoff.userMessage)"
        if !handoff.brief.isEmpty { request += "\nbrief: \(handoff.brief)" }
        parts.append(request)
        if !handoff.state.isEmpty { parts.append(handoff.state.rendered()) }

        let query = handoff.userMessage + " " + handoff.brief
        let rows = SettingsSearchIndex.relevant(toMessage: query)
        if !rows.isEmpty {
            var lines = ["[Settings catalog: rows matching the request]"]
            for row in rows {
                var line = "- \(row.breadcrumbPath) (id: \(row.id); "
                line += row.declarativeSection.map { "osaurus_config section `\($0)`" } ?? "Settings only"
                line += ")"
                if let note = row.disambiguation { line += ". \(note)" }
                lines.append(line)
            }
            parts.append(lines.joined(separator: "\n"))
        }

        let sections = OsaurusGuide.relevantSections(toMessage: query)
        if !sections.isEmpty {
            var lines = ["[Guide excerpts]"]
            for section in sections {
                lines.append("## \(section.topicId) › \(section.heading)\n\(section.body)")
            }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Outcome

    /// What the run did, from its tool calls: the last `osaurus_config`
    /// apply decides applied / needs setup / declined; anything else is an
    /// answer. The Configurator's reply is the text either way.
    static func classify(
        _ calls: [HandoffToolCall],
        digest: String,
        exposedToolNames: Set<String> = []
    ) -> HandoffResult {
        let writeTools = exposedToolNames.subtracting(["osaurus_config", "osaurus_inspect", "osaurus_help"])
        for call in calls.reversed() {
            if call.name == "osaurus_config", action(of: call) == "apply" {
                return classifyApply(call.result, digest: digest)
            }
            if call.name == OsaurusImportTool.toolName {
                return classifyImport(call.result, digest: digest)
            }
            if writeTools.contains(call.name) {
                if ToolEnvelope.isSuccess(call.result) { return .applied(digest) }
                if failureKind(call.result) == ToolEnvelope.Kind.userDenied.rawValue { return .declined(digest) }
            }
        }
        return .answer(digest)
    }

    /// An import that ran to an answer: something installed, the user said
    /// no, or the apply failed. The tool's summary is the reply, so the run
    /// stops there instead of spending more local-model steps on a recap.
    static func importFinished(_ call: HandoffToolCall) -> Bool {
        guard call.name == OsaurusImportTool.toolName else { return false }
        if ToolEnvelope.isSuccess(call.result) { return true }
        let kind = failureKind(call.result)
        return kind == ToolEnvelope.Kind.userDenied.rawValue || kind == ToolEnvelope.Kind.timeout.rawValue
            || kind == ToolEnvelope.Kind.executionError.rawValue
    }

    private static func importText(_ result: String) -> String {
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any] {
            return payload["summary"] as? String ?? ""
        }
        guard let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return object["message"] as? String ?? ""
    }

    private static func classifyImport(_ result: String, digest: String) -> HandoffResult {
        let digest = digest.isEmpty ? importText(result) : digest
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any] {
            switch payload["status"] as? String {
            case "installed": return .applied(digest)
            case "needs_setup": return .needsSetup(digest)
            default: return .answer(digest)
            }
        }
        switch failureKind(result) {
        case ToolEnvelope.Kind.userDenied.rawValue, ToolEnvelope.Kind.timeout.rawValue,
            ToolEnvelope.Kind.permissionDenied.rawValue:
            return .declined(digest)
        default:
            return .answer(digest)
        }
    }

    private static func classifyApply(_ result: String, digest: String) -> HandoffResult {
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any] {
            let status = payload["status"] as? String ?? ""
            let rows = payload["results"] as? [[String: Any]] ?? []
            if rows.contains(where: { $0["status"] as? String == "needs_user_action" }) {
                return .needsSetup(digest)
            }
            if status == "applied" || status == "applied_downloads_running" { return .applied(digest) }
            return .answer(digest)
        }
        switch failureKind(result) {
        case ToolEnvelope.Kind.userDenied.rawValue, ToolEnvelope.Kind.timeout.rawValue,
            ToolEnvelope.Kind.permissionDenied.rawValue:
            return .declined(digest)
        default:
            return .answer(digest)
        }
    }

    private static func action(of call: HandoffToolCall) -> String? {
        JSONValue.parse(call.argumentsJSON)?.objectValue?["action"]?.stringValue
    }

    private static func failureKind(_ envelope: String) -> String? {
        guard ToolEnvelope.isError(envelope), let data = envelope.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["kind"] as? String
    }
}
