//
//  ChatRunOutcome.swift
//  osaurus
//
//  How a chat run ended when it did not end on an answer: the cause,
//  whether another attempt can help, and what the person can do next.
//  Read from typed state only (failure-envelope fields, thrown error types,
//  the agent loop's exit), never from message text, and mapped through the
//  same classification workflows use (`WorkflowFailure.classify`).
//

import Foundation

struct ChatRunOutcome: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// Admission found no room for another local model run.
        case memoryRefused = "memory_refused"
        /// Memory Safety refused to load the model.
        case memoryLoadRefused = "memory_load_refused"
        /// The runtime ran out of memory mid-run.
        case memoryExhausted = "memory_exhausted"
        case modelBusy = "model_busy"
        /// Another loaded model was in the way of a swap or a restore.
        case modelResidency = "model_residency"
        case outputLimit = "output_limit"
        /// The model ended in reasoning without a visible reply.
        case reasoningOnly = "reasoning_only"
        case emptyResponse = "empty_response"
        case contextTooLong = "context_too_long"
        case stepLimit = "step_limit"
        /// The app ended while a local load or run was in flight.
        case interruptedByExit = "interrupted_by_exit"
    }

    enum Cause: String, Sendable {
        case memory
        case modelBusy = "model_busy"
        case outputLimit = "output_limit"
        case contextTooLong = "context_too_long"
        case incomplete
        case stopped
    }

    struct Fact: Equatable, Sendable {
        let label: String
        let value: String
    }

    let kind: Kind
    /// The tool whose failure ended the run, when one did.
    var tool: String?
    /// What the runtime knew when the run ended. Live only: a reloaded
    /// chat rebuilds the outcome from `kind` alone.
    var facts: [Fact] = []
    /// Resident models nothing is using, sampled when the outcome was
    /// recorded; Free Up Memory unloads them.
    var freeableModels: [String] = []
    /// Free Up Memory can release cached buffers even with no idle model.
    var hasReclaimableCache = false
    /// The person's Context Window Cap, not the model's window, was the
    /// limit a too-long conversation hit.
    var contextLimitedByCap = false
    /// The admission decision's raw pressure and limiting terms, for
    /// content-free telemetry.
    var memoryPressure: String?
    var limitedBy: [String] = []

    // MARK: - Verdict

    var cause: Cause {
        switch kind {
        case .memoryRefused, .memoryLoadRefused, .memoryExhausted: return .memory
        case .modelBusy, .modelResidency: return .modelBusy
        case .outputLimit, .reasoningOnly: return .outputLimit
        case .contextTooLong: return .contextTooLong
        case .emptyResponse, .stepLimit: return .incomplete
        case .interruptedByExit: return .stopped
        }
    }

    /// Whether running the same request again can succeed without the
    /// person changing the request itself.
    var retryable: Bool {
        kind != .contextTooLong
    }

    var fixIn: NodeRunFailure.FixIn {
        switch kind {
        case .memoryRefused, .memoryLoadRefused, .modelResidency, .outputLimit, .reasoningOnly, .stepLimit:
            return .settings
        case .memoryExhausted, .modelBusy, .emptyResponse, .interruptedByExit:
            return .retry
        case .contextTooLong:
            return .person
        }
    }

    /// One sentence for the notice, and the neutral line kept in the turn's
    /// model-visible content so a later turn knows this one did not finish.
    var title: String {
        switch kind {
        case .memoryRefused: return L("There wasn't enough free memory to run this.")
        case .memoryLoadRefused: return L("Memory Safety stopped the model from loading.")
        case .memoryExhausted: return L("The model ran out of memory.")
        case .modelBusy: return L("The model was busy with other work.")
        case .modelResidency: return L("Another loaded model was in the way.")
        case .outputLimit: return L("The reply reached its output limit before it finished.")
        case .reasoningOnly: return L("The model stopped inside its reasoning without finishing a reply.")
        case .emptyResponse: return L("The model returned an empty reply.")
        case .contextTooLong: return L("This conversation no longer fits in the model's context.")
        case .stepLimit: return L("The run reached its step limit.")
        case .interruptedByExit: return L("Osaurus quit unexpectedly while a local model was working.")
        }
    }

    var explanation: String {
        switch kind {
        case .memoryRefused:
            return L("Nothing was changed. Free up memory, then try again.")
        case .memoryLoadRefused:
            return L("The model needs more memory than the Memory Safety budget allows.")
        case .memoryExhausted:
            return L("Close other apps or unload models, then try again.")
        case .modelBusy:
            return L("Try again in a moment.")
        case .modelResidency:
            return L("Finish the other work, or let Osaurus swap local models for helpers.")
        case .outputLimit:
            return L("Continue to pick up where it stopped, or raise Max Tokens for longer replies.")
        case .reasoningOnly:
            return L("Try again, or turn off Thinking for this request.")
        case .emptyResponse:
            return L("Try again, or rephrase the request.")
        case .contextTooLong:
            return L("Start a new chat, or shorten the input.")
        case .stepLimit:
            return L("Send a message to continue from the last step.")
        case .interruptedByExit:
            return L("This usually means the Mac ran out of memory. A smaller model or a shorter context uses less.")
        }
    }

    /// Short label for a failed tool card, in place of "Failed: <tool>".
    var toolLabel: String {
        switch kind {
        case .memoryRefused, .memoryExhausted: return L("Not enough memory")
        case .memoryLoadRefused: return L("Memory Safety stopped the load")
        case .modelBusy: return L("Model busy")
        case .modelResidency: return L("Another model in the way")
        case .outputLimit, .reasoningOnly, .emptyResponse, .contextTooLong, .stepLimit, .interruptedByExit:
            return title
        }
    }

    var canFreeMemory: Bool {
        cause == .memory && kind != .memoryLoadRefused && (!freeableModels.isEmpty || hasReclaimableCache)
    }

    /// The setting the details disclosure links to, if one decides this.
    var settingId: String? {
        switch kind {
        case .memoryRefused: return Self.delegationMemoryCheckSettingId
        case .memoryLoadRefused: return Self.memorySafetySettingId
        case .modelResidency: return Self.swapModelsSettingId
        case .contextTooLong: return contextLimitedByCap ? Self.contextWindowCapSettingId : nil
        case .stepLimit: return Self.toolAttemptsSettingId
        default: return nil
        }
    }

    /// What the linked setting does, including its risk, for the details.
    var settingNote: String? {
        switch kind {
        case .memoryRefused:
            return L(
                "Check Memory Before Delegating skips this check when turned off, at the risk of running out of memory or crashing.")
        case .memoryLoadRefused:
            return L("Memory Safety sets how much memory a model may load into.")
        case .modelResidency:
            return L("Swap Local Models for Subagents lets a helper unload the chat model while it works.")
        case .contextTooLong where contextLimitedByCap:
            return L("Your Context Window Cap, not the model's own window, set this limit.")
        case .stepLimit:
            return L("Max Tool Attempts sets how many steps one run may take.")
        default:
            return nil
        }
    }

    var offersContinue: Bool {
        kind == .outputLimit || kind == .reasoningOnly
    }

    // MARK: - Persistence

    static let stopReasonPrefix = "outcome:"

    /// Stored in `ChatTurn.terminalStopReason`; the turn's other columns
    /// already persist, so the notice survives a reload without a new field.
    var stopReason: String { Self.stopReasonPrefix + kind.rawValue }

    init(kind: Kind, tool: String? = nil, facts: [Fact] = []) {
        self.kind = kind
        self.tool = tool
        self.facts = facts
    }

    init?(stopReason: String?) {
        guard let stopReason, stopReason.hasPrefix(Self.stopReasonPrefix),
            let kind = Kind(rawValue: String(stopReason.dropFirst(Self.stopReasonPrefix.count)))
        else { return nil }
        self.init(kind: kind)
    }

    /// The turn content with the trailing outcome sentence removed, for
    /// rendering above the notice that already says it.
    func contentRemovingTitle(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(title) else { return content }
        return String(trimmed.dropLast(title.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `content` with the outcome sentence appended after any partial reply.
    func contentAppendingTitle(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(title) { return content }
        return trimmed.isEmpty ? title : trimmed + "\n\n" + title
    }

    // MARK: - Settings ids

    static let delegationMemoryCheckSettingId = "settings.agents.delegation.ramSafety"
    static let memorySafetySettingId = "settings.server.memorySafetyMode"
    static let swapModelsSettingId = "settings.agents.delegation.swapModels"
    static let contextWindowCapSettingId = "settings.chat.contextLength"
    static let toolAttemptsSettingId = "settings.chat.toolAttempts"
}

// MARK: - Classification

extension ChatRunOutcome {
    /// A failure envelope's structured fields, when they name a memory or
    /// model-residency cause.
    static func classify(envelope: String) -> ChatRunOutcome? {
        guard envelope.utf8.count <= 256 * 1024, ToolEnvelope.isError(envelope),
            let data = envelope.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let tool = dict["tool"] as? String
        switch dict["admission"] as? String {
        case "stable_memory_refusal":
            let decision = dict["memory_decision"] as? [String: Any] ?? [:]
            var outcome = ChatRunOutcome(kind: .memoryRefused, tool: tool, facts: admissionFacts(decision))
            outcome.memoryPressure = decision["memory_pressure"] as? String
            outcome.limitedBy = decision["limited_by"] as? [String] ?? []
            return outcome
        case "timeout", "capacity_changed":
            return ChatRunOutcome(kind: .modelBusy, tool: tool)
        default:
            break
        }
        guard let cause = dict[residencyKey] as? String else { return nil }
        var facts: [Fact] = []
        if let needed = dict["needed_bytes"] as? NSNumber {
            facts.append(Fact(label: L("Needed"), value: bytes(needed.uint64Value)))
        }
        if let available = dict["available_bytes"] as? NSNumber {
            facts.append(Fact(label: L("Available"), value: bytes(available.uint64Value)))
        }
        if let model = dict["model"] as? String {
            facts.insert(Fact(label: L("Model"), value: model), at: 0)
        }
        switch cause {
        case "insufficient_memory": return ChatRunOutcome(kind: .memoryRefused, tool: tool, facts: facts)
        case "memory_load_refused": return ChatRunOutcome(kind: .memoryLoadRefused, tool: tool, facts: facts)
        case "model_busy": return ChatRunOutcome(kind: .modelBusy, tool: tool)
        case "model_residency": return ChatRunOutcome(kind: .modelResidency, tool: tool)
        default: return nil
        }
    }

    /// A thrown error, by the kind `WorkflowFailure.classify` gives it.
    static func classify(error: Error) -> ChatRunOutcome? {
        let failure = WorkflowFailure.classify(error)
        switch failure.kind {
        case "insufficient_memory", "memory_admission":
            return ChatRunOutcome(kind: .memoryRefused, facts: errorFacts(error))
        case "memory_load_refused":
            return ChatRunOutcome(kind: .memoryLoadRefused, facts: errorFacts(error))
        case "model_busy":
            return ChatRunOutcome(kind: .modelBusy)
        case "model_residency":
            return ChatRunOutcome(kind: .modelResidency)
        default:
            // MLX and Metal allocation failures arrive untyped; this is the
            // one cause read from the runtime's own error text.
            if ChatErrorMessages.isSystemResourceExhaustion(error.localizedDescription) {
                return ChatRunOutcome(kind: .memoryExhausted)
            }
            return nil
        }
    }

    /// The agent loop's own fallback sentences, which it emits only after its
    /// recovery for that stop is spent. The Architect keeps its own
    /// output-limit message and Continue suggestion.
    static func classify(loopFallback text: String, architect: Bool = false) -> ChatRunOutcome? {
        switch text {
        case AgentToolLoop.lengthExhaustedFallback:
            return architect ? nil : ChatRunOutcome(kind: .outputLimit)
        case AgentToolLoop.truncatedToolCallFallback:
            return ChatRunOutcome(kind: .outputLimit)
        case AgentToolLoop.emptyTurnFallback, AgentToolLoop.emptyToolTaskFallback:
            return ChatRunOutcome(kind: .emptyResponse)
        default:
            return nil
        }
    }

    static func classify(exit: AgentToolLoop.Exit) -> ChatRunOutcome? {
        switch exit {
        case .lengthExhausted, .truncatedToolCallExhausted: return ChatRunOutcome(kind: .outputLimit)
        case .incompleteReasoningExhausted: return ChatRunOutcome(kind: .reasoningOnly)
        case .emptyResponseExhausted: return ChatRunOutcome(kind: .emptyResponse)
        case .overBudget: return ChatRunOutcome(kind: .contextTooLong)
        case .iterationCapReached: return ChatRunOutcome(kind: .stepLimit)
        case .finalResponse, .endedBySurface, .toolRejected, .cancelled, .repetitionLoopExhausted:
            return nil
        }
    }

    /// Structured fields for a thrown memory or residency error crossing the
    /// tool-envelope boundary, so the chat can classify the envelope later.
    static func envelopeMetadata(for error: Error) -> [String: Any]? {
        switch error {
        case let refusal as ModelRuntime.MemorySafetyLoadRefusal:
            var metadata: [String: Any] = [
                residencyKey: "memory_load_refused", "model": refusal.modelName,
                "setting_id": memorySafetySettingId,
            ]
            if let needed = refusal.estimatedWorkingSetBytes { metadata["needed_bytes"] = needed }
            if let budget = refusal.loadBudgetBytes { metadata["available_bytes"] = budget }
            return metadata
        case let handoff as ChatResidencyHandoff.HandoffError:
            switch handoff {
            case .chatBusy:
                return [residencyKey: "model_busy"]
            case let .insufficientMemory(neededGB, availableGB):
                return [
                    residencyKey: "insufficient_memory",
                    "needed_bytes": UInt64(max(0, neededGB) * 1_073_741_824),
                    "available_bytes": UInt64(max(0, availableGB) * 1_073_741_824),
                    "setting_id": delegationMemoryCheckSettingId,
                ]
            case .restoreFailed, .parentNotReclaimable, .restoreBlocked, .ownedChildCleanupFailed:
                return [residencyKey: "model_residency", "setting_id": swapModelsSettingId]
            }
        default:
            return nil
        }
    }

    static let residencyKey = "residency"

    private static func errorFacts(_ error: Error) -> [Fact] {
        guard let metadata = envelopeMetadata(for: error) else { return [] }
        var facts: [Fact] = []
        if let model = metadata["model"] as? String { facts.append(Fact(label: L("Model"), value: model)) }
        if let needed = metadata["needed_bytes"] as? UInt64 {
            facts.append(Fact(label: L("Needed"), value: bytes(needed)))
        }
        if let available = metadata["available_bytes"] as? UInt64 {
            facts.append(Fact(label: L("Available"), value: bytes(available)))
        }
        return facts
    }

    /// The admission decision's own terms, in the order a person reads them.
    private static func admissionFacts(_ decision: [String: Any]) -> [Fact] {
        func number(_ key: String) -> UInt64? { (decision[key] as? NSNumber)?.uint64Value }
        var facts: [Fact] = []
        if let model = decision["canonical_model"] as? String, !model.isEmpty {
            facts.append(Fact(label: L("Model"), value: model))
        }
        var needed = number("per_child_bytes") ?? 0
        if (decision["target_already_resident"] as? Bool) == false, let load = number("target_load_bytes") {
            needed += load
        }
        if needed > 0 { facts.append(Fact(label: L("Needed for this run"), value: bytes(needed))) }
        if let available = number("reclaimable_bytes") {
            facts.append(Fact(label: L("Available now"), value: bytes(available)))
        }
        if let reserve = number("os_reserve_bytes"), reserve > 0 {
            facts.append(Fact(label: L("Kept free for macOS"), value: bytes(reserve)))
        }
        if let pressure = decision["memory_pressure"] as? String {
            facts.append(Fact(label: L("Memory pressure"), value: pressureLabel(pressure)))
        }
        if let limits = decision["limited_by"] as? [String], !limits.isEmpty {
            facts.append(Fact(label: L("Limited by"), value: limits.map(limitLabel).joined(separator: ", ")))
        }
        return facts
    }

    private static func limitLabel(_ raw: String) -> String {
        switch SubagentBatchLimitingFactor(rawValue: raw) {
        case .agentPolicy: return L("Parallel helper limit")
        case .continuousBatchingDisabled: return L("Continuous Batching is off")
        case .engineCapacity: return L("Model busy with other runs")
        case .memoryCapacity: return L("Free memory")
        case .memoryEstimateUnavailable: return L("Memory estimate unavailable")
        case nil: return raw
        }
    }

    private static func pressureLabel(_ raw: String) -> String {
        switch raw {
        case "normal": return L("Normal")
        case "warning": return L("Elevated")
        case "critical": return L("Critical")
        default: return L("Unknown")
        }
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}
