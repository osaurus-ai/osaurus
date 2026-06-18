//
//  MCPLocalProviderDiagnostics.swift
//  osaurus
//
//  Extra diagnostics rows for local MCP probes and capture-policy state.
//

import Foundation

public enum MCPLocalProviderDiagnostics {
    public static func augment(
        report: ProviderDiagnosticReport,
        provider: MCPProvider,
        healthSnapshot: MCPProviderHealthSnapshot?,
        captureDecision: MCPCapturePolicyDecision = MCPCaptureCapabilityPolicy.defaultScreenshotDecision
    ) -> ProviderDiagnosticReport {
        var rows = report.rows
        rows.append(healthSnapshotRow(provider: provider, snapshot: healthSnapshot))
        rows.append(capturePolicyRow(captureDecision))
        return ProviderDiagnosticReport(
            title: report.title,
            subtitle: report.subtitle,
            rows: rows
        )
    }

    public static func healthSnapshotRow(
        provider: MCPProvider,
        snapshot: MCPProviderHealthSnapshot?
    ) -> ProviderDiagnosticRow {
        guard let snapshot else {
            return ProviderDiagnosticRow(
                id: "local-health",
                title: L("Last probe"),
                value: L("Not run"),
                severity: .info,
                detail: provider.transport == .stdio
                    ? L("Use Test to launch initialize/listTools and record a health snapshot.")
                    : L("Use Test to run HTTP/SSE initialize/listTools and record a health snapshot.")
            )
        }

        let result = snapshot.lastProbe
        return ProviderDiagnosticRow(
            id: "local-health",
            title: L("Last probe"),
            value: result.reasonCode.rawValue,
            severity: result.succeeded ? .ok : .blocked,
            detail: result.succeeded
                ? L("\(result.toolCount) tool(s) discovered via \(snapshot.transportSummary).")
                : result.redactedMessage,
            action: result.redactedAction
        )
    }

    public static func capturePolicyRow(
        _ decision: MCPCapturePolicyDecision
    ) -> ProviderDiagnosticRow {
        ProviderDiagnosticRow(
            id: "capture-policy",
            title: L("Capture policy"),
            value: decision.allowed ? L("Allowed") : (decision.denialReason?.rawValue ?? L("Denied")),
            severity: decision.allowed ? .ok : .info,
            detail: decision.message,
            action: decision.action
        )
    }
}
