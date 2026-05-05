//
//  InsightsDetailPane.swift
//  osaurus
//
//  Pushed full-width detail view for the Insights screen. Surfaces the
//  formatted prompt (system / user / assistant / tool messages + tools),
//  the full pretty request and response JSON, and the model parameters
//  for a selected RequestLog so users can self-diagnose what was sent
//  to the model. Pop is invoked via the back button or Escape key.
//

import AppKit
import SwiftUI

// MARK: - Detail View

struct InsightsDetailPane: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    let onBack: () -> Void

    @State private var selectedTab: DetailTab = .prompt

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(theme.primaryBorder.opacity(0.3))
            if log.isPluginLog {
                pluginBody
            } else {
                tabPicker
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                tabContent
            }
        }
        .background(theme.primaryBackground)
        .id(log.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back to Logs", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground.opacity(0.5))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if log.formattedRequestBody != nil {
                    headerActionButton(
                        title: Text("Copy Request", bundle: .module),
                        icon: "doc.on.doc",
                        helpText: Text("Copy request JSON", bundle: .module),
                        action: copyRequest
                    )
                }

                if log.formattedResponseBody != nil {
                    headerActionButton(
                        title: Text("Copy Response", bundle: .module),
                        icon: "arrow.down.doc",
                        helpText: Text("Copy response", bundle: .module),
                        action: copyResponse
                    )
                }
            }

            HStack(alignment: .center, spacing: 10) {
                MethodBadgeCompact(method: log.method)
                HTTPStatusBadgeCompact(statusCode: log.statusCode)

                Text(log.path)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(log.formattedDuration)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            HStack(spacing: 8) {
                metaPill(icon: "clock", text: Text(verbatim: log.formattedTimestamp))
                metaPill(icon: sourceIcon(log.source), text: Text(verbatim: log.source.displayName))
                if let pluginId = log.pluginId {
                    metaPill(
                        icon: "puzzlepiece.extension.fill",
                        text: Text(verbatim: pluginId),
                        tint: .teal
                    )
                }
                if let model = log.model {
                    metaPill(icon: "cpu", text: Text(verbatim: log.shortModelName), tint: .purple)
                        .help(Text(verbatim: model))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground.opacity(0.4))
    }

    private func headerActionButton(
        title: Text,
        icon: String,
        helpText: Text,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                title
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground.opacity(0.5))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help(helpText)
    }

    private func sourceIcon(_ source: RequestSource) -> String {
        switch source {
        case .chatUI: return "bubble.left.and.bubble.right.fill"
        case .httpAPI: return "network"
        case .plugin: return "puzzlepiece.extension.fill"
        }
    }

    private func metaPill(icon: String, text: Text, tint: Color? = nil) -> some View {
        let color = tint ?? theme.tertiaryText
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            text
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(color.opacity(tint == nil ? 1.0 : 0.9))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(color.opacity(tint == nil ? 0.08 : 0.12))
        )
        // Lock the pill to its intrinsic size so multi-pill HStacks (with a
        // trailing Spacer) never compress the text. Without this, pills
        // like "HTTP API" can get clipped to "HTT…" when the available
        // width is tight (narrow window or many pills present).
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Tabs

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        tab.label
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                    }
                    .foregroundColor(selectedTab == tab ? .white : theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selectedTab == tab ? theme.accentColor.opacity(0.85) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(theme.tertiaryBackground.opacity(0.4))
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch selectedTab {
            case .prompt: PromptTab(log: log)
            case .request: BodyTab(bodyText: log.formattedRequestBody, kind: .request, log: log)
            case .response: BodyTab(bodyText: log.formattedResponseBody, kind: .response, log: log)
            case .params: ParamsTab(log: log)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Plugin body

    @ViewBuilder
    private var pluginBody: some View {
        let level = PluginLogLevel(statusCode: log.statusCode)
        let levelColor = level.color(theme: theme)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: level.icon)
                        .font(.system(size: 12))
                        .foregroundColor(levelColor)
                    Text(level.label, bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(levelColor)
                    Spacer()
                }
                if let body = log.requestBody {
                    Text(body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(levelColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(levelColor.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(levelColor.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Copy actions

    private func copyRequest() {
        guard let body = log.formattedRequestBody else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private func copyResponse() {
        guard let body = log.formattedResponseBody else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }
}

// MARK: - Tab Enum

private enum DetailTab: CaseIterable {
    case prompt
    case request
    case response
    case params

    var icon: String {
        switch self {
        case .prompt: return "text.bubble"
        case .request: return "arrow.up.circle"
        case .response: return "arrow.down.circle"
        case .params: return "slider.horizontal.3"
        }
    }

    @ViewBuilder
    var label: some View {
        switch self {
        case .prompt: Text("Prompt", bundle: .module)
        case .request: Text("Request", bundle: .module)
        case .response: Text("Response", bundle: .module)
        case .params: Text("Params", bundle: .module)
        }
    }
}

// MARK: - Plugin Log Level

/// Visual treatment for plugin console logs. The status code on a plugin
/// row is overloaded as a severity (200=info, 299=warn, 500=error) to
/// avoid adding a new field to `RequestLog`; this enum centralizes that
/// mapping plus the matching color/icon/label.
private enum PluginLogLevel {
    case info, warning, error

    init(statusCode: Int) {
        switch statusCode {
        case 500: self = .error
        case 299: self = .warning
        default: self = .info
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .info: return "Log"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    /// Resolved per-theme color. `info` defers to the theme so it adapts
    /// to dark/light mode rather than baking in a fixed gray.
    func color(theme: ThemeProtocol) -> Color {
        switch self {
        case .info: return theme.primaryText
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Prompt Tab

private struct PromptTab: View {
    @Environment(\.theme) private var theme

    let log: RequestLog

    private var parsedRequest: ParsedChatRequest? {
        ParsedChatRequest.parse(log.requestBody)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let parsed = parsedRequest {
                    if parsed.messages.isEmpty {
                        emptyState(text: Text("No messages in request", bundle: .module))
                    } else {
                        ForEach(Array(parsed.messages.enumerated()), id: \.offset) { _, msg in
                            MessageCard(message: msg)
                        }
                    }

                    if !parsed.tools.isEmpty {
                        toolsSection(parsed.tools)
                    }
                } else if log.requestBody == nil {
                    emptyState(text: Text("No request captured for this row", bundle: .module))
                } else {
                    emptyState(text: Text("Request body is not a chat completion", bundle: .module))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func emptyState(text: Text) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
                text
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    private func toolsSection(_ tools: [ParsedTool]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.teal.opacity(0.8))
                Text("Tools (\(tools.count))", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    ToolCard(tool: tool)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Message Role Style

/// Visual + display attributes for a chat message role. Folds three
/// previously-separate switches (`roleColor`, `roleIcon`, `roleDisplay`)
/// into a single source of truth so adding a new role only touches one
/// site.
private enum MessageRoleStyle {
    case system, user, assistant, tool, developer
    case other(String)

    init(rawRole: String) {
        switch rawRole.lowercased() {
        case "system": self = .system
        case "user": self = .user
        case "assistant": self = .assistant
        case "tool": self = .tool
        case "developer": self = .developer
        default: self = .other(rawRole)
        }
    }

    var color: Color {
        switch self {
        case .system: return .purple
        case .user: return .blue
        case .assistant: return .green
        case .tool: return .teal
        case .developer: return .indigo
        case .other: return .gray
        }
    }

    var icon: String {
        switch self {
        case .system: return "gearshape"
        case .user: return "person.fill"
        case .assistant: return "sparkle"
        case .tool: return "wrench.and.screwdriver.fill"
        case .developer: return "hammer"
        case .other: return "circle"
        }
    }

    var displayName: String {
        switch self {
        case .system: return L("System")
        case .user: return L("User")
        case .assistant: return L("Assistant")
        case .tool: return L("Tool")
        case .developer: return L("Developer")
        case .other(let raw): return raw.capitalized
        }
    }
}

// MARK: - Message Card

private struct MessageCard: View {
    @Environment(\.theme) private var theme

    let message: ParsedMessage

    @State private var isExpanded: Bool = true

    private var role: MessageRoleStyle { MessageRoleStyle(rawRole: message.role) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            if isExpanded {
                cardContent
                if !message.toolCalls.isEmpty {
                    toolCallsList
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(role.color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(role.color.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            roleBadge
            Spacer()
            if let toolCallId = message.toolCallId {
                Text(verbatim: "call: \(toolCallId)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            Button(action: copyContent) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
            .help(Text("Copy", bundle: .module))

            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if let content = message.content, !content.isEmpty {
            Text(content)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if message.toolCalls.isEmpty {
            Text("(empty)", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var toolCallsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, call in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundColor(.teal.opacity(0.8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                        Text(call.arguments)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.teal.opacity(0.06))
                )
            }
        }
    }

    private var roleBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: role.icon)
                .font(.system(size: 9, weight: .bold))
            Text(role.displayName)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(role.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(role.color.opacity(0.15)))
    }

    private func copyContent() {
        let payload: String
        if let content = message.content, !content.isEmpty {
            payload = content
        } else if !message.toolCalls.isEmpty {
            payload = message.toolCalls
                .map { "\($0.name)(\($0.arguments))" }
                .joined(separator: "\n")
        } else {
            payload = ""
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }
}

// MARK: - Tool Card

private struct ToolCard: View {
    @Environment(\.theme) private var theme

    let tool: ParsedTool

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(tool.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    if let desc = tool.description, !desc.isEmpty {
                        Text("·")
                            .foregroundColor(theme.tertiaryText)
                        Text(desc)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded, let params = tool.parametersJSON, !params.isEmpty {
                Text(params)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.codeBlockBackground)
                    )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.teal.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.teal.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - Body Tab

private struct BodyTab: View {
    @Environment(\.theme) private var theme

    enum Kind {
        case request, response

        var emptyIcon: String {
            self == .request ? "arrow.up.circle" : "arrow.down.circle"
        }

        @ViewBuilder
        var emptyMessage: some View {
            switch self {
            case .request: Text("No request body captured", bundle: .module)
            case .response: Text("No response body captured", bundle: .module)
            }
        }
    }

    let bodyText: String?
    let kind: Kind
    let log: RequestLog

    var body: some View {
        ScrollView {
            if let text = bodyText {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.codeBlockBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(borderColor, lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: kind.emptyIcon)
                    .font(.system(size: 28))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
                kind.emptyMessage
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.vertical, 40)
            Spacer()
        }
    }

    private var textColor: Color {
        switch kind {
        case .request: return theme.primaryText
        case .response: return log.isSuccess ? theme.primaryText : theme.errorColor
        }
    }

    private var borderColor: Color {
        switch kind {
        case .request: return theme.primaryBorder.opacity(0.2)
        case .response: return log.isSuccess ? Color.green.opacity(0.2) : Color.red.opacity(0.2)
        }
    }
}

// MARK: - Params Tab

private struct ParamsTab: View {
    @Environment(\.theme) private var theme

    let log: RequestLog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if log.isInference {
                    inferenceSection
                }
                metadataSection
                if let toolCalls = log.toolCalls, !toolCalls.isEmpty {
                    toolCallsSection(toolCalls)
                }
                if let error = log.errorMessage {
                    errorSection(error)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "bolt.fill", text: Text("Inference Details", bundle: .module), color: .purple)

            VStack(spacing: 0) {
                if log.model != nil {
                    DetailRow(label: Text("Model", bundle: .module), value: log.shortModelName)
                }
                if let input = log.inputTokens, let output = log.outputTokens {
                    DetailRow(label: Text("Tokens", bundle: .module), value: "\(input) → \(output)")
                }
                if let speed = log.tokensPerSecond, speed > 0 {
                    DetailRow(
                        label: Text("Speed", bundle: .module),
                        value: String(format: "%.1f tok/s", speed),
                        valueColor: speedColor(speed)
                    )
                }
                if let temp = log.temperature {
                    DetailRow(label: Text("Temperature", bundle: .module), value: String(format: "%.2f", temp))
                }
                if let maxTokens = log.maxTokens {
                    DetailRow(label: Text("Max Tokens", bundle: .module), value: "\(maxTokens)")
                }
                if let reason = log.finishReason {
                    DetailRow(label: Text("Finish Reason", bundle: .module), value: reason.rawValue)
                }
            }
            .padding(10)
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

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "info.circle", text: Text("Request", bundle: .module), color: theme.secondaryText)

            VStack(spacing: 0) {
                DetailRow(label: Text("Source", bundle: .module), value: log.source.displayName)
                DetailRow(label: Text("Method", bundle: .module), value: log.method)
                DetailRow(label: Text("Path", bundle: .module), value: log.path)
                DetailRow(label: Text("Status", bundle: .module), value: "\(log.statusCode)")
                DetailRow(label: Text("Duration", bundle: .module), value: log.formattedDuration)
                if let userAgent = log.userAgent {
                    DetailRow(label: Text("User Agent", bundle: .module), value: userAgent)
                }
                if let pluginId = log.pluginId {
                    DetailRow(label: Text("Plugin", bundle: .module), value: pluginId)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.primaryBorder.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    private func toolCallsSection(_ toolCalls: [ToolCallLog]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "wrench.and.screwdriver.fill", text: Text("Tool Calls", bundle: .module), color: .teal)

            VStack(spacing: 6) {
                ForEach(toolCalls) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(tool.isError ? .red.opacity(0.7) : .green.opacity(0.7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                            if !tool.arguments.isEmpty && tool.arguments != "{}" {
                                Text(tool.arguments)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Spacer()
                        if let duration = tool.durationMs {
                            Text(String(format: "%.0fms", duration))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tertiaryBackground.opacity(0.3))
                    )
                }
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "exclamationmark.triangle.fill", text: Text("Error", bundle: .module), color: .red)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.red.opacity(0.8))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                )
        }
    }

    private func sectionHeader(icon: String, text: Text, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            text
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
    }

    private func speedColor(_ speed: Double) -> Color {
        if speed >= 30 { return .green }
        if speed >= 15 { return .orange }
        return theme.secondaryText
    }
}

// MARK: - Detail Row

private struct DetailRow: View {
    @Environment(\.theme) private var theme

    let label: Text
    let value: String
    var valueColor: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(valueColor ?? theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Compact Header Badges

private struct MethodBadgeCompact: View {
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
        case "LOG": return .teal
        default: return .gray
        }
    }
}

private struct HTTPStatusBadgeCompact: View {
    let statusCode: Int

    var body: some View {
        Text("\(statusCode)")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(statusColor)
            )
    }

    private var statusColor: Color {
        if statusCode >= 200 && statusCode < 300 { return .green }
        if statusCode >= 400 && statusCode < 500 { return .orange }
        if statusCode >= 500 { return .red }
        return .gray
    }
}

// MARK: - Lightweight Chat Request Parser

/// Best-effort parse of the request body into messages + tools.
/// Tolerates partial / non-OpenAI shapes (e.g. plain text bodies, raw
/// JSON without `messages`) and surfaces what it can rather than failing.
struct ParsedChatRequest {
    let messages: [ParsedMessage]
    let tools: [ParsedTool]

    static func parse(_ body: String?) -> ParsedChatRequest? {
        guard let body = body, let data = body.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let messages = (obj["messages"] as? [[String: Any]] ?? []).map(ParsedMessage.init(json:))
        let tools = (obj["tools"] as? [[String: Any]] ?? []).compactMap(ParsedTool.init(json:))

        if messages.isEmpty && tools.isEmpty {
            return nil
        }
        return ParsedChatRequest(messages: messages, tools: tools)
    }
}

struct ParsedMessage {
    let role: String
    let content: String?
    let toolCalls: [ParsedMessageToolCall]
    let toolCallId: String?

    init(json: [String: Any]) {
        self.role = (json["role"] as? String) ?? "?"
        self.toolCallId = json["tool_call_id"] as? String
        if let stringContent = json["content"] as? String {
            self.content = stringContent
        } else if let parts = json["content"] as? [[String: Any]] {
            // OpenAI-style array-of-parts: stitch text segments together
            // and surface non-text parts as a [type: …] marker so the user
            // still sees that an image / audio / video was attached.
            var assembled: [String] = []
            for part in parts {
                if let type = part["type"] as? String {
                    switch type {
                    case "text":
                        if let txt = part["text"] as? String { assembled.append(txt) }
                    case "image_url":
                        let detail = (part["image_url"] as? [String: Any])?["detail"] as? String
                        let label = detail.map { " (\($0))" } ?? ""
                        assembled.append("[image\(label)]")
                    case "input_audio":
                        let format = (part["input_audio"] as? [String: Any])?["format"] as? String ?? "?"
                        assembled.append("[audio:\(format)]")
                    case "video_url":
                        assembled.append("[video]")
                    default:
                        assembled.append("[\(type)]")
                    }
                }
            }
            self.content = assembled.isEmpty ? nil : assembled.joined(separator: "\n")
        } else {
            self.content = nil
        }

        if let calls = json["tool_calls"] as? [[String: Any]] {
            self.toolCalls = calls.compactMap(ParsedMessageToolCall.init(json:))
        } else {
            self.toolCalls = []
        }
    }
}

struct ParsedMessageToolCall {
    let name: String
    let arguments: String

    init?(json: [String: Any]) {
        guard let function = json["function"] as? [String: Any],
            let name = function["name"] as? String
        else { return nil }
        self.name = name
        self.arguments = (function["arguments"] as? String) ?? "{}"
    }
}

struct ParsedTool {
    let name: String
    let description: String?
    let parametersJSON: String?

    init?(json: [String: Any]) {
        // OpenAI shape: { "type": "function", "function": { "name", "description", "parameters" } }
        guard let function = json["function"] as? [String: Any],
            let name = function["name"] as? String
        else { return nil }
        self.name = name
        self.description = function["description"] as? String
        self.parametersJSON = function["parameters"].flatMap { Self.prettyJSON($0) }
    }

    private static func prettyJSON(_ value: Any) -> String? {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
