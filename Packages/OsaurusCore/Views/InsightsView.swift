//
//  InsightsView.swift
//  osaurus
//
//  Request/response logging view for debugging and analytics.
//

import SwiftUI

struct InsightsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var insightsService = InsightsService.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var selectedLogId: UUID?
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Filter bar
            filterBar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .opacity(hasAppeared ? 1 : 0)

            // Stats summary
            statsBar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .opacity(hasAppeared ? 1 : 0)

            // Request logs
            if insightsService.filteredLogs.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(hasAppeared ? 1 : 0)
            } else {
                logTableView
                    .opacity(hasAppeared ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .alert("Clear All Logs", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                insightsService.clear()
            }
        } message: {
            Text("Are you sure you want to clear all request logs? This action cannot be undone.")
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insights")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("Monitor API requests and performance")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Clear button
                Button(action: { showClearConfirmation = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(insightsService.logs.isEmpty ? theme.tertiaryText : theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground.opacity(0.5))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(insightsService.logs.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)

                TextField("Search path or model...", text: $insightsService.searchFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)

                if !insightsService.searchFilter.isEmpty {
                    Button(action: { insightsService.searchFilter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder.opacity(0.5), lineWidth: 1)
                    )
            )
            .frame(maxWidth: 220)

            // Method filter
            MethodFilterPills(selection: $insightsService.methodFilter)

            // Source filter
            SourceFilterPills(selection: $insightsService.sourceFilter)

            Spacer()

            // Total count
            Text("\(insightsService.totalRequestCount) requests")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        let stats = insightsService.stats

        return HStack(spacing: 0) {
            StatPill(
                icon: "arrow.left.arrow.right",
                value: "\(stats.totalRequests)",
                label: "Requests",
                color: .blue
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "checkmark.circle.fill",
                value: stats.formattedSuccessRate,
                label: "Success",
                color: .green
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "clock",
                value: stats.formattedAvgDuration,
                label: "Avg Time",
                color: .orange
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "exclamationmark.triangle.fill",
                value: "\(stats.errorCount)",
                label: "Errors",
                color: stats.errorCount > 0 ? .red : Color.gray.opacity(0.5)
            )

            // Show inference stats if there are any
            if stats.inferenceCount > 0 {
                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 16)

                StatPill(
                    icon: "bolt.fill",
                    value: "\(stats.inferenceCount)",
                    label: "Inferences",
                    color: .purple
                )

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 16)

                StatPill(
                    icon: "gauge.with.needle",
                    value: stats.formattedAvgSpeed,
                    label: "Avg Speed",
                    color: .cyan
                )
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Log Table View

    private var logTableView: some View {
        VStack(spacing: 0) {
            // Table header
            HStack(spacing: 0) {
                Text("TIME")
                    .frame(width: 70, alignment: .leading)
                Text("SOURCE")
                    .frame(width: 50, alignment: .leading)
                Text("METHOD")
                    .frame(width: 55, alignment: .leading)
                Text("PATH")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("STATUS")
                    .frame(width: 60, alignment: .center)
                Text("DURATION")
                    .frame(width: 80, alignment: .trailing)
                Text("")
                    .frame(width: 30)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText.opacity(0.7))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(theme.primaryBackground)

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Log rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(insightsService.filteredLogs) { log in
                        RequestLogRow(
                            log: log,
                            isExpanded: selectedLogId == log.id,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if selectedLogId == log.id {
                                        selectedLogId = nil
                                    } else {
                                        selectedLogId = log.id
                                    }
                                }
                            }
                        )

                        if log.id != insightsService.filteredLogs.last?.id {
                            Divider()
                                .background(theme.primaryBorder.opacity(0.2))
                                .padding(.horizontal, 24)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 48))
                .foregroundColor(theme.tertiaryText.opacity(0.3))

            Text("No Requests Yet")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)

            Text(
                "API request activity will appear here.\nTest endpoints from Server tab or connect an app via the API."
            )
            .font(.system(size: 13))
            .foregroundColor(theme.tertiaryText)
            .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

// MARK: - Method Filter Pills

private struct MethodFilterPills: View {
    @Binding var selection: MethodFilter
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MethodFilter.allCases, id: \.self) { filter in
                Button(action: { selection = filter }) {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: selection == filter ? .semibold : .medium))
                        .foregroundColor(selection == filter ? .white : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == filter ? methodColor(filter).opacity(0.8) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }

    private func methodColor(_ filter: MethodFilter) -> Color {
        switch filter {
        case .all: return .blue
        case .get: return .green
        case .post: return .blue
        }
    }
}

// MARK: - Source Filter Pills

private struct SourceFilterPills: View {
    @Binding var selection: SourceFilter
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SourceFilter.allCases, id: \.self) { filter in
                Button(action: { selection = filter }) {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: selection == filter ? .semibold : .medium))
                        .foregroundColor(selection == filter ? .white : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == filter ? Color.purple.opacity(0.8) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    @Environment(\.theme) private var theme

    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color.opacity(0.8))

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }
}

// MARK: - Request Log Row

private struct RequestLogRow: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            Button(action: onTap) {
                HStack(spacing: 0) {
                    // Timestamp
                    Text(log.formattedTimestamp)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 70, alignment: .leading)

                    // Source badge
                    SourceBadge(source: log.source)
                        .frame(width: 50, alignment: .leading)

                    // Method badge
                    MethodBadge(method: log.method)
                        .frame(width: 55, alignment: .leading)

                    // Path
                    Text(log.path)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Status code
                    HTTPStatusBadge(statusCode: log.statusCode)
                        .frame(width: 60, alignment: .center)

                    // Duration
                    Text(log.formattedDuration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 80, alignment: .trailing)

                    // Expand chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(isExpanded ? theme.secondaryBackground.opacity(0.5) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // Expanded details
            if isExpanded {
                expandedDetails
            }
        }
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                // Request panel
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Request", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }

                    if let body = log.formattedRequestBody {
                        ScrollView {
                            Text(body)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.codeBlockBackground)
                        )
                    } else {
                        Text("No request body")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.codeBlockBackground)
                            )
                    }
                }
                .frame(maxWidth: .infinity)

                // Response panel
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Response", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                        Spacer()

                        if let body = log.responseBody {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(body, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Copy response")
                        }
                    }

                    if let body = log.formattedResponseBody {
                        ScrollView {
                            Text(body)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(log.isSuccess ? theme.primaryText : theme.errorColor)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.codeBlockBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            log.isSuccess ? Color.green.opacity(0.2) : Color.red.opacity(0.2),
                                            lineWidth: 1
                                        )
                                )
                        )
                    } else {
                        Text("No response body")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.codeBlockBackground)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Inference data (only for chat endpoints)
            if log.isInference {
                inferenceDetails
            }

            // Error message
            if let error = log.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.8))

                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.08))
                )
            }

            // Tool calls
            if let toolCalls = log.toolCalls, !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tool Calls")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)

                    ForEach(toolCalls) { tool in
                        ToolCallRow(tool: tool)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground.opacity(0.3))
    }

    @ViewBuilder
    private var inferenceDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Inference Details", systemImage: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.purple.opacity(0.8))

            HStack(spacing: 24) {
                if log.model != nil {
                    DetailPill(label: "Model", value: log.shortModelName)
                }

                if let input = log.inputTokens, let output = log.outputTokens {
                    DetailPill(label: "Tokens", value: "\(input) → \(output)")
                }

                if let speed = log.tokensPerSecond, speed > 0 {
                    DetailPill(label: "Speed", value: String(format: "%.1f tok/s", speed), color: speedColor(speed))
                }

                if let temp = log.temperature {
                    DetailPill(label: "Temp", value: String(format: "%.2f", temp))
                }

                if let maxTokens = log.maxTokens {
                    DetailPill(label: "Max Tokens", value: "\(maxTokens)")
                }

                if let reason = log.finishReason {
                    DetailPill(label: "Finish", value: reason.rawValue)
                }

                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.purple.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }

    private func speedColor(_ speed: Double) -> Color {
        if speed >= 30 { return .green }
        if speed >= 15 { return .orange }
        return theme.secondaryText
    }
}

// MARK: - Detail Pill

private struct DetailPill: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(color ?? theme.primaryText)
        }
    }
}

// MARK: - Method Badge

private struct MethodBadge: View {
    let method: String

    var body: some View {
        Text(method)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(methodColor.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(methodColor.opacity(0.15))
            )
    }

    private var methodColor: Color {
        switch method {
        case "GET": return .green
        case "POST": return .blue
        case "PUT": return .orange
        case "DELETE": return .red
        default: return .gray
        }
    }
}

// MARK: - HTTP Status Badge

private struct HTTPStatusBadge: View {
    let statusCode: Int

    var body: some View {
        Text("\(statusCode)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(statusColor)
            )
    }

    private var statusColor: Color {
        if statusCode >= 200 && statusCode < 300 {
            return .green
        } else if statusCode >= 400 && statusCode < 500 {
            return .orange
        } else if statusCode >= 500 {
            return .red
        }
        return .gray
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let source: RequestSource

    var body: some View {
        Text(source.shortName)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(badgeColor.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(badgeColor.opacity(0.15))
            )
    }

    private var badgeColor: Color {
        switch source {
        case .chatUI: return .pink
        case .httpAPI: return .blue
        }
    }
}

extension RequestSource {
    var shortName: String {
        switch self {
        case .chatUI: return "Chat"
        case .httpAPI: return "HTTP"
        }
    }
}

// MARK: - Tool Call Row

private struct ToolCallRow: View {
    @Environment(\.theme) private var theme

    let tool: ToolCallLog

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(tool.isError ? .red.opacity(0.7) : .green.opacity(0.7))

            Text(tool.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)

            if !tool.arguments.isEmpty && tool.arguments != "{}" {
                Text(tool.arguments)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer()

            if let duration = tool.durationMs {
                Text(String(format: "%.0fms", duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground.opacity(0.3))
        )
    }
}

// MARK: - Preview

#Preview {
    InsightsView()
        .frame(width: 900, height: 600)
}
