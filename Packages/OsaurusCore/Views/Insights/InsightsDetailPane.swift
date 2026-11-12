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
        VStack(spacing: theme.space.s0) {
            header
            Divider()
                .background(theme.border.subtle)
            if log.isPluginLog {
                pluginBody
            } else {
                if availableTabs.count > 1 {
                    tabPicker
                        .padding(.horizontal, hInset)
                        .padding(.top, theme.space.s12)
                }
                tabContent
            }
        }
        .background(theme.surface.canvas)
        .id(log.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                if presentation == .page {
                    SettingsBackButton(title: "Insights", action: onBack)
                        .padding(.leading, -theme.space.s8)
                        .keyboardShortcut(.escape, modifiers: [])
                }

                Spacer()

                copyMenu

                if presentation == .inspector {
                    SettingsIconButton("xmark", help: "Close", size: .compact, action: onBack)
                }
            }

            HStack(alignment: .top, spacing: theme.space.s12) {
                ZStack {
                    Circle().fill(theme.dataWash(log.category.ink))
                    Image(systemName: log.category.icon)
                        .glyphSize(.label, weight: .semibold)
                        .foregroundColor(theme.dataInk(log.category.ink))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text(log.title)
                        .textStyle(usesMonospacedTitle ? .code : .heading, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if log.category != .system {
                        Text(verbatim: "\(log.method) \(Self.abbreviatedPath(log.path))")
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.tertiary)
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
        .padding(.vertical, theme.space.s12)
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
        StatusChip(
            log.statusCode == 200 ? L("failed") : "\(log.statusCode) · \(L("failed"))",
            tone: .error,
            icon: "exclamationmark.circle.fill"
        )
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
            SettingsMenuButton(.secondary, "Copy", icon: "doc.on.doc", size: .compact) {
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
            }
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
        HStack(spacing: theme.space.s4) {
            ForEach(availableTabs, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: tab.icon)
                            .glyphSize(.footnote, weight: .semibold)
                        tab.label
                            .textStyle(.caption, weight: selectedTab == tab ? 600 : 500)
                    }
                    .foregroundColor(selectedTab == tab ? theme.text.primary : theme.text.secondary)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s6)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .fill(selectedTab == tab ? theme.surface.selected : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .strokeBorder(selectedTab == tab ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
        .padding(theme.space.s4)
        .settingsChrome(.inset)
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
            VStack(alignment: .leading, spacing: theme.space.s8) {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: level.icon)
                        .glyphSize(.caption)
                        .foregroundColor(levelColor)
                    Text(level.label, bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(levelColor)
                    Spacer()
                }
                if let body = log.requestBody {
                    Text(body)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(levelColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(theme.space.s12)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(level.wash(theme: theme))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .stroke(level.edge(theme: theme), lineWidth: theme.stroke.default)
                    )
            )
            .padding(.horizontal, hInset)
            .padding(.vertical, theme.space.s16)
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
        VStack(spacing: theme.space.s0) {
            HStack(spacing: theme.space.s2) {
                pill(.request, label: Text("Request", bundle: .module), icon: "arrow.up.circle")
                pill(.response, label: Text("Response", bundle: .module), icon: "arrow.down.circle")
                Spacer()
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.top, theme.space.s12)

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
            HStack(spacing: theme.space.s4) {
                Image(systemName: icon).glyphSize(.micro, weight: .semibold)
                label.textStyle(.footnote, weight: isSelected ? 600 : 500)
            }
            .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s6)
            .settingsChrome(isSelected ? .surface : nil)
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
        case .info: return theme.text.primary
        case .warning: return theme.status.warning.foreground
        case .error: return theme.status.error.foreground
        }
    }

    func wash(theme: ThemeProtocol) -> Color {
        switch self {
        case .info: return theme.surface.subtle
        case .warning: return theme.status.warning.background
        case .error: return theme.status.error.background
        }
    }

    func edge(theme: ThemeProtocol) -> Color {
        switch self {
        case .info: return theme.border.subtle
        case .warning: return theme.status.warning.border
        case .error: return theme.status.error.border
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
            VStack(alignment: .leading, spacing: theme.space.s12) {
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
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s16)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func emptyState(text: Text) -> some View {
        HStack {
            Spacer()
            VStack(spacing: theme.space.s8) {
                Image(systemName: "text.bubble")
                    .glyphSize(.display)
                    .foregroundColor(theme.text.tertiary)
                text
                    .textStyle(.caption)
                    .foregroundColor(theme.text.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .padding(.vertical, theme.space.s40)
            Spacer()
        }
    }

    private func toolsSection(_ tools: [ParsedTool]) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.status.info.foreground)
                Text("Tools (\(tools.count))", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    ToolCard(tool: tool)
                }
            }
        }
        .padding(.top, theme.space.s8)
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

    var ink: DataInk {
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
    private var roleColor: Color { theme.dataInk(role.ink) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            cardHeader
            if isExpanded {
                cardContent
                if !message.toolCalls.isEmpty {
                    toolCallsList
                }
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card, radius: theme.radius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .stroke(theme.dataWash(role.ink), lineWidth: theme.stroke.default)
        )
    }

    private var cardHeader: some View {
        HStack(spacing: theme.space.s8) {
            roleBadge
            Spacer()
            if let toolCallId = message.toolCallId {
                Text(verbatim: "call: \(toolCallId)")
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
            }
            Button(action: copyContent) {
                Image(systemName: "doc.on.doc")
                    .glyphSize(.micro)
                    .foregroundColor(theme.text.tertiary)
            }
            .buttonStyle(PlainButtonStyle())
            .localizedHelp("Copy")

            Button(action: { withAnimation(theme.motion.quick) { isExpanded.toggle() } }) {
                Image(systemName: "chevron.right")
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if let content = message.content, !content.isEmpty {
            Text(content)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if message.toolCalls.isEmpty {
            Text("(empty)", bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
    }

    private var toolCallsList: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, call in
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .glyphSize(.micro)
                        .foregroundColor(theme.status.info.foreground)
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        Text(call.name)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.primary)
                        Text(call.arguments)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(theme.space.s8)
                .settingsChrome(.status(.info), radius: theme.radius.small)
            }
        }
    }

    private var roleBadge: some View {
        StatusChip(role.displayName, tint: roleColor, icon: role.icon)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Button(action: { withAnimation(theme.motion.quick) { isExpanded.toggle() } }) {
                HStack(spacing: theme.space.s8) {
                    Image(systemName: "chevron.right")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(tool.name)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                    if let desc = tool.description, !desc.isEmpty {
                        Text("·")
                            .foregroundColor(theme.text.tertiary)
                        Text(desc)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded, let params = tool.parametersJSON, !params.isEmpty {
                Text(params)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(theme.space.s8)
                    .settingsChrome(.inset)
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.status(.info))
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
            VStack(alignment: .leading, spacing: theme.space.s10) {
                if hasBothSources {
                    sourcePicker
                    captionRow
                }
                if let text = activeBody {
                    Text(text)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(textColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(theme.space.s12)
                        .settingsChrome(.subtle)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, theme.space.s24)
            .padding(.vertical, theme.space.s16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Two-pill segmented control. Rendered only when both bodies
    /// exist; the visual is intentionally similar to the parent
    /// tab strip so the relationship reads as "tab > sub-tab".
    private var sourcePicker: some View {
        HStack(spacing: theme.space.s4) {
            sourcePill(.server, label: Text("insights.body.source.server", bundle: .module))
            sourcePill(.local, label: Text("insights.body.source.local", bundle: .module))
            Spacer()
        }
        .padding(theme.space.s4)
        .settingsChrome(.inset)
    }

    private func sourcePill(_ value: InsightsBodySource, label: Text) -> some View {
        let isSelected = source == value
        let isServer = value == .server
        return Button(action: { source = value }) {
            HStack(spacing: theme.space.s4) {
                Image(systemName: isServer ? "shield.lefthalf.filled" : "laptopcomputer")
                    .glyphSize(.micro, weight: .semibold)
                label
                    .textStyle(.footnote, weight: isSelected ? 600 : 500)
            }
            .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s6)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(isSelected ? theme.surface.selected : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .strokeBorder(isSelected ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var captionRow: some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: source == .server ? "shield.lefthalf.filled" : "laptopcomputer")
                .glyphSize(.tiny, weight: .semibold)
                .foregroundColor(source == .server ? theme.text.link : theme.text.tertiary)
            captionText
                .glyphSize(.footnote)
                .foregroundColor(theme.text.secondary)
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
            VStack(spacing: theme.space.s8) {
                Image(systemName: kind.emptyIcon)
                    .glyphSize(.display)
                    .foregroundColor(theme.text.tertiary)
                kind.emptyMessage(source: source)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.vertical, theme.space.s40)
            Spacer()
        }
    }

    private var textColor: Color {
        switch kind {
        case .request: return theme.text.primary
        case .response:
            return log.isSuccess ? theme.text.primary : theme.status.error.foreground
        }
    }

    /// Border color is the trust signal: server view always carries
    /// the accent border (this is the wire body), local response
    /// keeps the existing green/red status tinting.
    private var borderColor: Color {
        if source == .server {
            return theme.border.strong
        }
        switch kind {
        case .request: return theme.border.subtle
        case .response:
            return log.isSuccess ? theme.status.success.background : theme.status.error.background
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
            VStack(alignment: .leading, spacing: theme.space.s16) {
                if let error = log.errorMessage {
                    errorSection(error)
                }

                let facts = commonFacts
                if !facts.isEmpty {
                    FactsGrid(facts: facts)
                }

                Text(summaryHeadline)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
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
            .padding(.vertical, theme.space.s16)
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
        if log.inputTokens != nil || log.outputTokens != nil {
            facts.append(Fact(label: L("Input tokens"), value: log.inputTokenDescription))
            facts.append(Fact(label: L("Output tokens"), value: log.outputTokenDescription))
        }
        if let rate = log.requestRateDescription, let speed = log.tokensPerSecond, speed > 0 {
            facts.append(Fact(
                label: L("Request rate"), value: rate,
                help: L("Output tokens divided by the full request duration, including prompt processing and network waits.")
            ))
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
        case .workflowRun:
            let status = details["status"].map(RequestLog.workflowStatusLabel) ?? outcome
            return L("Workflow \(details["workflow"] ?? log.path) ran for \(log.source.displayName) — \(status).")
        case .workflowNode:
            return L("Step \(details["node_name"] ?? log.workflowNodeId ?? log.path) of \(details["workflow"] ?? L("a workflow")) — \(outcome).")
        case .event:
            let status = details["status"].map { EventRunStatus(rawValue: $0)?.displayName ?? $0 } ?? outcome
            return L("Automation \(details["event"] ?? log.path) ran from \(log.source.displayName) — \(status).")
        case .task:
            let state = details["state"].map { TaskState(rawValue: $0)?.displayName ?? $0 } ?? outcome
            let kind = details["work"].map { TaskWorkKind(rawValue: $0)?.displayName ?? $0 } ?? L("Task")
            let onDefault =
                details["queue_id"].map { UUID(uuidString: $0) == TaskQueue.defaultID }
                ?? (details["queue"] == nil || details["queue"] == L("Default"))
            if onDefault && !TaskStore.shared.hasMultipleQueues {
                return L("\(kind) from \(log.source.displayName) — \(state).")
            }
            return L("\(kind) from \(log.source.displayName) on \(details["queue"] ?? L("Default")) — \(state).")
        case .system:
            return log.systemEventSummary ?? log.title
        case .interaction:
            guard let asker = details["requester"] ?? details["agent"], let decider = details["decided_by"] else {
                return "\(log.title)."
            }
            let wait = details["wait_ms"].flatMap(Double.init).map { RequestLog.formattedDuration(ms: $0) }
            let ownAnswer = ["owner", "owner_device"].contains(details["decided_by_kind"] ?? "owner")
            switch (ownAnswer, wait) {
            case (true, let wait?): return L("Asked by \(asker); you answered after \(wait).")
            case (true, nil): return L("Asked by \(asker); you answered.")
            case (false, let wait?): return L("Asked by \(asker); \(decider) answered after \(wait).")
            case (false, nil): return L("Asked by \(asker); \(decider) answered.")
            }
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
            valueColor: isRemote ? theme.status.warning.foreground : theme.status.success.foreground
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
                        valueColor: theme.status.success.foreground
                    )
                } else if log.category == .inference || log.category == .compaction {
                    DetailRow(
                        label: Text("Privacy Filter", bundle: .module),
                        value: L("Not applied"),
                        valueColor: theme.text.secondary
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
        case .workflowRun, .workflowNode: workflowSection
        case .inboundAPI, .pluginCall, .pluginLog, .event, .task: genericDetailsSection
        case .interaction: interactionSection
        }
    }

    @ViewBuilder
    private var interactionSection: some View {
        FlatGroup(icon: log.category.icon, title: Text("Interaction", bundle: .module)) {
            if let kind = details["kind"] {
                DetailRow(label: Text("Kind", bundle: .module), value: RequestLog.interactionKindLabel(kind) ?? kind)
            }
            if let tool = details["tool"] { DetailRow(label: Text("Tool", bundle: .module), value: tool) }
            if log.participant == nil, let requester = details["requester"] {
                DetailRow(label: Text("Requested by", bundle: .module), value: requester)
            }
            if log.agentName == nil, let agent = details["agent"] {
                DetailRow(label: Text("Agent", bundle: .module), value: agent)
            }
            if let address = details["agent_address"] {
                IdentifierRow(label: Text("Agent address", bundle: .module), value: address)
            }
            DetailRow(
                label: Text("Outcome", bundle: .module),
                value: RequestLog.interactionOutcomeLabel(log.method),
                valueColor: log.isError ? theme.status.error.foreground : nil
            )
            if let decider = details["decided_by"] {
                DetailRow(label: Text("Answered by", bundle: .module), value: decider)
            }
            if let surface = details["surface"] {
                DetailRow(
                    label: Text("Answered from", bundle: .module),
                    value: AttentionSurface(rawValue: surface)?.displayName ?? surface
                )
            }
            if details["scope"] == "conversation" {
                DetailRow(label: Text("Applies to", bundle: .module), value: L("The rest of this conversation"))
            }
            if let wait = details["wait_ms"].flatMap(Double.init) {
                DetailRow(label: Text("Waited", bundle: .module), value: RequestLog.formattedDuration(ms: wait))
            }
            if let delivered = details["delivered_to"] {
                DetailRow(
                    label: Text("Notified on", bundle: .module),
                    value: delivered.split(separator: ",").map {
                        NotificationChannelID(rawValue: String($0))?.displayName ?? String($0)
                    }.joined(separator: ", ")
                )
            }
            if let message = details["message"] {
                DetailRow(label: Text("Reply", bundle: .module), value: message)
            }
            if let id = details["attention_id"] {
                IdentifierRow(label: Text("Attention ID", bundle: .module), value: id)
            }
            if let address = details["agent_address"] {
                AgentAddressLinks(address: address)
            }
        }
        let timeline = InteractionTimeline.steps(details: details, method: log.method)
        if !timeline.isEmpty {
            FlatGroup(icon: "clock", title: Text("Timeline", bundle: .module)) {
                ForEach(timeline) { step in
                    DetailRow(label: Text(verbatim: step.label), value: step.value)
                }
            }
        }
    }

    @ViewBuilder
    private var workflowSection: some View {
        FlatGroup(icon: log.category.icon, title: Text("Workflow", bundle: .module)) {
            if let name = details["workflow"] { DetailRow(label: Text("Workflow", bundle: .module), value: name) }
            if let step = details["node_name"] { DetailRow(label: Text("Step", bundle: .module), value: step) }
            if let kind = details["kind"] { DetailRow(label: Text("Step kind", bundle: .module), value: kind) }
            if let status = details["status"] {
                DetailRow(label: Text("Status", bundle: .module), value: RequestLog.workflowStatusLabel(status))
            }
            if let caller = details["caller"] { DetailRow(label: Text("Started by", bundle: .module), value: caller) }
            if let steps = details["steps"] { DetailRow(label: Text("Steps run", bundle: .module), value: steps) }
            if let failed = details["failed_step"] {
                DetailRow(
                    label: Text("Failed at", bundle: .module),
                    value: failed,
                    valueColor: theme.status.error.foreground
                )
            }
            if let attempts = details["attempts"], attempts != "1" {
                DetailRow(label: Text("Attempts", bundle: .module), value: attempts)
            }
            if let folder = details["folder"] { DetailRow(label: Text("Folder", bundle: .module), value: folder) }
            if let urls = details["urls"], !urls.isEmpty {
                DetailRow(label: Text("Requests", bundle: .module), value: urls)
            }
            if let logs = details["logs"], !logs.isEmpty {
                DetailRow(label: Text("Log", bundle: .module), value: logs)
            }
            if let runID = log.workflowRunId { WorkflowRunLinks(runID: runID) }
        }
        if let tools = log.toolCalls, !tools.isEmpty {
            FlatGroup(icon: "wrench.and.screwdriver", title: Text("Tool calls", bundle: .module)) {
                ForEach(tools) { call in
                    DetailRow(
                        label: Text(verbatim: call.name),
                        value: [call.arguments, call.result].compactMap { $0 }.joined(separator: "\n→ "),
                        valueColor: call.isError ? theme.status.error.foreground : nil
                    )
                }
            }
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
                DetailRow(
                    label: Text("Failures", bundle: .module),
                    value: f,
                    valueColor: theme.status.error.foreground
                )
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
                DetailRow(
                    label: Text("Failures", bundle: .module),
                    value: f,
                    valueColor: theme.status.error.foreground
                )
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
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, theme.space.s4)
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
                valueColor: theme.text.secondary
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
                valueColor: theme.text.secondary
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
        if log.workflowRunId != nil, log.category != .workflowRun { parts.append(L("Workflow run")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var whoRows: some View {
        DetailRow(label: Text("Source", bundle: .module), value: log.source.displayName)
        if let participant = log.participant {
            DetailRow(label: Text("Who", bundle: .module), value: ParticipantFormatter.short(participant))
            ForEach(Array(ParticipantFormatter.full(participant).enumerated()), id: \.offset) { _, row in
                DetailRow(label: Text(verbatim: row.label), value: row.value)
            }
            ParticipantLinks(key: participant.key)
        }
        if let name = log.agentName {
            DetailRow(label: Text("Agent", bundle: .module), value: name)
        } else if let id = log.agentId {
            IdentifierRow(label: Text("Agent", bundle: .module), value: id.uuidString)
        }
        if let session = log.sessionId {
            IdentifierRow(label: Text("Session", bundle: .module), value: session.uuidString)
        }
        if let runID = log.workflowRunId {
            IdentifierRow(label: Text("Workflow run", bundle: .module), value: runID.uuidString)
            if let step = log.workflowNodeId, log.category != .workflowNode {
                DetailRow(label: Text("Workflow step", bundle: .module), value: step)
            }
            if log.category != .workflowRun && log.category != .workflowNode {
                WorkflowRunLinks(runID: runID)
            }
        }
        if let taskID = log.taskId {
            IdentifierRow(label: Text("Task", bundle: .module), value: taskID.uuidString)
            TaskLinks(taskID: taskID)
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
            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Tool calls", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.tertiary)
                    .padding(.top, theme.space.s6)
                ForEach(toolCalls) { tool in
                    HStack(alignment: .top, spacing: theme.space.s8) {
                        Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .glyphSize(.micro)
                            .foregroundColor(
                                tool.isError
                                    ? theme.status.error.foreground
                                    : theme.status.success.foreground
                            )
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(tool.name)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                            if !tool.arguments.isEmpty && tool.arguments != "{}" {
                                Text(tool.arguments)
                                    .font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Spacer()
                        if let duration = tool.durationMs {
                            Text(String(format: "%.0fms", duration))
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.tertiary)
                        }
                    }
                    .padding(theme.space.s8)
                    .settingsChrome(.inset)
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
        Text(
            "Each record is chained to the one before it with SHA-256. Use Verify Integrity from the Insights menu to check the whole log.",
            bundle: .module
        )
        .font(SettingsFont.footnote)
        .foregroundColor(theme.text.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, theme.space.s6)
    }

    // MARK: Error

    private func errorSection(_ message: String) -> some View {
        HStack(alignment: .top, spacing: theme.space.s10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.caption)
                .foregroundColor(theme.status.error.foreground)
            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text("Error", bundle: .module)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.status.error.foreground)
                Text(message)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.error))
    }

    private func codeBlock(icon: String, title: Text, code: String) -> some View {
        FlatGroup(icon: icon, title: title) {
            Text(code)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.space.s8)
                .settingsChrome(.inset)
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
        LazyVGrid(columns: columns, alignment: .leading, spacing: theme.space.s12) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(fact.label)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.tertiary)
                    Text(fact.value)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Text(verbatim: fact.help ?? fact.value))
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.surface)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon)
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
                title
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: theme.space.s0) {
                content()
            }
            .padding(.leading, theme.space.s16)
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Button(action: { withAnimation(theme.motion.quick) { isExpanded.toggle() } }) {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "chevron.right")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                    title
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                    if !isExpanded, !summary.isEmpty {
                        Text(summary)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, theme.space.s4)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if isExpanded {
                VStack(alignment: .leading, spacing: theme.space.s0) {
                    content()
                }
                .padding(.leading, theme.space.s16)
            }
        }
        .padding(.vertical, theme.space.s2)
        .overlay(alignment: .top) {
            Divider().background(theme.border.subtle).offset(y: -9)
        }
    }
}

// MARK: - Rows

/// Open the run this row belongs to, or list every row of it.
private struct WorkflowRunLinks: View {
    @Environment(\.theme) private var theme
    let runID: UUID

    var body: some View {
        HStack(spacing: theme.space.s8) {
            if WorkflowRunStore.shared.run(id: runID) != nil {
                InsightsLink(title: "Open Run", icon: "arrow.up.forward.square") {
                    WorkflowRunLauncher.open(runID: runID)
                }
            }
            InsightsLink(title: "All Events for This Run", icon: "line.3.horizontal.decrease.circle") {
                InsightsService.shared.showRun(runID)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, theme.space.s6)
    }
}

private struct TaskLinks: View {
    @Environment(\.theme) private var theme
    let taskID: UUID

    var body: some View {
        HStack(spacing: theme.space.s8) {
            InsightsLink(title: "Open Task", icon: "arrow.up.forward.square") {
                TaskControl.showDetail(taskID)
            }
            InsightsLink(title: "All Events for This Task", icon: "line.3.horizontal.decrease.circle") {
                InsightsService.shared.showTask(taskID)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AgentAddressLinks: View {
    @Environment(\.theme) private var theme
    let address: String

    var body: some View {
        HStack(spacing: theme.space.s8) {
            InsightsLink(title: "All Events for This Agent", icon: "line.3.horizontal.decrease.circle") {
                InsightsService.shared.showAgent(address: address)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Raised, delivered and settled times of an interaction, each with the
/// time since it was raised.
enum InteractionTimeline {
    struct Step: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }

    static func steps(details: [String: String], method: String, timeZone: TimeZone = .current) -> [Step] {
        func date(_ key: String) -> Date? {
            details[key].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        guard let raised = date("raised_at_ms") else { return [] }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        /// "12:00:42 · Paired phone · +42.0s": the time, then where, then
        /// how long after the ask.
        func value(_ at: Date, where place: String? = nil) -> String {
            var parts = [formatter.string(from: at)]
            if let place, !place.isEmpty { parts.append(place) }
            let offset = at.timeIntervalSince(raised)
            if offset >= 0.5 { parts.append("+\(RequestLog.formattedDuration(ms: offset * 1000))") }
            return parts.joined(separator: " · ")
        }
        var steps = [Step(id: "raised", label: L("Asked"), value: formatter.string(from: raised))]
        if let delivered = date("delivered_at_ms") {
            let channels = details["delivered_to"].map {
                $0.split(separator: ",").map { NotificationChannelID(rawValue: String($0))?.displayName ?? String($0) }
                    .joined(separator: ", ")
            }
            steps.append(Step(id: "delivered", label: L("Notified"), value: value(delivered, where: channels)))
        }
        if let settled = date("settled_at_ms") {
            let surface = details["surface"].flatMap(AttentionSurface.init(rawValue:)).flatMap {
                $0 == .system ? nil : $0.displayName
            }
            steps.append(
                Step(
                    id: "settled", label: RequestLog.interactionOutcomeLabel(method),
                    value: value(settled, where: surface)))
        }
        return steps
    }
}

private struct ParticipantLinks: View {
    @Environment(\.theme) private var theme
    let key: String

    var body: some View {
        HStack(spacing: theme.space.s8) {
            InsightsLink(title: "All Events for This Person", icon: "line.3.horizontal.decrease.circle") {
                InsightsService.shared.showParticipant(key)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct InsightsLink: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s4) {
                Image(systemName: icon).glyphSize(.micro, weight: .semibold)
                Text(title, bundle: .module).font(SettingsFont.smallLabel)
            }
            .foregroundColor(theme.text.link)
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s4)
            .settingsChrome(.selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct DetailRow: View {
    @Environment(\.theme) private var theme

    let label: Text
    let value: String
    var valueColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s12) {
            label
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(SettingsFont.monoSmall)
                .foregroundColor(valueColor ?? theme.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, theme.space.s4)
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
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s12) {
            label
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 104, alignment: .leading)
            Button(action: copy) {
                HStack(spacing: theme.space.s4) {
                    Text(Self.shortened(value))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(copied ? theme.status.success.foreground : theme.text.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(Text(verbatim: value))
            Spacer(minLength: 0)
        }
        .padding(.vertical, theme.space.s4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(theme.motion.quick) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(theme.motion.quick) { copied = false }
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
