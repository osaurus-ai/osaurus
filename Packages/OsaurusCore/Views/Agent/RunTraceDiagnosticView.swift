//
//  RunTraceDiagnosticView.swift
//  osaurus
//
//  Compact SwiftUI surface for a RunTraceInspection. It intentionally renders
//  the inspector's redacted report model, not raw trace JSON.
//

import AppKit
import SwiftUI

public struct RunTraceDiagnosticView: View {
    @Environment(\.theme) private var theme

    private let inspection: RunTraceInspection

    public init(inspection: RunTraceInspection) {
        self.inspection = inspection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().foregroundColor(theme.primaryBorder)
            summaryStrip
            if !inspection.findings.isEmpty {
                Divider().foregroundColor(theme.primaryBorder)
                findingsSection
            }
            Divider().foregroundColor(theme.primaryBorder)
            toolCallsSection
            Divider().foregroundColor(theme.primaryBorder)
            stepsSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: inspection.hasErrors ? "exclamationmark.triangle.fill" : "list.bullet.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(inspection.hasErrors ? .orange : theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trace Inspector", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(inspection.summary.title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                copy(inspection.markdownReport())
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .localizedHelp("Copy Markdown report")

            Button {
                if let data = try? inspection.jsonReport(prettyPrinted: true),
                    let json = String(data: data, encoding: .utf8)
                {
                    copy(json)
                }
            } label: {
                Image(systemName: "curlybraces")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .localizedHelp("Copy JSON report")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var summaryStrip: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: 10, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            metric("Status", inspection.summary.status ?? "n/a")
            metric("Kind", inspection.artifactKind.rawValue)
            metric("Turns", "\(inspection.summary.turnCount)")
            metric("Steps", "\(inspection.summary.stepCount)")
            metric("Tools", "\(inspection.summary.toolCallCount)")
            metric("Errors", "\(inspection.summary.toolErrorCount)")
            if let duration = inspection.summary.durationMs {
                metric("Duration", durationLabel(duration))
            }
            if let tokensIn = inspection.summary.tokensIn {
                metric("In", "\(tokensIn)")
            }
            if let tokensOut = inspection.summary.tokensOut {
                metric("Out", "\(tokensOut)")
            }
            if inspection.redactionCount > 0 {
                metric("Redacted", "\(inspection.redactionCount)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label, bundle: .module)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var findingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Findings")
            ForEach(Array(inspection.findings.enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(color(for: finding.severity))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(finding.severity.rawValue.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(color(for: finding.severity))
                            Text(finding.code.rawValue)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                            Text(finding.path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }
                        Text(finding.message)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private var toolCallsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Tool Calls")
            if inspection.toolCalls.isEmpty {
                emptyLine("No tool calls recorded.")
            } else {
                ForEach(Array(inspection.toolCalls.enumerated()), id: \.element.index) { _, call in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text("#\(call.index)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                            Text(call.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            statusBadge(call.resultStatus ?? "n/a")
                        }
                        diagnosticText("args", call.argumentsPreview)
                        if let result = call.resultPreview {
                            diagnosticText("result", result)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
                }
            }
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Steps")
            if inspection.steps.isEmpty {
                emptyLine("No steps recorded.")
            } else {
                ForEach(Array(inspection.steps.enumerated()), id: \.element.index) { _, step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text("\(step.index)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .frame(width: 22, alignment: .leading)
                            Text(step.kind.rawValue)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.accentColor)
                            Text(step.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            if let timingMs = step.timingMs {
                                Text(durationLabel(timingMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }
                        if let detail = step.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
                }
            }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func emptyLine(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }

    private func diagnosticText(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(status == "error" ? .red : theme.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.tertiaryBackground)
            )
    }

    private func color(for severity: RunTraceInspection.Finding.Severity) -> Color {
        switch severity {
        case .info: return theme.accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func durationLabel(_ ms: Double) -> String {
        if ms < 1_000 { return String(format: "%.0fms", ms) }
        if ms < 60_000 { return String(format: "%.1fs", ms / 1_000) }
        let seconds = Int(ms.rounded() / 1_000)
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
