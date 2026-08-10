//
//  EvalTranscript.swift
//  OsaurusEvalsKit
//
//  Full-transcript persistence for failed/errored LLM cases, behind the
//  CLI's `--transcripts` flag. Report `notes` intentionally truncate
//  (one-line diagnostics, 300-char result previews); when a case fails
//  the question is always "what did the model actually see and do?" —
//  this writes the whole thing (system prompt, every tool call with
//  arguments and result preview, final text, loop notices) as one JSON
//  per failed case next to the report, so forensics never require a
//  re-run.
//
//  Off by default: transcripts contain the full system prompt and tool
//  results, which is exactly what you want locally and exactly what a
//  committed/shared report shouldn't carry by accident.
//

import Foundation

struct EvalTrialIdentity: Sendable, Equatable {
    let ordinal: Int
    let total: Int
}

enum EvalTrialExecutionContext {
    @TaskLocal static var current: EvalTrialIdentity?
}

/// A persisted transcript for one failed/errored case. Field coverage
/// intentionally follows the union of the runner transcripts
/// (`AgentLoopTranscript`, `CapabilityClaimsTranscript`); optional fields
/// stay nil for domains that don't produce them.
public struct EvalCaseTranscript: Codable, Sendable {
    public struct ToolEvent: Codable, Sendable {
        public let name: String
        /// Raw JSON argument string as the model produced it.
        public let arguments: String
        /// Result envelope preview (agent_loop keeps the first 300 chars);
        /// nil for domains that don't capture results.
        public let resultPreview: String?
        public let wasDeduped: Bool?
        public let wasError: Bool?

        public init(
            name: String,
            arguments: String,
            resultPreview: String? = nil,
            wasDeduped: Bool? = nil,
            wasError: Bool? = nil
        ) {
            self.name = name
            self.arguments = arguments
            self.resultPreview = resultPreview
            self.wasDeduped = wasDeduped
            self.wasError = wasError
        }
    }

    public struct StepEvent: Codable, Sendable {
        public let step: Int
        public let stopReason: String?
        public let contentCharacterCount: Int
        public let reasoningCharacterCount: Int
        public let contentPreview: String?
        public let reasoningPreview: String?
        public let sawToolCallProgress: Bool
        public let pendingToolName: String?
        public let toolArgumentCharacters: Int
        public let completionTokens: Int?
        public let decodeTokensPerSecond: Double?
        /// Always populated for current artifacts. Historical transcripts that
        /// predate this field decode as `unavailable_legacy_transcript`.
        public let decodeThroughputAttribution: String
        public let requestedEnableThinking: Bool?
        public let thinkingState: String?

        public init(
            step: Int,
            stopReason: String?,
            contentCharacterCount: Int,
            reasoningCharacterCount: Int,
            contentPreview: String?,
            reasoningPreview: String?,
            sawToolCallProgress: Bool,
            pendingToolName: String?,
            toolArgumentCharacters: Int,
            completionTokens: Int? = nil,
            decodeTokensPerSecond: Double? = nil,
            decodeThroughputAttribution: String? = nil,
            requestedEnableThinking: Bool?,
            thinkingState: String? = nil
        ) {
            self.step = step
            self.stopReason = stopReason
            self.contentCharacterCount = contentCharacterCount
            self.reasoningCharacterCount = reasoningCharacterCount
            self.contentPreview = contentPreview
            self.reasoningPreview = reasoningPreview
            self.sawToolCallProgress = sawToolCallProgress
            self.pendingToolName = pendingToolName
            self.toolArgumentCharacters = toolArgumentCharacters
            self.completionTokens = completionTokens
            self.decodeTokensPerSecond = decodeTokensPerSecond
            self.decodeThroughputAttribution = decodeThroughputAttribution
                ?? (decodeTokensPerSecond != nil
                    ? "measured_vmlx_info"
                    : "unavailable_no_vmlx_info")
            self.requestedEnableThinking = requestedEnableThinking
            self.thinkingState = thinkingState
                ?? requestedEnableThinking.map {
                    $0 ? "explicitEnabled" : "explicitDisabled"
                } ?? "runtimeDefault"
        }

        private enum CodingKeys: String, CodingKey {
            case step
            case stopReason
            case contentCharacterCount
            case reasoningCharacterCount
            case contentPreview
            case reasoningPreview
            case sawToolCallProgress
            case pendingToolName
            case toolArgumentCharacters
            case completionTokens
            case decodeTokensPerSecond
            case decodeThroughputAttribution
            case requestedEnableThinking
            case thinkingState
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            step = try container.decode(Int.self, forKey: .step)
            stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            contentCharacterCount = try container.decode(Int.self, forKey: .contentCharacterCount)
            reasoningCharacterCount = try container.decode(
                Int.self,
                forKey: .reasoningCharacterCount
            )
            contentPreview = try container.decodeIfPresent(String.self, forKey: .contentPreview)
            reasoningPreview = try container.decodeIfPresent(String.self, forKey: .reasoningPreview)
            sawToolCallProgress = try container.decode(Bool.self, forKey: .sawToolCallProgress)
            pendingToolName = try container.decodeIfPresent(String.self, forKey: .pendingToolName)
            toolArgumentCharacters = try container.decode(Int.self, forKey: .toolArgumentCharacters)
            completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
            decodeTokensPerSecond = try container.decodeIfPresent(
                Double.self,
                forKey: .decodeTokensPerSecond
            )
            decodeThroughputAttribution = try container.decodeIfPresent(
                String.self,
                forKey: .decodeThroughputAttribution
            ) ?? (decodeTokensPerSecond != nil
                ? "measured_vmlx_info"
                : "unavailable_legacy_transcript")
            requestedEnableThinking = try container.decodeIfPresent(
                Bool.self,
                forKey: .requestedEnableThinking
            )
            thinkingState = try container.decodeIfPresent(String.self, forKey: .thinkingState)
                ?? requestedEnableThinking.map {
                    $0 ? "explicitEnabled" : "explicitDisabled"
                } ?? "runtimeDefault"
        }
    }

    public let caseId: String
    public let domain: String
    public let modelId: String
    public let outcome: String
    public let query: String
    /// First-turn system prompt (post-compose) — "what the model saw".
    public let systemPrompt: String?
    /// Tool schemas sent on the first iteration (agent_loop).
    public let toolSchemaNames: [String]?
    /// Every processed tool call, in model order across iterations.
    public let toolCalls: [ToolEvent]
    /// Tools brought in mid-session via `capabilities_load`.
    public let loadedToolNames: [String]?
    public let finalText: String
    public let iterations: Int?
    /// Loop exit reason (agent_loop): finalResponse, iterationCapReached, …
    public let exit: String?
    /// Driver-staged transient notices (budget warnings, dedupe, nudges).
    public let notices: [String]?
    /// Bounded per-model-step generation/tool-envelope forensics.
    public let stepDiagnostics: [StepEvent]?
    /// Repeat-run identity. nil for ordinary one-shot cases and reports
    /// produced before per-trial evidence preservation.
    public let trial: Int?
    public let trialCount: Int?
    public let error: String?

    public init(
        caseId: String,
        domain: String,
        modelId: String,
        outcome: String,
        query: String,
        systemPrompt: String? = nil,
        toolSchemaNames: [String]? = nil,
        toolCalls: [ToolEvent] = [],
        loadedToolNames: [String]? = nil,
        finalText: String,
        iterations: Int? = nil,
        exit: String? = nil,
        notices: [String]? = nil,
        stepDiagnostics: [StepEvent]? = nil,
        trial: Int? = nil,
        trialCount: Int? = nil,
        error: String? = nil
    ) {
        self.caseId = caseId
        self.domain = domain
        self.modelId = modelId
        self.outcome = outcome
        self.query = query
        self.systemPrompt = systemPrompt
        self.toolSchemaNames = toolSchemaNames
        self.toolCalls = toolCalls
        self.loadedToolNames = loadedToolNames
        self.finalText = finalText
        self.iterations = iterations
        self.exit = exit
        self.notices = notices
        self.stepDiagnostics = stepDiagnostics
        self.trial = trial ?? EvalTrialExecutionContext.current?.ordinal
        self.trialCount = trialCount ?? EvalTrialExecutionContext.current?.total
        self.error = error
    }
}

/// Process-wide transcript sink. The CLI points it at
/// `<report>.transcripts/` when `--transcripts` is set; runners hand it
/// every LLM-case transcript and it persists ONLY failed/errored rows
/// (a passing case's transcript is rarely interesting and multiplies
/// disk fast). Repeat failures carry a trial ordinal and write distinct files,
/// so stochastic protocol failures do not overwrite one another.
@MainActor
public enum EvalTranscriptStore {
    /// Destination directory; nil (default) disables persistence.
    public private(set) static var directory: URL?
    /// Files written since `configure` — the CLI's end-of-suite summary.
    public private(set) static var writtenCount = 0

    /// Point the store at a directory (created lazily on first write) or
    /// disable it with nil. Resets the written counter — call per suite.
    public static func configure(directory: URL?) {
        self.directory = directory
        writtenCount = 0
    }

    /// Persist `transcript` iff the store is enabled and the case did not
    /// pass/skip. Failures are swallowed into stderr — transcript loss
    /// must never fail a run that already produced its report.
    public static func persistIfEnabled(_ transcript: EvalCaseTranscript) {
        guard let directory else { return }
        // `outcome` is the persisted rawValue of `EvalCaseOutcome`; keep it
        // tied to the enum rather than bare string literals.
        let persisted: Set<String> = [
            EvalCaseOutcome.failed.rawValue, EvalCaseOutcome.errored.rawValue,
        ]
        guard persisted.contains(transcript.outcome) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(transcript)
            let safeName = transcript.caseId.replacingOccurrences(of: "/", with: "-")
            let suffix = transcript.trial.map { ".trial-\($0)" } ?? ""
            try data.write(
                to: directory.appendingPathComponent("\(safeName)\(suffix).json")
            )
            writtenCount += 1
        } catch {
            FileHandle.standardError.write(
                Data("[evals] transcript write failed for \(transcript.caseId): \(error)\n".utf8)
            )
        }
    }

    /// Sidecar directory for a report path: `report.json` →
    /// `report.transcripts/` (sibling, so run dirs stay self-contained).
    public static func sidecarDirectory(forOut outPath: String) -> URL {
        let base = URL(fileURLWithPath: outPath)
        let stem = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(stem).transcripts", isDirectory: true)
    }
}
