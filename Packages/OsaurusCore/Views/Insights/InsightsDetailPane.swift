//
//  InsightsDetailPane.swift
//  osaurus
//
//  Detail view for one Insights row. Shown beside the list as a side
//  inspector at wide widths, or pushed full-width (with Back / Escape) in
//  narrow windows. Overview answers what happened, where the data went and
//  who drove it with progressive disclosure; Prompt shows the parsed chat
//  messages; Raw holds the pretty request / response bodies (local and
//  wire) for self-diagnosis.
//

import AppKit
import SwiftUI

/// How the pane is being shown; drives Back vs. Close and horizontal metrics.
enum InsightsDetailPresentation: Equatable {
    /// Replaces the list; a Back button (and Escape) returns.
    case page
    /// Sits beside the list; a close button dismisses it.
    case inspector
}

// MARK: - Detail View

struct InsightsDetailPane: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    var presentation: InsightsDetailPresentation = .page
    let onBack: () -> Void

    @State private var selectedTab: DetailTab = .overview

    private var hInset: CGFloat { presentation == .inspector ? 20 : 24 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(theme.primaryBorder.opacity(0.3))
            if log.isPluginLog {
                pluginBody
            } else {
                if availableTabs.count > 1 {
                    tabPicker
                        .padding(.horizontal, hInset)
                        .padding(.top, 12)
                }
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
                if presentation == .page {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Back", bundle: .module)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.5)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                }

                Spacer()

                copyMenu

                if presentation == .inspector {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.5)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(Text("Close", bundle: .module))
                }
            }

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(log.category.tint.opacity(0.14))
                    Image(systemName: log.category.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(log.category.tint.opacity(0.9))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(log.title)
                        .font(.system(size: 16, weight: .semibold, design: usesMonospacedTitle ? .monospaced : .default))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if log.category != .system {
                        Text(verbatim: "\(log.method) \(Self.abbreviatedPath(log.path))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(Text(verbatim: log.path))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if log.isError {
                    failurePill
                }
            }
        }
        .padding(.horizontal, hInset)
        .padding(.vertical, 14)
    }

    /// `Category · time · duration · Source · Agent` — only the parts that exist.
    private var subtitle: String {
        var parts = [log.category.displayName, log.formattedTimestamp, log.formattedDuration, log.source.displayName]
        if let agent = log.agentName { parts.append(agent) }
        if let plugin = log.pluginId { parts.append(plugin) }
        if log.locality == .remote { parts.append(log.destinationDisplay) }
        return parts.joined(separator: " · ")
    }

    private var usesMonospacedTitle: Bool {
        switch log.category {
        case .inboundAPI, .routerControl, .mcpToolCall, .pluginCall, .urlExtract: return true
        default: return false
        }
    }

    private var failurePill: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: log.statusCode == 200 ? L("failed") : "\(log.statusCode) · \(L("failed"))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(theme.errorColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.errorColor.opacity(0.12)))
        .fixedSize()
    }

    /// Single `Copy ▾` menu listing every captured body. Hidden when nothing
    /// was captured (metadata-only rows).
    @ViewBuilder
    private var copyMenu: some View {
        let localReq = log.formattedRequestBody
        let wireReq = log.formattedWireRequestBody
        let localRes = log.formattedResponseBody
        let wireRes = log.formattedWireResponseBody
        if localReq != nil || wireReq != nil || localRes != nil || wireRes != nil {
            Menu {
                if wireReq != nil || localReq != nil {
                    Section(header: Text("Request", bundle: .module)) {
                        if let wireReq {
                            Button(action: { copy(wireReq) }) { Text("insights.body.copy.server", bundle: .module) }
                        }
                        if let localReq {
                            Button(action: { copy(localReq) }) {
                                wireReq == nil ? Text("Copy request", bundle: .module) : Text("insights.body.copy.local", bundle: .module)
                            }
                        }
                    }
                }
                if wireRes != nil || localRes != nil {
                    Section(header: Text("Response", bundle: .module)) {
                        if let wireRes {
                            Button(action: { copy(wireRes) }) { Text("insights.body.copy.server", bundle: .module) }
                        }
                        if let localRes {
                            Button(action: { copy(localRes) }) {
                                wireRes == nil ? Text("Copy response", bundle: .module) : Text("insights.body.copy.local", bundle: .module)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Copy", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.5)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Copy request or response JSON", bundle: .module))
        }
    }

    /// Collapse a long leading crypto-address label (`0x` + 40 hex) in a relay
    /// host to `0xABCD…F291` — matching `RemoteAgent.shortAddress` /
    /// `AgentInvite.shortAddress` so the same address reads identically across
    /// surfaces — while leaving the domain suffix and ordinary hostnames (IPs,
    /// `.local`, plain domains) untouched. Examples:
    /// `0x7F5b…40hex…557C7a.agent.osaurus.ai` → `0x7F5b…57C7a.agent.osaurus.ai`;
    /// `192.168.1.5` → `192.168.1.5`.
    static func abbreviatedHost(_ host: String) -> String {
        guard let dot = host.firstIndex(of: ".") else {
            return shortAddressLabel(host)
        }
        return "\(shortAddressLabel(String(host[..<dot])))\(host[dot...])"
    }

    /// Mirror of `AgentInvite.shortAddress`: short labels pass through, longer
    /// ones collapse to first-6 + last-4 around an ellipsis.
    private static func shortAddressLabel(_ label: String) -> String {
        guard label.count > 12 else { return label }
        return "\(label.prefix(6))…\(label.suffix(4))"
    }

    /// Display form of a request path with any long `0x…` agent-address segment
    /// collapsed to `0xABCD…F291` (matching the relay pill and
    /// `RemoteAgent.shortAddress`), so a `/v1/agents/0x…40hex…/run` URL stays
    /// readable instead of dominating the header. Other segments are left as-is;
    /// the untruncated path remains available via the header tooltip and the
    /// Copy action.
    static func abbreviatedPath(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let s = String(segment)
                return isAddressSegment(s) ? shortAddressLabel(s) : s
            }
            .joined(separator: "/")
    }

    /// A path segment that is an `0x`-prefixed hex agent address long enough to
    /// be worth collapsing (short ids stay verbatim).
    private static func isAddressSegment(_ segment: String) -> Bool {
        guard segment.hasPrefix("0x"), segment.count > 12 else { return false }
        return segment.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    // MARK: - Tabs

    /// Prompt only makes sense for chat-shaped rows; Raw only when some body
    /// was captured. Everything else lives in Overview.
    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = [.overview]
        if log.isInference || log.category == .inboundAPI {
            tabs.append(.prompt)
        }
        if log.formattedRequestBody != nil || log.formattedWireRequestBody != nil
            || log.formattedResponseBody != nil || log.formattedWireResponseBody != nil
        {
            tabs.append(.raw)
        }
        return tabs
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        tab.label
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                    }
                    .foregroundColor(selectedTab == tab ? .white : theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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
            case .overview: OverviewTab(log: log, hInset: hInset)
            case .prompt: PromptTab(log: log)
            case .raw: RawTab(log: log)
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
            .padding(.horizontal, hInset)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Copy actions

    private func copy(_ body: String?) {
        guard let body, !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }
}

// MARK: - Tab Enum

private enum DetailTab: CaseIterable {
    case overview
    case prompt
    case raw

    var icon: String {
        switch self {
        case .overview: return "list.bullet.rectangle"
        case .prompt: return "text.bubble"
        case .raw: return "curlybraces"
        }
    }

    @ViewBuilder
    var label: some View {
        switch self {
        case .overview: Text("Overview", bundle: .module)
        case .prompt: Text("Prompt", bundle: .module)
        case .raw: Text("Raw", bundle: .module)
        }
    }
}

// MARK: - Raw Tab

/// Request / Response toggle over the shared `BodyTab`, which in turn
/// offers the Server / Local sub-toggle when a wire body was captured.
private struct RawTab: View {
    @Environment(\.theme) private var theme
    let log: RequestLog

    @State private var kind: BodyTab.Kind

    init(log: RequestLog) {
        self.log = log
        // Open on the side that actually has content.
        let hasRequest = log.formattedRequestBody != nil || log.formattedWireRequestBody != nil
        _kind = State(initialValue: hasRequest ? .request : .response)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                pill(.request, label: Text("Request", bundle: .module), icon: "arrow.up.circle")
                pill(.response, label: Text("Response", bundle: .module), icon: "arrow.down.circle")
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Group {
                switch kind {
                case .request:
                    BodyTab(
                        localBody: log.formattedRequestBody,
                        serverBody: log.formattedWireRequestBody,
                        kind: .request,
                        log: log
                    )
                case .response:
                    BodyTab(
                        localBody: log.formattedResponseBody,
                        serverBody: log.formattedWireResponseBody,
                        kind: .response,
                        log: log
                    )
                }
            }
            .id(kind)
        }
    }

    private func pill(_ value: BodyTab.Kind, label: Text, icon: String) -> some View {
        let isSelected = kind == value
        return Button(action: { kind = value }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                label.font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? theme.cardBackground : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
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
                } else if RequestLog.isWithheldContent(log.requestBody) {
                    emptyState(
                        text: Text(
                            "Prompt not stored for this record — Privacy › Activity Log › Store Prompts and Responses was off when it was written. Metadata, sizes and tokens are still recorded.",
                            bundle: .module
                        )
                    )
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
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
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
            .localizedHelp("Copy")

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

/// Which body the user is looking at inside the Request / Response
/// tab. The pair (`local`, `server`) collapses the previous separate
/// "Wire Request" / "Wire Response" tabs into a sub-toggle so the
/// page never has 6 tabs.
enum InsightsBodySource: Hashable {
    /// What Osaurus saw from the local caller (Chat UI -> Osaurus,
    /// or HTTP API client -> Osaurus). Unscrubbed for chat sends.
    case local
    /// What the cloud provider actually saw on the wire
    /// (post Privacy Filter, raw pre-unscrub stream on return).
    /// Hidden when the wire probe didn't capture anything (MLX,
    /// Foundation, plugins, or local HTTP API rows).
    case server

    /// Default selection rule. Server wins whenever a wire body
    /// exists — that's the trust artifact the user opened the tab
    /// for; otherwise fall back to the unscrubbed local body so the
    /// tab isn't empty for MLX / Foundation / plugin / HTTP API
    /// rows.
    static func defaultSource(local: String?, server: String?) -> InsightsBodySource {
        server != nil ? .server : .local
    }
}

private struct BodyTab: View {
    @Environment(\.theme) private var theme

    enum Kind {
        case request, response

        var emptyIcon: String {
            switch self {
            case .request: return "arrow.up.circle"
            case .response: return "arrow.down.circle"
            }
        }

        @ViewBuilder
        func emptyMessage(source: InsightsBodySource) -> some View {
            switch (self, source) {
            case (.request, .local):
                Text("No request body captured", bundle: .module)
            case (.response, .local):
                Text("No response body captured", bundle: .module)
            case (.request, .server):
                Text("insights.body.empty.server.request", bundle: .module)
            case (.response, .server):
                Text("insights.body.empty.server.response", bundle: .module)
            }
        }
    }

    let localBody: String?
    let serverBody: String?
    let kind: Kind
    let log: RequestLog

    @State private var source: InsightsBodySource

    init(localBody: String?, serverBody: String?, kind: Kind, log: RequestLog) {
        self.localBody = localBody
        self.serverBody = serverBody
        self.kind = kind
        self.log = log
        _source = State(
            initialValue: InsightsBodySource.defaultSource(local: localBody, server: serverBody)
        )
    }

    private var hasBothSources: Bool {
        localBody != nil && serverBody != nil
    }

    private var activeBody: String? {
        source == .server ? serverBody : localBody
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if hasBothSources {
                    sourcePicker
                    captionRow
                }
                if let text = activeBody {
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
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Two-pill segmented control. Rendered only when both bodies
    /// exist; the visual is intentionally similar to the parent
    /// tab strip so the relationship reads as "tab > sub-tab".
    private var sourcePicker: some View {
        HStack(spacing: 4) {
            sourcePill(.server, label: Text("insights.body.source.server", bundle: .module))
            sourcePill(.local, label: Text("insights.body.source.local", bundle: .module))
            Spacer()
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.4))
        )
    }

    private func sourcePill(_ value: InsightsBodySource, label: Text) -> some View {
        let isSelected = source == value
        let isServer = value == .server
        return Button(action: { source = value }) {
            HStack(spacing: 5) {
                Image(systemName: isServer ? "shield.lefthalf.filled" : "laptopcomputer")
                    .font(.system(size: 10, weight: .semibold))
                label
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accentColor.opacity(0.85) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var captionRow: some View {
        HStack(spacing: 6) {
            Image(systemName: source == .server ? "shield.lefthalf.filled" : "laptopcomputer")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(source == .server ? theme.accentColor : theme.tertiaryText)
            captionText
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    @ViewBuilder
    private var captionText: some View {
        switch (kind, source) {
        case (.request, .local):
            Text("insights.body.caption.local.request", bundle: .module)
        case (.request, .server):
            Text("insights.body.caption.server.request", bundle: .module)
        case (.response, .local):
            Text("insights.body.caption.local.response", bundle: .module)
        case (.response, .server):
            Text("insights.body.caption.server.response", bundle: .module)
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: kind.emptyIcon)
                    .font(.system(size: 28))
                    .foregroundColor(theme.tertiaryText.opacity(0.5))
                kind.emptyMessage(source: source)
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
        case .response:
            return log.isSuccess ? theme.primaryText : theme.errorColor
        }
    }

    /// Border color is the trust signal: server view always carries
    /// the accent border (this is the wire body), local response
    /// keeps the existing green/red status tinting.
    private var borderColor: Color {
        if source == .server {
            return theme.accentColor.opacity(0.35)
        }
        switch kind {
        case .request: return theme.primaryBorder.opacity(0.2)
        case .response:
            return log.isSuccess ? Color.green.opacity(0.2) : Color.red.opacity(0.2)
        }
    }
}

// MARK: - Overview Tab

/// Plain-language summary for reviewers: the facts that matter for this
/// kind of row up top, one sentence saying what happened, then
/// progressively disclosed groups — where the data went, who drove it,
/// generation settings and chain integrity — each collapsed to a one-line
/// summary until opened.
private struct OverviewTab: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    var hInset: CGFloat = 24

    private var details: [String: String] { log.egress?.details ?? [:] }
    private var isRemote: Bool { log.locality == .remote }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = log.errorMessage {
                    errorSection(error)
                }

                let facts = commonFacts
                if !facts.isEmpty {
                    FactsGrid(facts: facts)
                }

                Text(summaryHeadline)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                categorySection

                CollapsibleGroup(
                    icon: isRemote ? "icloud.and.arrow.up" : "lock.laptopcomputer",
                    title: Text("Where it went", bundle: .module),
                    summary: whereSummary,
                    initiallyExpanded: isRemote
                ) { whereRows }

                CollapsibleGroup(
                    icon: "person.crop.circle",
                    title: Text("Who drove this", bundle: .module),
                    summary: whoSummary,
                    initiallyExpanded: false
                ) { whoRows }

                if log.isInference || log.connection != nil || !(log.toolCalls ?? []).isEmpty {
                    CollapsibleGroup(
                        icon: "slider.horizontal.3",
                        title: Text("Generation settings", bundle: .module),
                        summary: generationSummary,
                        initiallyExpanded: false
                    ) { generationRows }
                }

                if log.seq != nil {
                    CollapsibleGroup(
                        icon: "checkmark.seal",
                        title: Text("Integrity", bundle: .module),
                        summary: integritySummary,
                        initiallyExpanded: false
                    ) { integrityRows }
                }
            }
            .padding(.horizontal, hInset)
            .padding(.vertical, 18)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Facts

    /// Cross-category facts for the grid. Category sections below add the
    /// kind-specific ones.
    private var commonFacts: [Fact] {
        var facts: [Fact] = []
        if let model = log.model, log.category != .speechSynthesis {
            facts.append(Fact(label: L("Model"), value: log.shortModelName, help: model))
        }
        if let i = log.inputTokens, let o = log.outputTokens, i + o > 0 {
            facts.append(Fact(label: L("Tokens"), value: L("\(i) in → \(o) out")))
        }
        if let speed = log.tokensPerSecond, speed > 0 {
            facts.append(Fact(label: L("Speed"), value: String(format: "%.1f tok/s", speed)))
        }
        if let reason = log.finishReason {
            facts.append(Fact(label: L("Finish"), value: reason.rawValue))
        }
        if let e = log.egress {
            if let b = e.bytesSent, b > 0 {
                facts.append(Fact(label: L("Sent"), value: ActivitySummary.formattedBytes(b)))
            }
            if let b = e.bytesReceived, b > 0 {
                facts.append(Fact(label: L("Received"), value: ActivitySummary.formattedBytes(b)))
            }
        }
        if isRemote {
            facts.append(Fact(label: L("Destination"), value: log.destinationDisplay))
        }
        if log.category.isModelWork {
            facts.append(
                Fact(
                    label: L("Content"),
                    value: log.hasStoredContent ? L("Stored") : L("Not stored"),
                    help: log.hasStoredContent
                        ? L("Prompt and response are kept in the log — see Prompt / Raw")
                        : L("Privacy › Activity Log › Store Prompts and Responses was off when this was written")
                )
            )
        }
        return facts
    }

    private var summaryHeadline: String {
        let outcome = log.isError ? L("failed") : L("completed")
        switch log.category {
        case .inference:
            return isRemote
                ? L("Model request sent to \(log.destinationDisplay) — \(outcome).")
                : L("Model ran on this Mac — \(outcome).")
        case .compaction:
            return isRemote
                ? L("Conversation summary sent to \(log.destinationDisplay) — \(outcome).")
                : L("Conversation summarized on this Mac — \(outcome).")
        case .webSearch:
            return L("Web search sent to \(log.destinationDisplay) — \(outcome).")
        case .urlExtract:
            return details["mode"] == "hosted"
                ? L("Pages fetched through \(log.destinationDisplay) — \(outcome).")
                : L("Page fetched from \(log.destinationDisplay) — \(outcome).")
        case .mcpToolCall:
            return isRemote
                ? L("Tool call sent to MCP server \(log.destinationDisplay) — \(outcome).")
                : L("Tool call to local MCP server \(log.destinationDisplay) — \(outcome).")
        case .channelDelivery:
            return L("Message delivered to \(log.destinationDisplay) — \(details["outcome"] ?? outcome).")
        case .routerControl:
            return L("\(details["purpose"] ?? L("Router call")) — Osaurus Router — \(outcome).")
        case .inboundAPI:
            return log.source == .p2p
                ? L("Request from a paired peer — \(outcome).")
                : L("Request from an API client — \(outcome).")
        case .pluginCall:
            return L("Plugin call — \(outcome).")
        case .pluginLog:
            return L("Plugin log line.")
        case .embedding:
            return isRemote
                ? L("Embeddings computed by \(log.destinationDisplay) — \(outcome).")
                : L("Embeddings computed on this Mac — \(outcome).")
        case .audioTranscription:
            return isRemote
                ? L("Audio sent to \(log.destinationDisplay) for transcription — \(outcome).")
                : L("Audio transcribed on this Mac — \(outcome).")
        case .speechSynthesis:
            return isRemote
                ? L("Text sent to \(log.destinationDisplay) for speech — \(outcome).")
                : L("Speech synthesized on this Mac — \(outcome).")
        case .mediaGeneration:
            return isRemote
                ? L("Media request sent to \(log.destinationDisplay) — \(outcome).")
                : L("Media generated on this Mac — \(outcome).")
        case .system:
            return log.systemEventSummary ?? log.title
        }
    }

    // MARK: Where

    private var whereSummary: String {
        if !isRemote { return L("Stayed on this Mac") }
        var parts = [log.destinationDisplay]
        if let classes = log.egress?.dataClasses, !classes.isEmpty {
            parts.append(classes.map(Self.dataClassLabel).joined(separator: ", "))
        }
        if log.egress?.privacyFilterApplied == true { parts.append(L("Privacy Filter applied")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var whereRows: some View {
        DetailRow(
            label: Text("Locality", bundle: .module),
            value: isRemote ? L("Left this Mac (cloud)") : L("Stayed on this Mac"),
            valueColor: isRemote ? theme.warningColor : theme.successColor
        )
        if isRemote {
            DetailRow(label: Text("Destination", bundle: .module), value: log.destinationDisplay)
            if let host = log.egress?.destinationHost ?? EgressInfo.host(from: log.connection?.remoteEndpoint) {
                DetailRow(label: Text("Host", bundle: .module), value: host)
            }
            if let endpoint = log.connection?.remoteEndpoint {
                DetailRow(label: Text("Endpoint", bundle: .module), value: endpoint)
            }
            if let transport = log.connection?.transport, transport != .local {
                DetailRow(label: Text("Transport", bundle: .module), value: transport.displayName)
            }
            if let mode = log.connection?.mode, mode != .local {
                DetailRow(label: Text("Mode", bundle: .module), value: mode.displayName)
            }
            if let classes = log.egress?.dataClasses, !classes.isEmpty {
                DetailRow(
                    label: Text("Data sent", bundle: .module),
                    value: classes.map(Self.dataClassLabel).joined(separator: ", ")
                )
            }
            if let e = log.egress {
                if e.privacyFilterApplied {
                    DetailRow(
                        label: Text("Privacy Filter", bundle: .module),
                        value: L("Applied — \(e.redactedSpanCount ?? 0) item(s) redacted before send"),
                        valueColor: theme.successColor
                    )
                } else if log.category == .inference || log.category == .compaction {
                    DetailRow(
                        label: Text("Privacy Filter", bundle: .module),
                        value: L("Not applied"),
                        valueColor: theme.secondaryText
                    )
                }
            }
        }
        if let ip = log.clientIP, log.category == .inboundAPI {
            DetailRow(label: Text("Caller address", bundle: .module), value: ip)
        }
    }

    static func dataClassLabel(_ raw: String) -> String {
        switch raw {
        case "prompt": return L("conversation")
        case "tools": return L("tool definitions")
        case "attachments": return L("attachments")
        case "search_query": return L("search query")
        case "urls": return L("URLs")
        case "tool_arguments": return L("tool arguments")
        case "channel_message": return L("message")
        case "account": return L("account metadata")
        default: return raw
        }
    }

    // MARK: Category-specific

    @ViewBuilder
    private var categorySection: some View {
        switch log.category {
        case .webSearch: searchSection
        case .urlExtract: extractSection
        case .mcpToolCall: mcpSection
        case .channelDelivery: channelSection
        case .routerControl: routerSection
        case .inference, .compaction: EmptyView()
        case .embedding: embeddingSection
        case .audioTranscription: transcriptionSection
        case .speechSynthesis: speechSection
        case .mediaGeneration: mediaSection
        case .system: systemEventSection
        case .inboundAPI, .pluginCall, .pluginLog: genericDetailsSection
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        FlatGroup(icon: "magnifyingglass", title: Text("Search", bundle: .module)) {
            if let q = details["query"] { DetailRow(label: Text("Query", bundle: .module), value: q) }
            if let c = details["category"] { DetailRow(label: Text("Category", bundle: .module), value: c) }
            if let s = details["site"] { DetailRow(label: Text("Site filter", bundle: .module), value: s) }
            if let f = details["filetype"] { DetailRow(label: Text("File type", bundle: .module), value: f) }
            if let t = details["time_range"] { DetailRow(label: Text("Time range", bundle: .module), value: t) }
            if let p = details["provider_used"] { DetailRow(label: Text("Served by", bundle: .module), value: p) }
            if let p = details["providers_tried"] { DetailRow(label: Text("Providers tried", bundle: .module), value: p) }
            if let s = details["source"] { DetailRow(label: Text("Tier", bundle: .module), value: s) }
            if let r = details["hosted_fallback"] { DetailRow(label: Text("Hosted fallback", bundle: .module), value: r) }
            if let n = details["hit_count"] { DetailRow(label: Text("Results", bundle: .module), value: n) }
            if details["pinned_test"] == "true" {
                DetailRow(label: Text("Note", bundle: .module), value: L("Provider test run from Settings"))
            }
            if let f = details["failures"] {
                DetailRow(label: Text("Failures", bundle: .module), value: f, valueColor: theme.errorColor.opacity(0.85))
            }
        }
        if let preview = details["result_preview"], !preview.isEmpty {
            FlatGroup(icon: "link", title: Text("Top results", bundle: .module)) {
                urlList(preview)
            }
        }
    }

    @ViewBuilder
    private var extractSection: some View {
        FlatGroup(icon: "doc.text.magnifyingglass", title: Text("Fetched pages", bundle: .module)) {
            if let mode = details["mode"] {
                DetailRow(
                    label: Text("Mode", bundle: .module),
                    value: mode == "hosted" ? L("Hosted (Osaurus Router)") : L("Direct from this Mac")
                )
            }
            if let n = details["url_count"] { DetailRow(label: Text("URL count", bundle: .module), value: n) }
            if let n = details["succeeded"] { DetailRow(label: Text("Succeeded", bundle: .module), value: n) }
            if let s = details["status"] { DetailRow(label: Text("Status", bundle: .module), value: s) }
            if let t = details["title"] { DetailRow(label: Text("Title", bundle: .module), value: t) }
            if let c = details["canonical_url"] { DetailRow(label: Text("Canonical URL", bundle: .module), value: c) }
            if let f = details["format"] { DetailRow(label: Text("Format", bundle: .module), value: f) }
            if let w = details["word_count"] { DetailRow(label: Text("Words", bundle: .module), value: w) }
            if let m = details["message"] { DetailRow(label: Text("Message", bundle: .module), value: m) }
            if let f = details["failures"] {
                DetailRow(label: Text("Failures", bundle: .module), value: f, valueColor: theme.errorColor.opacity(0.85))
            }
        }
        if let urls = details["urls"], !urls.isEmpty {
            FlatGroup(icon: "link", title: Text("URLs", bundle: .module)) {
                urlList(urls)
            }
        }
    }

    private func urlList(_ joined: String) -> some View {
        ForEach(joined.split(separator: "\n").map(String.init), id: \.self) { url in
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var mcpSection: some View {
        FlatGroup(icon: "wrench.and.screwdriver", title: Text("MCP tool call", bundle: .module)) {
            if let s = details["server"] { DetailRow(label: Text("Server", bundle: .module), value: s) }
            if let t = details["tool"] { DetailRow(label: Text("Tool", bundle: .module), value: t) }
            if let e = details["exposed_as"] { DetailRow(label: Text("Exposed as", bundle: .module), value: e) }
            if let t = details["transport"] { DetailRow(label: Text("Transport", bundle: .module), value: t) }
            if let h = details["execution_host"] { DetailRow(label: Text("Runs in", bundle: .module), value: h) }
            if let c = details["command"] { DetailRow(label: Text("Command", bundle: .module), value: c) }
        }
        if let args = details["arguments"], !args.isEmpty {
            codeBlock(icon: "arrow.up.circle", title: Text("Arguments sent", bundle: .module), code: args)
        }
        if let result = details["result_preview"], !result.isEmpty {
            codeBlock(icon: "arrow.down.circle", title: Text("Result (preview)", bundle: .module), code: result)
        }
    }

    @ViewBuilder
    private var channelSection: some View {
        FlatGroup(icon: "paperplane", title: Text("Channel delivery", bundle: .module)) {
            if let c = details["channel"] { DetailRow(label: Text("Channel", bundle: .module), value: c) }
            if let c = details["connection"] { DetailRow(label: Text("Connection", bundle: .module), value: c) }
            if let r = details["room"] { DetailRow(label: Text("Room", bundle: .module), value: r) }
            if let t = details["thread"] { DetailRow(label: Text("Thread", bundle: .module), value: t) }
            if let b = details["binding"] { DetailRow(label: Text("Binding", bundle: .module), value: b) }
            if let o = details["outcome"] { DetailRow(label: Text("Outcome", bundle: .module), value: o) }
            if let n = details["content_length"] {
                DetailRow(label: Text("Message size", bundle: .module), value: L("\(n) characters"))
            }
            if let id = details["provider_message_id"] {
                DetailRow(label: Text("Provider message", bundle: .module), value: id)
            }
            if let r = details["run_source"] { DetailRow(label: Text("Run source", bundle: .module), value: r) }
            if let i = details["intent_id"] { DetailRow(label: Text("Intent", bundle: .module), value: i) }
            DetailRow(
                label: Text("Content", bundle: .module),
                value: L("Not stored here — see the channel outbox / audit ledger"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var routerSection: some View {
        FlatGroup(icon: "network", title: Text("Router call", bundle: .module)) {
            if let p = details["purpose"] { DetailRow(label: Text("Purpose", bundle: .module), value: p) }
            if let q = details["query_string"] { DetailRow(label: Text("Query", bundle: .module), value: q) }
            DetailRow(label: Text("HTTP status", bundle: .module), value: "\(log.statusCode)")
        }
    }

    @ViewBuilder
    private var embeddingSection: some View {
        FlatGroup(icon: "point.3.connected.trianglepath.dotted", title: Text("Embedding", bundle: .module)) {
            if let n = details["texts"] { DetailRow(label: Text("Texts embedded", bundle: .module), value: n) }
            if let d = details["dims"] { DetailRow(label: Text("Dimensions", bundle: .module), value: d) }
            if let c = details["chars"] { DetailRow(label: Text("Input size", bundle: .module), value: L("\(c) characters")) }
            if let p = details["purpose"] { DetailRow(label: Text("Purpose", bundle: .module), value: p) }
            DetailRow(
                label: Text("Texts", bundle: .module),
                value: L("Not copied into the log — only counts and sizes"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        FlatGroup(icon: "waveform", title: Text("Transcription", bundle: .module)) {
            if let s = details["audio_seconds"], let secs = Double(s) {
                DetailRow(label: Text("Audio length", bundle: .module), value: String(format: "%.1f s", secs))
            }
            if let b = details["audio_bytes"], let bytes = Int(b) {
                DetailRow(label: Text("Audio size", bundle: .module), value: ActivitySummary.formattedBytes(bytes))
            }
            if let f = details["audio_format"] { DetailRow(label: Text("Format", bundle: .module), value: f) }
            if let l = details["language"] { DetailRow(label: Text("Language", bundle: .module), value: l) }
            if let c = details["transcript_chars"] {
                DetailRow(label: Text("Transcript size", bundle: .module), value: L("\(c) characters"))
            }
            if let m = details["mode"] { DetailRow(label: Text("Mode", bundle: .module), value: m) }
        }
    }

    @ViewBuilder
    private var speechSection: some View {
        FlatGroup(icon: "speaker.wave.2", title: Text("Speech synthesis", bundle: .module)) {
            if let model = log.model { DetailRow(label: Text("Model / voice", bundle: .module), value: model) }
            if let v = details["voice"] { DetailRow(label: Text("Voice", bundle: .module), value: v) }
            if let c = details["chars"] { DetailRow(label: Text("Text size", bundle: .module), value: L("\(c) characters")) }
            if let a = details["audio_seconds"] { DetailRow(label: Text("Audio produced", bundle: .module), value: L("\(a) s")) }
            if let p = details["provider"] { DetailRow(label: Text("Provider", bundle: .module), value: p) }
            if let t = details["trigger"] { DetailRow(label: Text("Triggered by", bundle: .module), value: t) }
            if details["cancelled"] == "true" {
                DetailRow(label: Text("Playback", bundle: .module), value: L("Stopped by the user before it finished"))
            }
        }
    }

    @ViewBuilder
    private var mediaSection: some View {
        FlatGroup(icon: "photo.on.rectangle.angled", title: Text("Media generation", bundle: .module)) {
            if let k = details["media_kind"] { DetailRow(label: Text("Kind", bundle: .module), value: k) }
            if let o = details["operation"] { DetailRow(label: Text("Operation", bundle: .module), value: o) }
            if let n = details["count"] { DetailRow(label: Text("Outputs", bundle: .module), value: n) }
            if let s = details["size"] { DetailRow(label: Text("Size", bundle: .module), value: s) }
            if let s = details["steps"] { DetailRow(label: Text("Steps", bundle: .module), value: s) }
            if let d = details["duration_seconds"] ?? details["duration"] {
                DetailRow(label: Text("Clip length", bundle: .module), value: L("\(d) s"))
            }
            if let s = details["scale"] { DetailRow(label: Text("Upscale factor", bundle: .module), value: "\(s)×") }
            if let n = details["source_images"] { DetailRow(label: Text("Source images", bundle: .module), value: n) }
            if let q = details["quote_usd"] { DetailRow(label: Text("Quoted price", bundle: .module), value: "$\(q)") }
            if let p = details["provider"] ?? details["backend"] { DetailRow(label: Text("Provider", bundle: .module), value: p) }
            if let j = details["job_id"] { DetailRow(label: Text("Job", bundle: .module), value: j) }
            if let c = details["prompt_chars"] { DetailRow(label: Text("Prompt size", bundle: .module), value: L("\(c) characters")) }
        }
    }

    @ViewBuilder
    private var systemEventSection: some View {
        FlatGroup(icon: "checkmark.shield", title: Text("Chain of custody", bundle: .module)) {
            ForEach(details.keys.sorted().filter { $0 != "event" }, id: \.self) { key in
                if Self.isHashKey(key) {
                    IdentifierRow(label: Text(verbatim: Self.systemDetailLabel(key)), value: details[key] ?? "")
                } else {
                    DetailRow(label: Text(verbatim: Self.systemDetailLabel(key)), value: details[key] ?? "")
                }
            }
        }
    }

    private static func isHashKey(_ key: String) -> Bool {
        key.hasSuffix("_hash")
    }

    private static func systemDetailLabel(_ key: String) -> String {
        switch key {
        case "removed_rows": return L("Rows removed")
        case "cutoff": return L("Cutoff")
        case "anchor_seq": return L("New anchor")
        case "records": return L("Records checked")
        case "head_hash": return L("Head hash")
        case "problems": return L("Problems")
        case "format": return L("Format")
        case "include_content": return L("Included content")
        case "filter": return L("Filter")
        case "file_name": return L("File")
        case "retention_days": return L("Keep history")
        case "store_content": return L("Store prompts and responses")
        case "expected_seq": return L("Head file seq")
        case "found_seq": return L("Database seq")
        case "expected_hash": return L("Head file hash")
        case "found_hash": return L("Database hash")
        case "head_seq": return L("Head seq")
        case "ok": return L("Chain intact")
        case "problem_summary": return L("Problem summary")
        case "previous_retention_days": return L("Previous keep history")
        case "previous_store_content": return L("Previously stored content")
        case "reason": return L("Reason")
        default: return key
        }
    }

    @ViewBuilder
    private var genericDetailsSection: some View {
        let keys = details.keys.sorted().filter { $0 != "parent_turn_id" }
        if !keys.isEmpty {
            FlatGroup(icon: "info.circle", title: Text("Details", bundle: .module)) {
                ForEach(keys, id: \.self) { key in
                    DetailRow(label: Text(verbatim: key), value: details[key] ?? "")
                }
            }
        }
    }

    // MARK: Who

    private var whoSummary: String {
        var parts = [log.source.displayName]
        if let name = log.agentName { parts.append(name) }
        if let plugin = log.pluginId { parts.append(plugin) }
        if let parent = details["parent_turn_id"] {
            parts.append(String(format: L("Delegated from turn %@"), IdentifierRow.shortened(parent)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var whoRows: some View {
        DetailRow(label: Text("Source", bundle: .module), value: log.source.displayName)
        if let name = log.agentName {
            DetailRow(label: Text("Agent", bundle: .module), value: name)
        } else if let id = log.agentId {
            IdentifierRow(label: Text("Agent", bundle: .module), value: id.uuidString)
        }
        if let session = log.sessionId {
            IdentifierRow(label: Text("Session", bundle: .module), value: session.uuidString)
        }
        if let turn = log.turnId {
            IdentifierRow(label: Text("Turn", bundle: .module), value: turn.uuidString)
        }
        if let parent = details["parent_turn_id"] {
            IdentifierRow(label: Text("Delegated from turn", bundle: .module), value: parent)
        }
        if let rid = log.requestId {
            IdentifierRow(label: Text("Request ID", bundle: .module), value: rid)
        }
        if let plugin = log.pluginId {
            DetailRow(label: Text("Plugin", bundle: .module), value: plugin)
        }
        if let ua = log.userAgent {
            DetailRow(label: Text("User agent", bundle: .module), value: ua)
        }
        if let key = log.connection?.accessKeyId {
            IdentifierRow(label: Text("Access key", bundle: .module), value: key)
        }
        if let aud = log.connection?.audience {
            DetailRow(label: Text("Audience", bundle: .module), value: aud)
        }
    }

    // MARK: Generation settings

    private var generationSummary: String {
        var parts: [String] = []
        if let temp = log.temperature { parts.append(String(format: L("temp %.2f"), temp)) }
        if let maxTokens = log.maxTokens { parts.append(String(format: L("max %d tokens"), maxTokens)) }
        if let tools = log.toolCalls, !tools.isEmpty {
            parts.append(tools.count == 1 ? L("1 tool call") : String(format: L("%d tool calls"), tools.count))
        }
        if let mode = log.connection?.mode, mode != .local { parts.append(mode.displayName) }
        return parts.isEmpty ? L("Defaults") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var generationRows: some View {
        if let temp = log.temperature {
            DetailRow(label: Text("Temperature", bundle: .module), value: String(format: "%.2f", temp))
        }
        if let maxTokens = log.maxTokens {
            DetailRow(label: Text("Max tokens", bundle: .module), value: "\(maxTokens)")
        }
        if let reason = log.finishReason {
            DetailRow(label: Text("Finish reason", bundle: .module), value: reason.rawValue)
        }
        if let connection = log.connection {
            if let mode = connection.mode {
                DetailRow(label: Text("Mode", bundle: .module), value: mode.displayName)
            }
            if let transport = connection.transport {
                DetailRow(label: Text("Transport", bundle: .module), value: transport.displayName)
            }
            if let endpoint = connection.remoteEndpoint {
                DetailRow(label: Text("Endpoint", bundle: .module), value: endpoint)
            }
        }
        if let toolCalls = log.toolCalls, !toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tool calls", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.top, 6)
                ForEach(toolCalls) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(tool.isError ? theme.errorColor.opacity(0.8) : theme.successColor.opacity(0.8))
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
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.35)))
                }
            }
        }
    }

    // MARK: Integrity

    private var integritySummary: String {
        guard let seq = log.seq else { return "" }
        var s = "#\(seq)"
        if let hash = log.hash { s += " · \(IdentifierRow.shortened(hash))" }
        return s
    }

    @ViewBuilder
    private var integrityRows: some View {
        if let seq = log.seq {
            DetailRow(label: Text("Record", bundle: .module), value: "#\(seq)")
        }
        if let hash = log.hash {
            IdentifierRow(label: Text("Hash", bundle: .module), value: hash)
        }
        if let prev = log.prevHash {
            IdentifierRow(label: Text("Previous", bundle: .module), value: prev)
        }
        Text("Each record is chained to the one before it with SHA-256. Use Verify Integrity from the Insights menu to check the whole log.", bundle: .module)
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    // MARK: Error

    private func errorSection(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Error", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.errorColor.opacity(0.25), lineWidth: 1))
        )
    }

    private func codeBlock(icon: String, title: Text, code: String) -> some View {
        FlatGroup(icon: icon, title: title) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.codeBlockBackground))
        }
    }
}

// MARK: - Facts grid

private struct Fact: Identifiable {
    let label: String
    let value: String
    var help: String?
    var id: String { label }
}

private struct FactsGrid: View {
    @Environment(\.theme) private var theme
    let facts: [Fact]

    private let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .textCase(.uppercase)
                    Text(fact.value)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Text(verbatim: fact.help ?? fact.value))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.primaryBorder.opacity(0.25), lineWidth: 1))
        )
    }
}

// MARK: - Groups

/// Always-open group: a small heading over flat rows. Used for the
/// category-specific facts that *are* the point of the row.
private struct FlatGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: Text
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                title
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.leading, 16)
        }
    }
}

/// Disclosure group with a one-line summary shown while collapsed, so a
/// reviewer can read the gist of every group without opening any of them.
private struct CollapsibleGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: Text
    let summary: String
    @State private var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        icon: String,
        title: Text,
        summary: String,
        initiallyExpanded: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.summary = summary
        self.content = content
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                    title
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                    if !isExpanded, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 4)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .top) {
            Divider().background(theme.primaryBorder.opacity(0.2)).offset(y: -9)
        }
    }
}

// MARK: - Rows

private struct DetailRow: View {
    @Environment(\.theme) private var theme

    let label: Text
    let value: String
    var valueColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(valueColor ?? theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

/// Row for a long identifier (UUID, hash, request id). Renders the
/// shortened form, keeps the full value in the tooltip and copies it on
/// click.
private struct IdentifierRow: View {
    @Environment(\.theme) private var theme

    let label: Text
    let value: String

    @State private var copied = false

    static func shortened(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 104, alignment: .leading)
            Button(action: copy) {
                HStack(spacing: 5) {
                    Text(Self.shortened(value))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(copied ? theme.successColor : theme.tertiaryText.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(Text(verbatim: value))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
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
