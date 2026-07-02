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
        self.error = error
    }
}

/// Process-wide transcript sink. The CLI points it at
/// `<report>.transcripts/` when `--transcripts` is set; runners hand it
/// every LLM-case transcript and it persists ONLY failed/errored rows
/// (a passing case's transcript is rarely interesting and multiplies
/// disk fast). Repeat trials overwrite the same file — only failing
/// trials write, so the file always holds a failing trial's forensics.
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
            try data.write(to: directory.appendingPathComponent("\(safeName).json"))
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
