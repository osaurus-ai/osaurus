//
//  ChatImportReader.swift
//  osaurus
//
//  The model half of "the model reads, code checks". One isolated call —
//  no chat history, no other tools — reads the numbered documents and
//  reports what they ask to install through `report_import`. It names
//  things and points at documents; it never writes the bodies, and every
//  value it reports is checked by `ChatImportVerifier` before use.
//
//  It runs `AgentSubagentRunner` directly rather than through a
//  `SubagentSession`: the Configurator that calls `osaurus_import` is
//  itself a subagent run, and sessions refuse to nest.
//

import Foundation

enum ChatImportReader {
    static let toolName = "report_import"
    /// Characters of document text the reader sees in total. Sized for
    /// small local models; long pages keep their opening, where install
    /// instructions almost always live.
    static let inputBudgetChars = 24_000
    static let maxIterations = 3
    static let wallClockSeconds: TimeInterval = 240

    struct Outcome: Sendable {
        var manifest: ChatImportManifest?
        var failure: String?
        var modelName: String?
        var tokensPerSecond: Double?
        var completionTokens = 0
    }

    /// Test and eval seam for the model stream.
    @TaskLocal static var streamProviderOverride: AgentSubagentRunner.StreamProvider?

    static func read(documents: [ChatImportDocument], modelName: String?) async -> Outcome {
        guard !documents.isEmpty else { return Outcome(failure: "nothing to read") }
        guard let model = await resolveModel(modelName) else {
            return Outcome(failure: "no model is available to read the page")
        }
        let box = ManifestBox()
        let reportTool = ChatImportReportTool()
        let toolset = AgentSubagentToolset(specs: [reportTool.asOpenAITool()]) { invocation in
            guard invocation.toolName == toolName else {
                return ToolEnvelope.failure(
                    kind: .rejected, message: "Only `report_import` is available here.", tool: invocation.toolName,
                    retryable: false)
            }
            switch ChatImportReportTool.parse(invocation.jsonArguments) {
            case .success(let manifest):
                box.set(manifest)
                return ToolEnvelope.success(tool: toolName, text: "Recorded.")
            case .failure(let message):
                return ToolEnvelope.failure(kind: .invalidArgs, message: message, tool: toolName, retryable: true)
            }
        }
        let seed = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userContent(documents)),
        ]
        do {
            let result = try await AgentSubagentRunner.run(
                modelName: model,
                seedMessages: seed,
                maxTokens: nil,
                maxIterations: maxIterations,
                deadline: Date().addingTimeInterval(wallClockSeconds),
                sessionId: "import-reader-\(UUID().uuidString)",
                isAgentRequest: false,
                toolset: toolset,
                endsRun: { invocation, result in
                    invocation.toolName == toolName && ToolEnvelope.isSuccess(result)
                },
                streamProvider: streamProviderOverride
            )
            var outcome = Outcome(
                manifest: box.value, modelName: model, tokensPerSecond: result.usage.tokensPerSecond,
                completionTokens: result.usage.completionTokens)
            if outcome.manifest == nil {
                outcome.failure = "the reader finished without reporting (\(result.exit))"
            }
            return outcome
        } catch {
            return Outcome(failure: error.localizedDescription, modelName: model)
        }
    }

    @MainActor
    private static func fallbackModel() -> String? {
        AgentManager.shared.effectiveModel(for: Agent.configuratorId)
            ?? AgentManager.shared.effectiveModel(for: Agent.defaultId)
    }

    private static func resolvedModel(_ requested: String?) -> String? {
        if let requested, !requested.isEmpty { return requested }
        if let current = ChatExecutionContext.currentModelName, !current.isEmpty { return current }
        return nil
    }

    static func resolveModel(_ requested: String?) async -> String? {
        if let model = resolvedModel(requested) { return model }
        return await MainActor.run { fallbackModel() }
    }

    static let systemPrompt = """
        You read setup instructions for Osaurus, a Mac app for AI agents. Call `report_import` \
        exactly once with what the documents ask the user to install. Do not answer in text.

        - skills: instructions meant for an AI assistant. Give a short name, a one-line \
        description, and the document id in `doc` (for example "d1"). If only part of a \
        document is the skill, add the heading in `section`. Never copy the instructions.
        - agents: a persona or role with its own system prompt, reported the same way. \
        `capabilities` and `denies` use only the listed values.
        - mcp_servers: Model Context Protocol servers. Copy `url`, `command`, and every \
        `args` item exactly as written. List environment variable and header NAMES only; \
        never include a key, token, or other secret value.
        - commands: slash commands with a prompt template, reported like skills.
        - manual_steps: things only the user can do (create an account, install an app). \
        Short sentences.

        If nothing can be installed, call `report_import` with empty lists and a summary.
        """

    static func userContent(_ documents: [ChatImportDocument]) -> String {
        let perDocument = max(2_000, inputBudgetChars / max(documents.count, 1))
        var parts: [String] = []
        var used = 0
        for document in documents {
            guard used < inputBudgetChars else { break }
            let room = min(perDocument, inputBudgetChars - used)
            var text = String(document.text.prefix(room))
            if document.text.count > room { text += "\n[… rest of \(document.id) omitted]" }
            used += text.count
            parts.append("[\(document.id)] \(document.label)\n\(text)")
        }
        return "Documents:\n\n" + parts.joined(separator: "\n\n---\n\n")
    }

    private final class ManifestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ChatImportManifest?
        var value: ChatImportManifest? { lock.withLock { stored } }
        func set(_ manifest: ChatImportManifest) { lock.withLock { stored = manifest } }
    }
}

// MARK: - report_import

/// The reader's only tool. Never registered: it exists for one isolated
/// call, so no chat or agent can reach it.
struct ChatImportReportTool: OsaurusTool {
    let name = ChatImportReader.toolName
    let description =
        "Report what the documents ask to install. Names and document references only; never copy bodies or secrets."

    static let capabilityKeys = ChatImportCapabilities.keys.sorted()

    var parameters: JSONValue? {
        let docRef: JSONValue = .object([
            "type": .string("string"), "description": .string("Document id, for example d1"),
        ])
        let section: JSONValue = .object([
            "type": .string("string"), "description": .string("Optional heading inside the document"),
        ])
        let text: JSONValue = .object(["type": .string("string")])
        let strings: JSONValue = .object(["type": .string("array"), "items": text])
        func list(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"), "properties": .object(properties),
                    "required": .array(required.map(JSONValue.string)),
                ]),
            ])
        }
        return .object([
            "type": .string("object"),
            "properties": .object([
                "summary": .object(["type": .string("string"), "description": .string("One sentence: what this is")]),
                "skills": list(["name": text, "description": text, "doc": docRef, "section": section], required: ["name", "doc"]),
                "agents": list(
                    [
                        "name": text, "description": text, "doc": docRef, "section": section, "model": text,
                        "capabilities": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("string"), "enum": .array(Self.capabilityKeys.map(JSONValue.string)),
                            ]),
                        ]),
                        "denies": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string"), "enum": .array([.string("shell"), .string("network")])]),
                        ]),
                    ], required: ["name", "doc"]),
                "mcp_servers": list(
                    [
                        "name": text, "url": text, "command": text, "args": strings,
                        "env": .object([
                            "type": .string("array"), "items": text,
                            "description": .string("Environment variable names only"),
                        ]),
                        "headers": .object([
                            "type": .string("array"), "items": text, "description": .string("Header names only"),
                        ]),
                        "auth": .object(["type": .string("string"), "enum": .array([.string("none"), .string("bearer"), .string("oauth")])]),
                    ], required: ["name"]),
                "commands": list(["name": text, "description": text, "doc": docRef, "section": section], required: ["name", "doc"]),
                "manual_steps": strings,
            ]),
            "required": .array([.string("summary")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        switch Self.parse(argumentsJSON) {
        case .success: return ToolEnvelope.success(tool: name, text: "Recorded.")
        case .failure(let message): return ToolEnvelope.failure(kind: .invalidArgs, message: message, tool: name)
        }
    }

    enum Parsed {
        case success(ChatImportManifest)
        case failure(String)
    }

    /// Lenient decode: local models send numbers as strings, single values
    /// for arrays, and omit optional keys. Shape errors return a message
    /// the model can act on.
    static func parse(_ json: String) -> Parsed {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure("Arguments must be one JSON object.") }
        var manifest = ChatImportManifest()
        manifest.summary = (root["summary"] as? String) ?? ""
        func objects(_ key: String) -> [[String: Any]] {
            if let list = root[key] as? [[String: Any]] { return list }
            if let one = root[key] as? [String: Any] { return [one] }
            if let raw = root[key] as? String, let data = raw.data(using: .utf8),
                let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            {
                return list
            }
            return []
        }
        func string(_ object: [String: Any], _ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func strings(_ object: [String: Any], _ key: String) -> [String] {
            (ArgumentCoercion.stringArray(object[key]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        for skill in objects("skills") {
            guard let name = string(skill, "name"), let doc = string(skill, "doc") else { continue }
            manifest.skills.append(
                .init(name: name, description: string(skill, "description") ?? "", doc: doc, section: string(skill, "section")))
        }
        for agent in objects("agents") {
            guard let name = string(agent, "name"), let doc = string(agent, "doc") else { continue }
            manifest.agents.append(
                .init(
                    name: name, description: string(agent, "description") ?? "", doc: doc,
                    section: string(agent, "section"), model: string(agent, "model"),
                    capabilities: strings(agent, "capabilities"), denies: strings(agent, "denies")))
        }
        for server in objects("mcp_servers") {
            guard let name = string(server, "name") else { continue }
            manifest.mcpServers.append(
                .init(
                    name: name, url: string(server, "url"), command: string(server, "command"),
                    args: ArgumentCoercion.stringArray(server["args"]) ?? [], env: strings(server, "env"),
                    headers: strings(server, "headers"), auth: string(server, "auth")))
        }
        for command in objects("commands") {
            guard let name = string(command, "name"), let doc = string(command, "doc") else { continue }
            manifest.commands.append(
                .init(
                    name: name, description: string(command, "description") ?? "", doc: doc,
                    section: string(command, "section")))
        }
        manifest.manualSteps = ArgumentCoercion.stringArray(root["manual_steps"]) ?? []
        return .success(manifest)
    }
}

/// The fixed capability keys an imported agent may turn on, and how each
/// maps onto the declarative agent entry.
enum ChatImportCapabilities {
    static let keys: Set<String> = [
        "web_search", "memory", "search_memory", "knowledge", "image", "applescript", "speak", "render_chart",
        "calculator", "browser_use", "computer_use", "task_checklist", "clarify", "artifacts", "self_scheduling",
    ]

    static func apply(_ keys: [String], to entry: inout AgentCapabilitiesEntry) {
        for key in keys {
            switch key {
            case "web_search": entry.webSearchEnabled = true
            case "memory": entry.memoryEnabled = true
            case "search_memory": entry.searchMemoryEnabled = true
            case "knowledge": entry.knowledgeEnabled = true
            case "image": entry.imageEnabled = true
            case "applescript": entry.applescriptEnabled = true
            case "speak": entry.speakEnabled = true
            case "render_chart": entry.renderChartEnabled = true
            case "calculator": entry.calculatorEnabled = true
            case "browser_use": entry.browserUseEnabled = true
            case "computer_use": entry.computerUseEnabled = true
            case "task_checklist": entry.taskChecklistEnabled = true
            case "clarify": entry.clarifyEnabled = true
            case "artifacts": entry.artifactsEnabled = true
            case "self_scheduling": entry.selfSchedulingEnabled = true
            default: break
            }
        }
    }
}
