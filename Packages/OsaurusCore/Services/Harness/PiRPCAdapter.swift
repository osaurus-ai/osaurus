//
//  PiRPCAdapter.swift
//  osaurus
//
//  Pi's `--mode rpc` protocol, for Pi itself and any Pi-based wrapper:
//  `prompt` commands in, agent events out, `agent_settled` ends a turn,
//  `abort` stops one, and closing stdin shuts the process down.
//

import Foundation

struct PiRPCAdapter: HarnessAdapter {
    let runtime: HarnessRuntime

    /// Deferred to the agent's own tool policy at call time.
    func tokenToolScope(context: HarnessLaunchContext) -> Set<String>? { nil }

    /// Pi has no per-agent config-write switch, so the token is read-only for
    /// Osaurus's configuration.
    func tokenAllowsConfigWrites(context: HarnessLaunchContext) -> Bool { false }

    func launchPlan(context: HarnessLaunchContext, token: String?) throws -> HarnessLaunchPlan {
        var temporaryFiles: [URL] = []
        var systemPromptFile: URL?
        if runtime.wantsSystemPromptFile {
            let url = try HarnessScratch.writePrivateFile(
                named: "system-prompt-\(UUID().uuidString).md",
                contents: context.systemPrompt ?? "",
                in: HarnessScratch.privateDirectory(chatId: context.chatId)
            )
            temporaryFiles.append(url)
            systemPromptFile = url
        }

        var environment = runtime.environment
        for (key, value) in HarnessEnvironment.contract(context: context, token: token) {
            environment[key] = value
        }

        return HarnessLaunchPlan(
            spec: HarnessProcess.LaunchSpec(
                executable: runtime.executable,
                arguments: runtime.resolvedArguments(
                    chatId: context.chatId,
                    agentId: context.agentId,
                    workingDirectory: context.workingDirectory,
                    systemPromptFile: systemPromptFile
                ),
                environment: environment,
                removingEnvironment: HarnessEnvironment.alwaysRemoved,
                workingDirectory: context.workingDirectory,
                runtimeName: runtime.displayName
            ),
            temporaryFiles: temporaryFiles
        )
    }

    func makeCodec() -> HarnessCodec {
        PiRPCCodec(runtimeName: runtime.displayName)
    }
}

final class PiRPCCodec: HarnessCodec {
    private let runtimeName: String

    private var turnActive = false
    private var promptRequestId: String?
    private var probeRequestId: String?
    private var sawAgentStart = false
    private var lastError: String?
    private var outputTokens = 0
    private var generationSeconds: Double = 0
    private var messageStartedAt: Date?
    private var lastStopReason: String?
    private var dialogs: [String] = []

    init(runtimeName: String) {
        self.runtimeName = runtimeName
    }

    var pendingDialogIds: [String] { dialogs }

    func beginTurn(_ message: HarnessUserMessage) throws -> [Data] {
        let id = "osaurus-\(UUID().uuidString)"
        turnActive = true
        promptRequestId = id
        probeRequestId = nil
        sawAgentStart = false
        lastError = nil
        outputTokens = 0
        generationSeconds = 0
        messageStartedAt = nil
        lastStopReason = nil

        var command: [String: Any] = ["id": id, "type": "prompt", "message": message.text]
        if !message.images.isEmpty {
            command["images"] = message.images.map {
                ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mimeType]
            }
        }
        return [try HarnessJSON.encode(command)]
    }

    func decode(line: Data) -> (events: [HarnessEvent], replies: [Data]) {
        guard let root = HarnessJSON.object(line), let type = root["type"] as? String else { return ([], []) }
        switch type {
        case "response":
            return decodeResponse(root)
        case "agent_start":
            sawAgentStart = true
            return ([], [])
        case "message_start":
            if let message = root["message"] as? [String: Any], (message["role"] as? String) == "assistant" {
                messageStartedAt = Date()
            }
            return ([], [])
        case "message_update":
            return (decodeMessageUpdate(root), [])
        case "message_end":
            decodeMessageEnd(root)
            return ([], [])
        case "tool_execution_start":
            return ([.toolStarted(callId: root["toolCallId"] as? String, name: (root["toolName"] as? String) ?? "")], [])
        case "tool_execution_end":
            return (
                [
                    .toolFinished(
                        callId: root["toolCallId"] as? String,
                        name: (root["toolName"] as? String) ?? "",
                        isError: (root["isError"] as? Bool) ?? false
                    )
                ], []
            )
        case "auto_retry_start":
            let attempt = (root["attempt"] as? Int) ?? 1
            let maxAttempts = (root["maxAttempts"] as? Int) ?? attempt
            return ([.notice(String(format: L("Retrying (attempt %d of %d)…"), attempt, maxAttempts), isError: false)], [])
        case "auto_retry_end":
            if (root["success"] as? Bool) == false {
                lastError = (root["finalError"] as? String) ?? lastError
            }
            return ([], [])
        case "compaction_start":
            return ([.notice(L("Compacting the conversation…"), isError: false)], [])
        case "compaction_end":
            if let message = root["errorMessage"] as? String, !message.isEmpty {
                return ([.notice(String(format: L("Compaction failed: %@"), message), isError: true)], [])
            }
            return ([], [])
        case "extension_error":
            let message = (root["error"] as? String) ?? L("An extension failed.")
            return ([.notice(message, isError: true)], [])
        case "extension_ui_request":
            return (decodeExtensionUI(root), [])
        case "agent_settled":
            return (settle(), [])
        default:
            return ([], [])
        }
    }

    func interruptRecords() -> [Data] {
        (try? HarnessJSON.encode(["type": "abort"])).map { [$0] } ?? []
    }

    func dialogResponse(id: String, response: HarnessDialogResponse) -> Data? {
        guard let index = dialogs.firstIndex(of: id) else { return nil }
        dialogs.remove(at: index)
        var record: [String: Any] = ["type": "extension_ui_response", "id": id]
        switch response {
        case .value(let value): record["value"] = value
        case .confirmed(let confirmed): record["confirmed"] = confirmed
        case .cancelled: record["cancelled"] = true
        }
        return try? HarnessJSON.encode(record)
    }

    // MARK: - Decoding

    private func decodeResponse(_ root: [String: Any]) -> (events: [HarnessEvent], replies: [Data]) {
        let id = root["id"] as? String
        let command = root["command"] as? String
        let success = (root["success"] as? Bool) ?? false

        if command == "prompt", turnActive, id == promptRequestId {
            guard success else {
                turnActive = false
                let detail = (root["error"] as? String) ?? L("The prompt was rejected.")
                return ([.turnFailed(Self.classifyRejection(runtime: runtimeName, detail: detail))], [])
            }
            if sawAgentStart { return ([], []) }
            // A prompt an extension command consumed never starts a run, so
            // no `agent_settled` will follow. Pi marks a real run as streaming
            // before acknowledging the prompt, so one state query tells the
            // two apart.
            let probeId = "osaurus-state-\(UUID().uuidString)"
            probeRequestId = probeId
            let probe = (try? HarnessJSON.encode(["id": probeId, "type": "get_state"])).map { [$0] } ?? []
            return ([], probe)
        }

        if command == "get_state", turnActive, id == probeRequestId {
            probeRequestId = nil
            let data = root["data"] as? [String: Any]
            let streaming = (data?["isStreaming"] as? Bool) ?? true
            if !streaming, !sawAgentStart {
                turnActive = false
                return ([.turnCompleted], [])
            }
        }
        return ([], [])
    }

    private func decodeMessageUpdate(_ root: [String: Any]) -> [HarnessEvent] {
        guard turnActive, let event = root["assistantMessageEvent"] as? [String: Any] else { return [] }
        switch event["type"] as? String {
        case "text_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.text(delta)]
        case "thinking_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.reasoning(delta)]
        default:
            return []
        }
    }

    private func decodeMessageEnd(_ root: [String: Any]) {
        guard let message = root["message"] as? [String: Any], (message["role"] as? String) == "assistant" else {
            return
        }
        if let usage = message["usage"] as? [String: Any] {
            outputTokens += (usage["output"] as? Int) ?? 0
        }
        if let started = messageStartedAt {
            generationSeconds += Date().timeIntervalSince(started)
            messageStartedAt = nil
        }
        let stopReason = message["stopReason"] as? String
        lastStopReason = stopReason
        if stopReason == "error" {
            lastError = (message["errorMessage"] as? String) ?? lastError ?? L("The model returned an error.")
        } else {
            lastError = nil
        }
    }

    private func decodeExtensionUI(_ root: [String: Any]) -> [HarnessEvent] {
        guard let id = root["id"] as? String, let method = root["method"] as? String else { return [] }
        let title = (root["title"] as? String) ?? ""
        let kind: HarnessDialogRequest.Kind
        switch method {
        case "select":
            kind = .select(options: (root["options"] as? [String]) ?? [])
        case "confirm":
            kind = .confirm(message: root["message"] as? String)
        case "input":
            kind = .input(placeholder: root["placeholder"] as? String)
        case "editor":
            kind = .editor(prefill: root["prefill"] as? String)
        case "notify":
            guard let message = root["message"] as? String, !message.isEmpty else { return [] }
            return [.notice(message, isError: (root["notifyType"] as? String) == "error")]
        case "setStatus":
            guard let text = root["statusText"] as? String, !text.isEmpty else { return [] }
            return [.notice(text, isError: false)]
        default:
            // setWidget / setTitle / set_editor_text target a terminal UI.
            return []
        }
        dialogs.append(id)
        return [.dialog(HarnessDialogRequest(id: id, title: title, kind: kind))]
    }

    private func settle() -> [HarnessEvent] {
        guard turnActive else { return [] }
        turnActive = false
        promptRequestId = nil
        probeRequestId = nil
        if let lastError, lastStopReason != "aborted" {
            return [.turnFailed(HarnessError.classify(runtime: runtimeName, detail: lastError))]
        }
        let tps = generationSeconds > 0 ? Double(outputTokens) / generationSeconds : 0
        return [
            .stats(outputTokens: outputTokens, tokensPerSecond: tps, stopReason: lastStopReason),
            .turnCompleted,
        ]
    }

    /// Pi refuses a prompt before acceptance chiefly for a missing model or
    /// credentials; those should read as "sign in", not as a crash.
    private static func classifyRejection(runtime: String, detail: String) -> HarnessError {
        let lowered = detail.lowercased()
        if lowered.contains("no api key") || lowered.contains("/login") || lowered.contains("no model selected") {
            return .notAuthenticated(runtime: runtime, detail: detail)
        }
        let classified = HarnessError.classify(runtime: runtime, detail: detail)
        if case .turnFailed = classified { return .rejected(runtime: runtime, detail: detail) }
        return classified
    }
}
