//
//  InsightsView.swift
//  osaurus
//
//  In-memory inference logging view for debugging and analytics.
//

import SwiftUI

struct InsightsView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var insightsService = InsightsService.shared
    @Environment(\.theme) private var theme

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

            // Inference logs
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
            Text("Are you sure you want to clear all inference logs? This action cannot be undone.")
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .center, spacing: 16) {
            // Icon and title
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.7), Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)

                    Text("Monitor model inference and performance")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder.opacity(0.5))
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 16) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)

                TextField("Search models...", text: $insightsService.modelFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)

                if !insightsService.modelFilter.isEmpty {
                    Button(action: { insightsService.modelFilter = "" }) {
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

            // Custom segmented control
            SourceFilterPills(selection: $insightsService.sourceFilter)

            Spacer()

            // Total count
            Text("\(insightsService.totalInferenceCount) inferences")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        let stats = insightsService.stats

        return HStack(spacing: 0) {
            StatPill(
                icon: "bolt.fill",
                value: "\(stats.totalInferences)",
                label: "Inferences",
                color: .blue
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "arrow.right",
                value: formatTokenCount(stats.totalInputTokens),
                label: "Input",
                color: .cyan
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "arrow.left",
                value: formatTokenCount(stats.totalOutputTokens),
                label: "Output",
                color: .green
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "gauge.with.needle",
                value: stats.formattedAvgSpeed,
                label: "Avg Speed",
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

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }

    // MARK: - Log Table View

    private var logTableView: some View {
        VStack(spacing: 0) {
            // Table header
            HStack(spacing: 0) {
                Text("TIME")
                    .frame(width: 70, alignment: .leading)
                Text("SOURCE")
                    .frame(width: 60, alignment: .leading)
                Text("MODEL")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("TOKENS")
                    .frame(width: 90, alignment: .center)
                Text("SPEED")
                    .frame(width: 80, alignment: .trailing)
                Text("DURATION")
                    .frame(width: 70, alignment: .trailing)
                Text("")
                    .frame(width: 50)
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
                        InferenceLogRow(
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
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 48))
                .foregroundColor(theme.tertiaryText.opacity(0.3))

            Text("No Inferences Yet")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)

            Text("Model inference activity will appear here.\nUse the Chat UI or connect an app via the API.")
                .font(.system(size: 13))
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .padding(40)
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
                    Text(filter.shortLabel)
                        .font(.system(size: 11, weight: selection == filter ? .semibold : .medium))
                        .foregroundColor(selection == filter ? .white : theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == filter ? Color.blue.opacity(0.8) : Color.clear)
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

extension SourceFilter {
    var shortLabel: String {
        switch self {
        case .all: return "All"
        case .chatUI: return "Chat"
        case .httpAPI: return "HTTP"
        case .sdk: return "SDK"
        }
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

// MARK: - Inference Log Row

private struct InferenceLogRow: View {
    @Environment(\.theme) private var theme

    let log: InferenceLog
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
                        .frame(width: 60, alignment: .leading)

                    // Model name
                    Text(log.shortModelName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Token counts
                    HStack(spacing: 3) {
                        Text("\(log.inputTokens)")
                            .foregroundColor(theme.tertiaryText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(theme.tertiaryText.opacity(0.5))
                        Text("\(log.outputTokens)")
                            .foregroundColor(theme.secondaryText)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90, alignment: .center)

                    // Speed
                    Text(log.formattedSpeed)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(speedColor(log.tokensPerSecond))
                        .frame(width: 80, alignment: .trailing)

                    // Duration
                    Text(log.formattedDuration)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 70, alignment: .trailing)

                    // Status and expand
                    HStack(spacing: 8) {
                        statusIndicator(log.finishReason)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.tertiaryText.opacity(0.5))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .frame(width: 50, alignment: .trailing)
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
        VStack(alignment: .leading, spacing: 12) {
            // Details grid
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(label: "Model", value: log.model)
                    DetailRow(label: "Temperature", value: String(format: "%.2f", log.temperature))
                    DetailRow(label: "Max Tokens", value: "\(log.maxTokens)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    DetailRow(label: "Input Tokens", value: "\(log.inputTokens)")
                    DetailRow(label: "Output Tokens", value: "\(log.outputTokens)")
                    DetailRow(label: "Finish Reason", value: log.finishReason.rawValue)
                }

                Spacer()
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
        .padding(.top, 4)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground.opacity(0.3))
    }

    private func speedColor(_ speed: Double) -> Color {
        if speed >= 30 { return .green }
        if speed >= 15 { return .orange }
        if speed > 0 { return theme.secondaryText }
        return theme.tertiaryText
    }

    @ViewBuilder
    private func statusIndicator(_ reason: InferenceLog.FinishReason) -> some View {
        switch reason {
        case .stop:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green.opacity(0.8))
        case .length:
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 12))
                .foregroundColor(.orange.opacity(0.8))
        case .toolCalls:
            Image(systemName: "wrench.fill")
                .font(.system(size: 11))
                .foregroundColor(.blue.opacity(0.8))
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red.opacity(0.8))
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange.opacity(0.8))
        }
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let source: InferenceSource

    var body: some View {
        Text(source.shortName)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(badgeColor.opacity(0.9))
            .padding(.horizontal, 6)
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
        case .sdk: return .purple
        }
    }
}

extension InferenceSource {
    var shortName: String {
        switch self {
        case .chatUI: return "Chat"
        case .httpAPI: return "HTTP"
        case .sdk: return "SDK"
        }
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 80, alignment: .trailing)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
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
