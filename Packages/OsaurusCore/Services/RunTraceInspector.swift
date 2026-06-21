//
//  RunTraceInspector.swift
//  osaurus
//
//  Offline diagnostics for saved agent/eval/tool run traces. The inspector is
//  deliberately nonthrowing at the public entry points: malformed artifacts are
//  returned as typed findings so callers can show exactly what failed.
//

import Foundation

public struct RunTraceInspection: Codable, Sendable, Equatable {
    public enum ArtifactKind: String, Codable, Sendable {
        case runTrace
        case evalReport
        case genericSteps
        case unknown
    }

    public let sourcePath: String?
    public let artifactKind: ArtifactKind
    public let summary: Summary
    public let steps: [Step]
    public let toolCalls: [ToolCall]
    public let findings: [Finding]
    public let redactionCount: Int

    public init(
        sourcePath: String?,
        artifactKind: ArtifactKind,
        summary: Summary,
        steps: [Step],
        toolCalls: [ToolCall],
        findings: [Finding],
        redactionCount: Int
    ) {
        self.sourcePath = sourcePath
        self.artifactKind = artifactKind
        self.summary = summary
        self.steps = steps
        self.toolCalls = toolCalls
        self.findings = findings
        self.redactionCount = redactionCount
    }

    public var hasErrors: Bool {
        findings.contains { $0.severity == .error }
    }

    public func jsonReport(prettyPrinted: Bool = true) throws -> Data {
        try JSONEncoder.osaurusCanonical(prettyPrinted: prettyPrinted).encode(self)
    }

    public func markdownReport() -> String {
        var lines: [String] = []
        lines.append("# Run Trace Diagnostic")
        lines.append("")
        lines.append("## Summary")
        appendBullet("source", sourcePath ?? "(in-memory)", into: &lines)
        appendBullet("kind", artifactKind.rawValue, into: &lines)
        appendBullet("title", summary.title, into: &lines)
        appendBullet("status", summary.status ?? "n/a", into: &lines)
        appendBullet("runId", summary.runId, into: &lines)
        appendBullet("agentId", summary.agentId, into: &lines)
        appendBullet("sessionId", summary.sessionId, into: &lines)
        appendBullet("trigger", summary.triggerSource, into: &lines)
        appendBullet("model", summary.modelId, into: &lines)
        appendBullet("startedAt", summary.startedAt, into: &lines)
        appendBullet("endedAt", summary.endedAt, into: &lines)
        if let durationMs = summary.durationMs {
            appendBullet("duration", Self.formatDuration(ms: durationMs), into: &lines)
        }
        appendBullet("turns", String(summary.turnCount), into: &lines)
        appendBullet("steps", String(summary.stepCount), into: &lines)
        appendBullet("toolCalls", String(summary.toolCallCount), into: &lines)
        appendBullet("toolErrors", String(summary.toolErrorCount), into: &lines)
        if let tokensIn = summary.tokensIn { appendBullet("tokensIn", String(tokensIn), into: &lines) }
        if let tokensOut = summary.tokensOut { appendBullet("tokensOut", String(tokensOut), into: &lines) }
        if let costUSD = summary.costUSD {
            appendBullet("costUSD", String(format: "%.6f", costUSD), into: &lines)
        }
        appendBullet("redactions", String(redactionCount), into: &lines)
        if !summary.notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            for note in summary.notes {
                lines.append("- \(note)")
            }
        }

        lines.append("")
        lines.append("## Findings")
        if findings.isEmpty {
            lines.append("- none")
        } else {
            for finding in findings {
                lines.append(
                    "- [\(finding.severity.rawValue)] \(finding.code.rawValue) at `\(finding.path)`: \(finding.message)"
                )
            }
        }

        lines.append("")
        lines.append("## Tool Calls")
        if toolCalls.isEmpty {
            lines.append("- none")
        } else {
            lines.append("| # | tool | status | arguments | result |")
            lines.append("|---:|---|---|---|---|")
            for call in toolCalls {
                lines.append(
                    "| \(call.index) | \(Self.escapeTable(call.name)) | \(Self.escapeTable(call.resultStatus ?? "n/a")) | \(Self.escapeTable(call.argumentsPreview)) | \(Self.escapeTable(call.resultPreview ?? "n/a")) |"
                )
            }
        }

        lines.append("")
        lines.append("## Steps")
        if steps.isEmpty {
            lines.append("- none")
        } else {
            for step in steps {
                let status = step.status.map { " [\($0)]" } ?? ""
                lines.append("- \(step.index). \(step.kind.rawValue): \(step.title)\(status)")
                if let detail = step.detail, !detail.isEmpty {
                    lines.append("  \(detail)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func appendBullet(_ label: String, _ value: String?, into lines: inout [String]) {
        guard let value, !value.isEmpty else { return }
        lines.append("- \(label): \(value)")
    }

    private static func formatDuration(ms: Double) -> String {
        if ms < 1_000 { return String(format: "%.0fms", ms) }
        if ms < 60_000 { return String(format: "%.2fs", ms / 1_000) }
        let seconds = Int(ms.rounded() / 1_000)
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func escapeTable(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    public struct Summary: Codable, Sendable, Equatable {
        public let title: String
        public let status: String?
        public let runId: String?
        public let agentId: String?
        public let sessionId: String?
        public let triggerSource: String?
        public let modelId: String?
        public let startedAt: String?
        public let endedAt: String?
        public let durationMs: Double?
        public let turnCount: Int
        public let stepCount: Int
        public let toolCallCount: Int
        public let toolErrorCount: Int
        public let tokensIn: Int?
        public let tokensOut: Int?
        public let costUSD: Double?
        public let notes: [String]

        public init(
            title: String,
            status: String?,
            runId: String?,
            agentId: String?,
            sessionId: String?,
            triggerSource: String?,
            modelId: String?,
            startedAt: String?,
            endedAt: String?,
            durationMs: Double?,
            turnCount: Int,
            stepCount: Int,
            toolCallCount: Int,
            toolErrorCount: Int,
            tokensIn: Int?,
            tokensOut: Int?,
            costUSD: Double?,
            notes: [String]
        ) {
            self.title = title
            self.status = status
            self.runId = runId
            self.agentId = agentId
            self.sessionId = sessionId
            self.triggerSource = triggerSource
            self.modelId = modelId
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.durationMs = durationMs
            self.turnCount = turnCount
            self.stepCount = stepCount
            self.toolCallCount = toolCallCount
            self.toolErrorCount = toolErrorCount
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.costUSD = costUSD
            self.notes = notes
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case turn
            case caseResult
            case toolResult
            case metadata
        }

        public let index: Int
        public let kind: Kind
        public let title: String
        public let detail: String?
        public let status: String?
        public let timingMs: Double?
        public let relatedToolCallIds: [String]

        public init(
            index: Int,
            kind: Kind,
            title: String,
            detail: String?,
            status: String?,
            timingMs: Double?,
            relatedToolCallIds: [String]
        ) {
            self.index = index
            self.kind = kind
            self.title = title
            self.detail = detail
            self.status = status
            self.timingMs = timingMs
            self.relatedToolCallIds = relatedToolCallIds
        }
    }

    public struct ToolCall: Codable, Sendable, Equatable {
        public let index: Int
        public let id: String
        public let name: String
        public let turnIndex: Int?
        public let argumentsPreview: String
        public let argumentFormat: String
        public let resultPreview: String?
        public let resultStatus: String?
        public let resultTurnIndex: Int?
        public let redactedPaths: [String]

        public init(
            index: Int,
            id: String,
            name: String,
            turnIndex: Int?,
            argumentsPreview: String,
            argumentFormat: String,
            resultPreview: String?,
            resultStatus: String?,
            resultTurnIndex: Int?,
            redactedPaths: [String]
        ) {
            self.index = index
            self.id = id
            self.name = name
            self.turnIndex = turnIndex
            self.argumentsPreview = argumentsPreview
            self.argumentFormat = argumentFormat
            self.resultPreview = resultPreview
            self.resultStatus = resultStatus
            self.resultTurnIndex = resultTurnIndex
            self.redactedPaths = redactedPaths
        }
    }

    public struct Finding: Codable, Sendable, Equatable {
        public enum Severity: String, Codable, Sendable, Hashable {
            case info
            case warning
            case error
        }

        public enum Code: String, Codable, Sendable, Hashable {
            case fileReadFailed
            case invalidJSON
            case unsupportedArtifact
            case missingRequiredField
            case invalidFieldType
            case invalidFieldValue
            case decodeFailed
            case malformedToolArguments
            case malformedToolResult
            case missingToolResult
            case orphanToolResult
            case duplicateToolResult
            case traceError
            case timingUnavailable
            case redactionApplied
        }

        public let severity: Severity
        public let code: Code
        public let path: String
        public let message: String

        public init(
            severity: Severity,
            code: Code,
            path: String,
            message: String
        ) {
            self.severity = severity
            self.code = code
            self.path = path
            self.message = message
        }
    }
}

public enum RunTraceInspector {
    public struct Options: Sendable, Equatable {
        public static let minimumPreviewLimit = 40
        public static let maximumPreviewLimit = 2_000

        public let previewLimit: Int
        public let includeInformationalFindings: Bool
        public let sensitiveKeyFragments: [String]

        public init(
            previewLimit: Int = 240,
            includeInformationalFindings: Bool = true,
            sensitiveKeyFragments: [String] = Self.defaultSensitiveKeyFragments
        ) {
            self.previewLimit = min(Self.maximumPreviewLimit, max(Self.minimumPreviewLimit, previewLimit))
            self.includeInformationalFindings = includeInformationalFindings
            self.sensitiveKeyFragments = sensitiveKeyFragments.map { $0.lowercased() }
        }

        public static let defaultSensitiveKeyFragments = [
            "api_key",
            "apikey",
            "authorization",
            "bearer",
            "cookie",
            "credential",
            "keychain",
            "password",
            "private_key",
            "secret",
            "access_token",
            "refresh_token",
            "id_token",
            "auth_token",
            "session_token",
            "token",
        ]
    }

    private struct ToolResultRecord {
        let turnIndex: Int
        let content: String
    }

    private struct RedactedPreview {
        let text: String
        let format: String
        let redactedPaths: [String]
        let parseFailed: Bool
        let lookedLikeJSON: Bool
    }

    public static func inspectFile(
        at url: URL,
        options: Options = Options()
    ) -> RunTraceInspection {
        do {
            let data = try Data(contentsOf: url)
            return inspect(data: data, sourcePath: safeSourcePath(url.path), options: options)
        } catch {
            return failedInspection(
                sourcePath: safeSourcePath(url.path),
                code: .fileReadFailed,
                message: error.localizedDescription
            )
        }
    }

    public static func inspect(
        data: Data,
        sourcePath: String? = nil,
        options: Options = Options()
    ) -> RunTraceInspection {
        let displaySourcePath = safeSourcePath(sourcePath)
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return failedInspection(
                sourcePath: displaySourcePath,
                code: .invalidJSON,
                message: error.localizedDescription
            )
        }

        guard let root = rootObject as? [String: Any] else {
            return unknownInspection(
                sourcePath: displaySourcePath,
                finding: .init(
                    severity: .error,
                    code: .invalidFieldType,
                    path: "$",
                    message: "trace root must be a JSON object"
                )
            )
        }

        if root["runId"] != nil || root["agentId"] != nil || root["turns"] != nil {
            return inspectRunTrace(root: root, data: data, sourcePath: displaySourcePath, options: options)
        }
        if root["cases"] != nil || (root["modelId"] != nil && root["startedAt"] != nil) {
            return inspectEvalReport(root: root, sourcePath: displaySourcePath, options: options)
        }
        if root["steps"] != nil {
            return inspectGenericSteps(root: root, sourcePath: displaySourcePath, options: options)
        }
        return unknownInspection(
            sourcePath: displaySourcePath,
            finding: .init(
                severity: .error,
                code: .unsupportedArtifact,
                path: "$",
                message: "unrecognized trace artifact; expected RunTrace, EvalReport, or a step trace"
            )
        )
    }

    private static func inspectRunTrace(
        root: [String: Any],
        data: Data,
        sourcePath: String?,
        options: Options
    ) -> RunTraceInspection {
        var findings = validateRunTraceRoot(root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseISODate(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid ISO-8601 date")
            )
        }

        guard let trace = try? decoder.decode(RunTrace.self, from: data) else {
            findings.append(
                .init(
                    severity: .error,
                    code: .decodeFailed,
                    path: "$",
                    message: "RunTrace decoding failed after structural validation; inspect typed findings above"
                )
            )
            return partialRunTraceInspection(
                root: root,
                sourcePath: sourcePath,
                findings: filter(findings, options: options),
                options: options
            )
        }

        if trace.endedAt < trace.startedAt {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldValue,
                    path: "$.endedAt",
                    message: "endedAt is earlier than startedAt"
                )
            )
        }
        if trace.turns.isEmpty {
            findings.append(
                .init(
                    severity: .warning,
                    code: .missingRequiredField,
                    path: "$.turns",
                    message: "trace contains no turns"
                )
            )
        } else {
            findings.append(
                .init(
                    severity: .info,
                    code: .timingUnavailable,
                    path: "$.turns",
                    message: "per-turn timings are not recorded; report uses run-level duration only"
                )
            )
        }

        let resultRecords = toolResultRecords(from: trace.turns, findings: &findings)
        let callIds = Set(trace.turns.flatMap { $0.toolCalls ?? [] }.map(\.id))
        for resultId in resultRecords.keys.sorted() where !callIds.contains(resultId) {
            findings.append(
                .init(
                    severity: .warning,
                    code: .orphanToolResult,
                    path: "$.turns",
                    message: "tool result '\(resultId)' has no matching assistant tool call"
                )
            )
        }

        var redactionCount = 0
        var toolCalls: [RunTraceInspection.ToolCall] = []
        var callIndex = 0
        for (turnIndex, turn) in trace.turns.enumerated() {
            for (innerIndex, call) in (turn.toolCalls ?? []).enumerated() {
                let callPath = "$.turns[\(turnIndex)].toolCalls[\(innerIndex)]"
                let args = redactedPreview(
                    call.arguments,
                    path: "\(callPath).arguments",
                    options: options
                )
                if args.parseFailed {
                    findings.append(
                        .init(
                            severity: .warning,
                            code: .malformedToolArguments,
                            path: "\(callPath).arguments",
                            message: "tool arguments are not parseable JSON"
                        )
                    )
                }

                let result = resultRecords[call.id]
                if result == nil {
                    findings.append(
                        .init(
                            severity: .warning,
                            code: .missingToolResult,
                            path: callPath,
                            message: "tool call '\(call.id)' has no matching result"
                        )
                    )
                }
                let resultPreviewValue = result.map {
                    redactedPreview(
                        $0.content,
                        path: "$.turns[\($0.turnIndex)].toolResults[\(call.id)]",
                        options: options
                    )
                }
                if resultPreviewValue?.parseFailed == true {
                    findings.append(
                        .init(
                            severity: .warning,
                            code: .malformedToolResult,
                            path: "$.turns[\(result?.turnIndex ?? turnIndex)].toolResults[\(call.id)]",
                            message: "tool result looked like JSON but was not parseable"
                        )
                    )
                }
                let redactedPaths = args.redactedPaths + (resultPreviewValue?.redactedPaths ?? [])
                redactionCount += redactedPaths.count
                let status = result.map { resultStatus($0.content) } ?? "missing"
                if status == "error" {
                    findings.append(
                        .init(
                            severity: .warning,
                            code: .traceError,
                            path: callPath,
                            message: "tool call '\(call.name)' returned an error-shaped result"
                        )
                    )
                }
                toolCalls.append(
                    .init(
                        index: callIndex,
                        id: call.id,
                        name: call.name,
                        turnIndex: turnIndex,
                        argumentsPreview: args.text,
                        argumentFormat: args.format,
                        resultPreview: resultPreviewValue?.text,
                        resultStatus: status,
                        resultTurnIndex: result?.turnIndex,
                        redactedPaths: redactedPaths
                    )
                )
                callIndex += 1
            }
        }

        let steps = runTraceSteps(
            trace: trace,
            toolCalls: toolCalls,
            options: options,
            redactionCount: &redactionCount
        )
        let terminalErrorNote: String?
        if let errorMessage = trace.errorMessage {
            let redacted = redactedPreview(
                errorMessage,
                path: "$.errorMessage",
                options: options
            )
            redactionCount += redacted.redactedPaths.count
            terminalErrorNote = "terminal error: \(redacted.text)"
        } else {
            terminalErrorNote = nil
        }
        if redactionCount > 0 {
            findings.append(redactionFinding(count: redactionCount))
        }

        let errorCount = toolCalls.filter { $0.resultStatus == "error" }.count
            + (trace.errorMessage == nil ? 0 : 1)
        let summary = RunTraceInspection.Summary(
            title: "Agent run \(trace.runId.uuidString)",
            status: trace.status,
            runId: trace.runId.uuidString,
            agentId: trace.agentId.uuidString,
            sessionId: trace.sessionId,
            triggerSource: trace.triggerSource,
            modelId: nil,
            startedAt: isoString(trace.startedAt),
            endedAt: isoString(trace.endedAt),
            durationMs: trace.endedAt.timeIntervalSince(trace.startedAt) * 1_000,
            turnCount: trace.turns.count,
            stepCount: steps.count,
            toolCallCount: toolCalls.count,
            toolErrorCount: errorCount,
            tokensIn: trace.tokensIn,
            tokensOut: trace.tokensOut,
            costUSD: trace.costUSD,
            notes: terminalErrorNote.map { [$0] } ?? []
        )
        return .init(
            sourcePath: sourcePath,
            artifactKind: .runTrace,
            summary: summary,
            steps: steps,
            toolCalls: toolCalls,
            findings: filter(findings, options: options),
            redactionCount: redactionCount
        )
    }

    private static func inspectEvalReport(
        root: [String: Any],
        sourcePath: String?,
        options: Options
    ) -> RunTraceInspection {
        var findings: [RunTraceInspection.Finding] = []
        let modelId = requiredString(root, key: "modelId", path: "$.modelId", findings: &findings)
        let startedAt = requiredString(root, key: "startedAt", path: "$.startedAt", findings: &findings)
        if let startedAt, parseISODate(startedAt) == nil {
            findings.append(
                .init(
                    severity: .warning,
                    code: .invalidFieldValue,
                    path: "$.startedAt",
                    message: "startedAt is not ISO-8601"
                )
            )
        }
        let cases = root["cases"] as? [[String: Any]]
        if root["cases"] != nil && cases == nil {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldType,
                    path: "$.cases",
                    message: "cases must be an array of objects"
                )
            )
        }

        var steps: [RunTraceInspection.Step] = []
        var toolCalls: [RunTraceInspection.ToolCall] = []
        var failed = 0
        var errored = 0
        var skipped = 0
        var passed = 0
        var redactionCount = 0
        var latencyTotal = 0.0
        var latencyCount = 0

        for (index, row) in (cases ?? []).enumerated() {
            let path = "$.cases[\(index)]"
            let id = optionalString(row["id"]) ?? "case[\(index)]"
            let domain = optionalString(row["domain"]) ?? "unknown"
            let outcome = optionalString(row["outcome"]) ?? "unknown"
            switch outcome {
            case "passed": passed += 1
            case "failed": failed += 1
            case "errored": errored += 1
            case "skipped": skipped += 1
            default:
                findings.append(
                    .init(
                        severity: .warning,
                        code: .invalidFieldValue,
                        path: "\(path).outcome",
                        message: "unknown eval outcome '\(outcome)'"
                    )
                )
            }
            if outcome == "failed" || outcome == "errored" {
                findings.append(
                    .init(
                        severity: outcome == "errored" ? .error : .warning,
                        code: .traceError,
                        path: path,
                        message: "eval case '\(id)' ended as \(outcome)"
                    )
                )
            }

            let queryPreview: String?
            if let query = optionalString(row["query"]) {
                let redacted = redactedPreview(query, path: "\(path).query", options: options)
                redactionCount += redacted.redactedPaths.count
                queryPreview = redacted.text
            } else {
                queryPreview = nil
            }
            let notes = (row["notes"] as? [String]) ?? []
            let redactedNotes = notes.map {
                redactedPreview($0, path: "\(path).notes", options: options)
            }
            redactionCount += redactedNotes.reduce(0) { $0 + $1.redactedPaths.count }
            if let latency = numberAsDouble(row["latencyMs"]) {
                latencyTotal += latency
                latencyCount += 1
            }
            let detailParts = [
                queryPreview.map { "query=\($0)" },
                redactedNotes.isEmpty ? nil : "notes=\(redactedNotes.map(\.text).joined(separator: " | "))",
            ].compactMap { $0 }
            steps.append(
                .init(
                    index: index,
                    kind: .caseResult,
                    title: "\(id) (\(domain))",
                    detail: detailParts.isEmpty ? nil : detailParts.joined(separator: "; "),
                    status: outcome,
                    timingMs: numberAsDouble(row["latencyMs"]),
                    relatedToolCallIds: []
                )
            )

            for usage in row["toolUsage"] as? [[String: Any]] ?? [] {
                let tool = optionalString(usage["tool"]) ?? "unknown"
                let calls = numberAsInt(usage["calls"]) ?? 0
                let errors = numberAsInt(usage["errors"]) ?? 0
                let deduped = numberAsInt(usage["deduped"]) ?? 0
                toolCalls.append(
                    .init(
                        index: toolCalls.count,
                        id: "\(id):\(tool)",
                        name: tool,
                        turnIndex: nil,
                        argumentsPreview: "calls=\(calls) errors=\(errors) deduped=\(deduped)",
                        argumentFormat: "eval-tool-usage",
                        resultPreview: nil,
                        resultStatus: errors > 0 ? "error" : "ok",
                        resultTurnIndex: nil,
                        redactedPaths: []
                    )
                )
            }
        }
        if redactionCount > 0 {
            findings.append(redactionFinding(count: redactionCount))
        }

        let summary = RunTraceInspection.Summary(
            title: "Eval report \(modelId ?? "unknown model")",
            status: "\(passed) passed, \(failed) failed, \(errored) errored, \(skipped) skipped",
            runId: nil,
            agentId: nil,
            sessionId: nil,
            triggerSource: "eval",
            modelId: modelId,
            startedAt: startedAt,
            endedAt: nil,
            durationMs: latencyCount > 0 ? latencyTotal : nil,
            turnCount: 0,
            stepCount: steps.count,
            toolCallCount: toolCalls.reduce(0) {
                $0 + (numberInToolUsagePreview($1.argumentsPreview, key: "calls") ?? 0)
            },
            toolErrorCount: toolCalls.reduce(0) {
                $0 + (numberInToolUsagePreview($1.argumentsPreview, key: "errors") ?? 0)
            },
            tokensIn: nil,
            tokensOut: nil,
            costUSD: nil,
            notes: latencyCount > 0 ? ["duration is the sum of per-case latencyMs values"] : []
        )
        return .init(
            sourcePath: sourcePath,
            artifactKind: .evalReport,
            summary: summary,
            steps: steps,
            toolCalls: toolCalls,
            findings: filter(findings, options: options),
            redactionCount: redactionCount
        )
    }

    private static func inspectGenericSteps(
        root: [String: Any],
        sourcePath: String?,
        options: Options
    ) -> RunTraceInspection {
        var findings: [RunTraceInspection.Finding] = []
        guard let rawSteps = root["steps"] as? [[String: Any]] else {
            return unknownInspection(
                sourcePath: sourcePath,
                finding: .init(
                    severity: .error,
                    code: .invalidFieldType,
                    path: "$.steps",
                    message: "steps must be an array of objects"
                )
            )
        }

        var redactionCount = 0
        let steps = rawSteps.enumerated().map { index, row in
            let title = optionalString(row["title"])
                ?? optionalString(row["name"])
                ?? optionalString(row["type"])
                ?? "step \(index)"
            let detail = optionalString(row["detail"])
                ?? optionalString(row["message"])
                ?? optionalString(row["content"])
            let redactedDetail = detail.map {
                redactedPreview($0, path: "$.steps[\(index)]", options: options)
            }
            redactionCount += redactedDetail?.redactedPaths.count ?? 0
            return RunTraceInspection.Step(
                index: index,
                kind: .metadata,
                title: title,
                detail: redactedDetail?.text,
                status: optionalString(row["status"]),
                timingMs: numberAsDouble(row["durationMs"]) ?? numberAsDouble(row["latencyMs"]),
                relatedToolCallIds: []
            )
        }
        if redactionCount > 0 {
            findings.append(redactionFinding(count: redactionCount))
        }

        let summary = RunTraceInspection.Summary(
            title: optionalString(root["title"]) ?? "Generic step trace",
            status: optionalString(root["status"]),
            runId: optionalString(root["runId"]),
            agentId: optionalString(root["agentId"]),
            sessionId: optionalString(root["sessionId"]),
            triggerSource: optionalString(root["triggerSource"]),
            modelId: optionalString(root["modelId"]),
            startedAt: optionalString(root["startedAt"]),
            endedAt: optionalString(root["endedAt"]),
            durationMs: numberAsDouble(root["durationMs"]),
            turnCount: 0,
            stepCount: steps.count,
            toolCallCount: 0,
            toolErrorCount: steps.filter { $0.status == "error" || $0.status == "failed" }.count,
            tokensIn: numberAsInt(root["tokensIn"]),
            tokensOut: numberAsInt(root["tokensOut"]),
            costUSD: numberAsDouble(root["costUSD"]),
            notes: []
        )
        return .init(
            sourcePath: sourcePath,
            artifactKind: .genericSteps,
            summary: summary,
            steps: steps,
            toolCalls: [],
            findings: filter(findings, options: options),
            redactionCount: redactionCount
        )
    }

    private static func validateRunTraceRoot(_ root: [String: Any]) -> [RunTraceInspection.Finding] {
        var findings: [RunTraceInspection.Finding] = []
        for key in ["runId", "agentId", "sessionId", "triggerSource", "status", "startedAt", "endedAt"] {
            _ = requiredString(root, key: key, path: "$.\(key)", findings: &findings)
        }
        if let runId = optionalString(root["runId"]), UUID(uuidString: runId) == nil {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldValue,
                    path: "$.runId",
                    message: "runId is not a UUID"
                )
            )
        }
        if let agentId = optionalString(root["agentId"]), UUID(uuidString: agentId) == nil {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldValue,
                    path: "$.agentId",
                    message: "agentId is not a UUID"
                )
            )
        }
        if let status = optionalString(root["status"]) {
            let knownStatuses = ["success", "error", "cancelled", "clamped", "running"]
            if !knownStatuses.contains(status) {
                findings.append(
                    .init(
                        severity: .warning,
                        code: .invalidFieldValue,
                        path: "$.status",
                        message: "status '\(status)' is not a known agent run status"
                    )
                )
            }
        }
        let started = optionalString(root["startedAt"]).flatMap(parseISODate)
        let ended = optionalString(root["endedAt"]).flatMap(parseISODate)
        if optionalString(root["startedAt"]) != nil && started == nil {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldValue,
                    path: "$.startedAt",
                    message: "startedAt is not ISO-8601"
                )
            )
        }
        if optionalString(root["endedAt"]) != nil && ended == nil {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldValue,
                    path: "$.endedAt",
                    message: "endedAt is not ISO-8601"
                )
            )
        }
        if let started, let ended, ended < started {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldValue,
                    path: "$.endedAt",
                    message: "endedAt is earlier than startedAt"
                )
            )
        }
        guard let turns = root["turns"] as? [[String: Any]] else {
            findings.append(
                .init(
                    severity: .error,
                    code: root["turns"] == nil ? .missingRequiredField : .invalidFieldType,
                    path: "$.turns",
                    message: "turns must be an array of objects"
                )
            )
            return findings
        }
        for (index, turn) in turns.enumerated() {
            let path = "$.turns[\(index)]"
            _ = requiredString(turn, key: "id", path: "\(path).id", findings: &findings)
            _ = requiredString(turn, key: "role", path: "\(path).role", findings: &findings)
            if turn["content"] != nil && !(turn["content"] is String) {
                findings.append(
                    .init(
                        severity: .error,
                        code: .invalidFieldType,
                        path: "\(path).content",
                        message: "content must be a string"
                    )
                )
            }
            if let id = optionalString(turn["id"]), UUID(uuidString: id) == nil {
                findings.append(
                    .init(
                        severity: .error,
                        code: .invalidFieldValue,
                        path: "\(path).id",
                        message: "turn id is not a UUID"
                    )
                )
            }
            if let calls = turn["toolCalls"], !(calls is NSNull) {
                guard let callObjects = calls as? [[String: Any]] else {
                    findings.append(
                        .init(
                            severity: .error,
                            code: .invalidFieldType,
                            path: "\(path).toolCalls",
                            message: "toolCalls must be an array of objects"
                        )
                    )
                    continue
                }
                for (callIndex, call) in callObjects.enumerated() {
                    let callPath = "\(path).toolCalls[\(callIndex)]"
                    _ = requiredString(call, key: "id", path: "\(callPath).id", findings: &findings)
                    _ = requiredString(call, key: "name", path: "\(callPath).name", findings: &findings)
                    _ = requiredString(call, key: "arguments", path: "\(callPath).arguments", findings: &findings)
                }
            }
            if let results = turn["toolResults"], !(results is NSNull) {
                if let resultObject = results as? [String: Any] {
                    for (key, value) in resultObject where !(value is String) {
                        findings.append(
                            .init(
                                severity: .error,
                                code: .invalidFieldType,
                                path: "\(path).toolResults.\(key)",
                                message: "tool result values must be strings"
                            )
                        )
                    }
                } else {
                    findings.append(
                        .init(
                            severity: .error,
                            code: .invalidFieldType,
                            path: "\(path).toolResults",
                            message: "toolResults must be an object of string values"
                        )
                    )
                }
            }
        }
        return findings
    }

    private static func partialRunTraceInspection(
        root: [String: Any],
        sourcePath: String?,
        findings: [RunTraceInspection.Finding],
        options: Options
    ) -> RunTraceInspection {
        let turns = root["turns"] as? [[String: Any]] ?? []
        let steps = turns.enumerated().map { index, turn in
            let redacted = optionalString(turn["content"]).map {
                redactedPreview($0, path: "$.turns[\(index)].content", options: options)
            }
            return RunTraceInspection.Step(
                index: index,
                kind: .turn,
                title: optionalString(turn["role"]) ?? "unknown",
                detail: redacted?.text,
                status: nil,
                timingMs: nil,
                relatedToolCallIds: []
            )
        }
        let summary = RunTraceInspection.Summary(
            title: "Malformed run trace",
            status: optionalString(root["status"]),
            runId: optionalString(root["runId"]),
            agentId: optionalString(root["agentId"]),
            sessionId: optionalString(root["sessionId"]),
            triggerSource: optionalString(root["triggerSource"]),
            modelId: nil,
            startedAt: optionalString(root["startedAt"]),
            endedAt: optionalString(root["endedAt"]),
            durationMs: nil,
            turnCount: turns.count,
            stepCount: steps.count,
            toolCallCount: 0,
            toolErrorCount: 0,
            tokensIn: numberAsInt(root["tokensIn"]),
            tokensOut: numberAsInt(root["tokensOut"]),
            costUSD: numberAsDouble(root["costUSD"]),
            notes: []
        )
        return .init(
            sourcePath: sourcePath,
            artifactKind: .runTrace,
            summary: summary,
            steps: steps,
            toolCalls: [],
            findings: findings,
            redactionCount: 0
        )
    }

    private static func runTraceSteps(
        trace: RunTrace,
        toolCalls: [RunTraceInspection.ToolCall],
        options: Options,
        redactionCount: inout Int
    ) -> [RunTraceInspection.Step] {
        let callsByTurn = Dictionary(grouping: toolCalls, by: { $0.turnIndex ?? -1 })
        let resultsByTurn = Dictionary(grouping: toolCalls.compactMap { call in
            call.resultTurnIndex.map { ($0, call) }
        }, by: \.0)
        return trace.turns.enumerated().map { index, turn in
            let calls = callsByTurn[index] ?? []
            let resultCalls = (resultsByTurn[index] ?? []).map(\.1)
            let redactedContent = redactedPreview(
                turn.content,
                path: "$.turns[\(index)].content",
                options: options
            )
            let content: String
            let relatedToolCallIds: [String]
            if turn.role == "tool", !resultCalls.isEmpty {
                content = resultCalls.compactMap(\.resultPreview).joined(separator: "\n")
                relatedToolCallIds = resultCalls.map(\.id)
            } else {
                content = redactedContent.text
                redactionCount += redactedContent.redactedPaths.count
                relatedToolCallIds = calls.map(\.id)
            }
            let callSuffix = calls.isEmpty
                ? ""
                : " tools=[\(calls.map(\.name).joined(separator: ","))]"
            return RunTraceInspection.Step(
                index: index,
                kind: turn.role == "tool" ? .toolResult : .turn,
                title: "\(turn.role)\(callSuffix)",
                detail: content.isEmpty ? nil : content,
                status: nil,
                timingMs: nil,
                relatedToolCallIds: relatedToolCallIds
            )
        }
    }

    private static func toolResultRecords(
        from turns: [RunTrace.Turn],
        findings: inout [RunTraceInspection.Finding]
    ) -> [String: ToolResultRecord] {
        var records: [String: ToolResultRecord] = [:]
        for (turnIndex, turn) in turns.enumerated() {
            if let toolCallId = turn.toolCallId {
                insertToolResult(
                    id: toolCallId,
                    record: ToolResultRecord(turnIndex: turnIndex, content: turn.content),
                    path: "$.turns[\(turnIndex)].toolCallId",
                    records: &records,
                    findings: &findings
                )
            }
            for (id, content) in turn.toolResults ?? [:] {
                insertToolResult(
                    id: id,
                    record: ToolResultRecord(turnIndex: turnIndex, content: content),
                    path: "$.turns[\(turnIndex)].toolResults[\(id)]",
                    records: &records,
                    findings: &findings
                )
            }
        }
        return records
    }

    private static func insertToolResult(
        id: String,
        record: ToolResultRecord,
        path: String,
        records: inout [String: ToolResultRecord],
        findings: inout [RunTraceInspection.Finding]
    ) {
        if records[id] != nil {
            findings.append(
                .init(
                    severity: .warning,
                    code: .duplicateToolResult,
                    path: path,
                    message: "duplicate result for tool call '\(id)'"
                )
            )
        }
        records[id] = record
    }

    private static func redactedPreview(
        _ raw: String,
        path: String,
        options: Options
    ) -> RedactedPreview {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return RedactedPreview(text: "", format: "empty", redactedPaths: [], parseFailed: false, lookedLikeJSON: false)
        }
        let lookedLikeJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        if let data = trimmed.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        {
            let redacted = redactJSON(parsed, path: path, options: options)
            if JSONSerialization.isValidJSONObject(redacted.value),
                let encoded = try? JSONSerialization.data(
                    withJSONObject: redacted.value,
                    options: .osaurusCanonical
                ),
                let text = String(data: encoded, encoding: .utf8)
            {
                return RedactedPreview(
                    text: preview(text, limit: options.previewLimit),
                    format: "json",
                    redactedPaths: redacted.paths,
                    parseFailed: false,
                    lookedLikeJSON: lookedLikeJSON
                )
            }
        }
        let embedded = redactEmbeddedJSONObjects(raw, path: path, options: options)
        let inline = redactInlineSecrets(embedded.text, path: path)
        return RedactedPreview(
            text: preview(inline.text, limit: options.previewLimit),
            format: lookedLikeJSON ? "invalid_json" : "text",
            redactedPaths: embedded.paths + inline.paths,
            parseFailed: lookedLikeJSON,
            lookedLikeJSON: lookedLikeJSON
        )
    }

    private static func redactJSON(
        _ value: Any,
        path: String,
        options: Options
    ) -> (value: Any, paths: [String]) {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            var paths: [String] = []
            for (key, child) in dict {
                let childPath = "\(path).\(key)"
                if isSensitiveKey(key, options: options) {
                    out[key] = "[REDACTED]"
                    paths.append(childPath)
                } else {
                    let redacted = redactJSON(child, path: childPath, options: options)
                    out[key] = redacted.value
                    paths.append(contentsOf: redacted.paths)
                }
            }
            return (out, paths)
        }
        if let array = value as? [Any] {
            var paths: [String] = []
            let out = array.enumerated().map { index, child in
                let redacted = redactJSON(child, path: "\(path)[\(index)]", options: options)
                paths.append(contentsOf: redacted.paths)
                return redacted.value
            }
            return (out, paths)
        }
        if let string = value as? String {
            let inline = redactInlineSecrets(string, path: path)
            return (inline.text, inline.paths)
        }
        return (value, [])
    }

    private static func isSensitiveKey(_ key: String, options: Options) -> Bool {
        let normalized = key.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return options.sensitiveKeyFragments.contains { matchesSensitiveKey(normalized, fragment: $0) }
    }

    private static func matchesSensitiveKey(_ normalized: String, fragment: String) -> Bool {
        guard !fragment.isEmpty else { return false }
        if normalized == fragment { return true }

        switch fragment {
        case "token":
            return normalized.hasSuffix("_token")
        case "secret":
            return normalized.hasSuffix("_secret")
        case "api_key", "apikey", "private_key", "access_token", "refresh_token", "id_token", "auth_token",
            "session_token":
            return normalized.hasSuffix("_\(fragment)")
        default:
            return normalized.hasPrefix("\(fragment)_") || normalized.hasSuffix("_\(fragment)")
        }
    }

    private static func safeSourcePath(_ sourcePath: String?) -> String? {
        guard let sourcePath, !sourcePath.isEmpty else { return sourcePath }
        guard sourcePath.hasPrefix("/") else { return sourcePath }

        let url = URL(fileURLWithPath: sourcePath)
        let fileName = url.lastPathComponent
        return fileName.isEmpty ? "(absolute path redacted)" : fileName
    }

    private static func redactInlineSecrets(_ value: String, path: String) -> (text: String, paths: [String]) {
        var redacted = value
        var matched = false
        let patterns = [
            (
                #"(?i)(["']?(?:api[_-]?key|apikey|authorization|bearer|cookie|credential|keychain|password|private_key|secret|session_token|token)["']?\s*:\s*["'])[^"']+(["'])"#,
                "$1[REDACTED]$2"
            ),
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-+/=]{8,}"#, "$1[REDACTED]"),
            (#"(?i)(api[_-]?key\s*[:=]\s*)[A-Za-z0-9._\-+/=]{8,}"#, "$1[REDACTED]"),
            (#"(?i)(token\s*[:=]\s*)[A-Za-z0-9._\-+/=]{8,}"#, "$1[REDACTED]"),
            (#"(?i)(password\s*[:=]\s*)[^\s,;]{4,}"#, "$1[REDACTED]"),
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            let next = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: template
            )
            if next != redacted {
                matched = true
                redacted = next
            }
        }
        return (redacted, matched ? [path] : [])
    }

    private static func redactEmbeddedJSONObjects(
        _ value: String,
        path: String,
        options: Options
    ) -> (text: String, paths: [String]) {
        var output = ""
        var paths: [String] = []
        var cursor = value.startIndex
        var search = value.startIndex
        var inlineIndex = 0

        while search < value.endIndex,
            let open = value[search...].firstIndex(of: "{")
        {
            guard let close = matchingJSONObjectEnd(in: value, from: open) else {
                break
            }

            output.append(contentsOf: value[cursor..<open])
            let end = value.index(after: close)
            let candidate = String(value[open..<end])
            let inlinePath = "\(path).inlineJSON[\(inlineIndex)]"
            if let data = candidate.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            {
                let redacted = redactJSON(parsed, path: inlinePath, options: options)
                if !redacted.paths.isEmpty,
                    JSONSerialization.isValidJSONObject(redacted.value),
                    let encoded = try? JSONSerialization.data(
                        withJSONObject: redacted.value,
                        options: .osaurusCanonical
                    ),
                    let text = String(data: encoded, encoding: .utf8)
                {
                    output.append(text)
                    paths.append(contentsOf: redacted.paths)
                } else {
                    output.append(candidate)
                }
                inlineIndex += 1
            } else {
                output.append(candidate)
            }
            cursor = end
            search = end
        }

        output.append(contentsOf: value[cursor...])
        return (output, paths)
    }

    private static func matchingJSONObjectEnd(in value: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < value.endIndex {
            let character = value[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func resultStatus(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return isPlainTextErrorResult(trimmed) ? "error" : "ok"
        }
        guard let dict = object as? [String: Any] else { return "ok" }
        if let success = dict["success"] as? Bool, success == false { return "error" }
        if let ok = dict["ok"] as? Bool, ok == false { return "error" }
        if let status = optionalString(dict["status"]),
            ["error", "failed", "failure"].contains(status.lowercased())
        {
            return "error"
        }
        if let type = optionalString(dict["type"]),
            ["error", "tool_error"].contains(type.lowercased())
        {
            return "error"
        }
        if let error = dict["error"] {
            if error is NSNull { return "ok" }
            if let s = error as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "ok"
            }
            return "error"
        }
        return "ok"
    }

    private static func isPlainTextErrorResult(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)^(error|failed|failure)\b"#,
            #"(?i)^tool[_\s-]?error\b"#,
            #"(?i)^exception\b"#,
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(
                in: trimmed,
                options: [],
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            ) != nil
        }
    }

    private static func failedInspection(
        sourcePath: String?,
        code: RunTraceInspection.Finding.Code,
        message: String
    ) -> RunTraceInspection {
        unknownInspection(
            sourcePath: sourcePath,
            finding: .init(severity: .error, code: code, path: "$", message: message)
        )
    }

    private static func unknownInspection(
        sourcePath: String?,
        finding: RunTraceInspection.Finding
    ) -> RunTraceInspection {
        .init(
            sourcePath: sourcePath,
            artifactKind: .unknown,
            summary: .init(
                title: "Unknown trace artifact",
                status: nil,
                runId: nil,
                agentId: nil,
                sessionId: nil,
                triggerSource: nil,
                modelId: nil,
                startedAt: nil,
                endedAt: nil,
                durationMs: nil,
                turnCount: 0,
                stepCount: 0,
                toolCallCount: 0,
                toolErrorCount: 0,
                tokensIn: nil,
                tokensOut: nil,
                costUSD: nil,
                notes: []
            ),
            steps: [],
            toolCalls: [],
            findings: [finding],
            redactionCount: 0
        )
    }

    private static func redactionFinding(count: Int) -> RunTraceInspection.Finding {
        .init(
            severity: .info,
            code: .redactionApplied,
            path: "$",
            message: "redacted \(count) sensitive field(s) or inline secret(s)"
        )
    }

    private static func filter(
        _ findings: [RunTraceInspection.Finding],
        options: Options
    ) -> [RunTraceInspection.Finding] {
        options.includeInformationalFindings
            ? findings
            : findings.filter { $0.severity != .info }
    }

    private static func requiredString(
        _ dict: [String: Any],
        key: String,
        path: String,
        findings: inout [RunTraceInspection.Finding]
    ) -> String? {
        guard let value = dict[key] else {
            findings.append(
                .init(
                    severity: .error,
                    code: .missingRequiredField,
                    path: path,
                    message: "missing required field '\(key)'"
                )
            )
            return nil
        }
        guard let string = value as? String else {
            findings.append(
                .init(
                    severity: .error,
                    code: .invalidFieldType,
                    path: path,
                    message: "field '\(key)' must be a string"
                )
            )
            return nil
        }
        return string
    }

    private static func optionalString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func numberAsInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func numberAsDouble(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func numberInToolUsagePreview(_ preview: String, key: String) -> Int? {
        let prefix = "\(key)="
        guard let range = preview.range(of: prefix) else { return nil }
        let suffix = preview[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func preview(_ value: String, limit: Int) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<end]) + "..."
    }

    private static func parseISODate(_ raw: String) -> Date? {
        isoFormatter(withFractionalSeconds: true).date(from: raw)
            ?? isoFormatter(withFractionalSeconds: false).date(from: raw)
    }

    private static func isoString(_ date: Date) -> String {
        isoFormatter(withFractionalSeconds: false).string(from: date)
    }

    private static func isoFormatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
