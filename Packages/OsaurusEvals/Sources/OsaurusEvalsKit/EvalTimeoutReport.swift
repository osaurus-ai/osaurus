//
//  EvalTimeoutReport.swift
//  OsaurusEvalsKit
//
//  Helpers for bounded CLI startup. Kept in the kit so the executable's
//  process watchdog can prebuild a JSON report before entering Core
//  bootstrap code that may block the main actor.
//

import Foundation

public enum EvalTimeoutReport {
    public static let localDefaultStartupTimeoutSeconds: Double = 120
    public static let ciDefaultStartupTimeoutSeconds: Double = 30

    public static func configuredStartupTimeoutSeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double? {
        if let raw = environment["OSAURUS_EVALS_STARTUP_TIMEOUT_SECONDS"]
            ?? environment["OSAURUS_EVALS_TIMEOUT_SECONDS"],
            let parsed = parseTimeoutSeconds(raw)
        {
            return parsed > 0 ? parsed : nil
        }

        if isTruthyCI(environment["CI"]) {
            return ciDefaultStartupTimeoutSeconds
        }

        return localDefaultStartupTimeoutSeconds
    }

    public static func parseTimeoutSeconds(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return seconds
    }

    public static func makeReport(
        suite: EvalSuite,
        modelId: String,
        filter: String?,
        timeoutSeconds: Double,
        phase: String,
        startedAt: String? = nil
    ) -> EvalReport {
        let startedAt = startedAt ?? isoNow()
        let note = "timeout: \(phase) exceeded \(formatSeconds(timeoutSeconds)); eval aborted before case execution"
        var rows = suite.decodeFailures.map { failure in
            EvalCaseReport.terminal(
                id: failure.filename,
                label: failure.filename,
                domain: "(unknown)",
                outcome: .errored,
                notes: ["decode failure: \(failure.error)", note],
                modelId: modelId
            )
        }

        for testCase in suite.cases where shouldInclude(testCase, filter: filter) {
            rows.append(
                EvalCaseReport(
                    id: testCase.id,
                    label: testCase.label ?? testCase.id,
                    domain: testCase.domain,
                    query: testCase.query,
                    outcome: .errored,
                    capabilitySearch: nil,
                    notes: [note],
                    modelId: modelId,
                    latencyMs: nil
                )
            )
        }

        return EvalReport(modelId: modelId, startedAt: startedAt, cases: rows)
    }

    public static func formatSeconds(_ seconds: Double) -> String {
        if seconds.rounded(.towardZero) == seconds {
            return "\(Int(seconds))s"
        }
        return String(format: "%.3gs", seconds)
    }

    private static func shouldInclude(_ testCase: EvalCase, filter: String?) -> Bool {
        guard let filter else { return true }
        return testCase.id.contains(filter)
    }

    private static func isTruthyCI(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
