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

    @State private var selectedTab: DetailTab = .overview

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

                copyMenu(
                    title: Text("Copy Request", bundle: .module),
                    icon: "doc.on.doc",
                    helpText: Text("Copy request JSON", bundle: .module),
                    localBody: log.formattedRequestBody,
                    serverBody: log.formattedWireRequestBody
                )

                copyMenu(
                    title: Text("Copy Response", bundle: .module),
                    icon: "arrow.down.doc",
                    helpText: Text("Copy response", bundle: .module),
                    localBody: log.formattedResponseBody,
                    serverBody: log.formattedWireResponseBody
                )
            }

            HStack(alignment: .center, spacing: 10) {
                MethodBadgeCompact(method: log.method)
                HTTPStatusBadgeCompact(statusCode: log.statusCode)

                Text(Self.abbreviatedPath(log.path))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(Text(verbatim: log.path))

                Text(log.formattedDuration)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            // Wrap to multiple rows rather than overflowing the pane: a
            // remote-agent run can carry six pills (time, source, model, mode,
            // relay host, secure) whose fixed-size widths exceed a narrow
            // detail pane on one line. `FlowLayout` breaks them onto new rows.
            FlowLayout(spacing: 8) {
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
                if let connection = log.connection {
                    if let mode = connection.mode, mode != .local {
                        metaPill(
                            icon: connectionModeIcon(mode),
                            text: Text(verbatim: mode.displayName),
                            tint: .blue
                        )
                        .help(Text(verbatim: connection.remoteEndpoint ?? mode.displayName))
                    }
                    if let host = connectionHostLabel(connection) {
                        metaPill(
                            icon: "antenna.radiowaves.left.and.right",
                            text: Text(verbatim: host),
                            tint: .blue
                        )
                        .help(Text(verbatim: connection.remoteEndpoint ?? host))
                    }
                    if connection.transport == .secureChannel {
                        metaPill(
                            icon: "lock.fill",
                            text: Text("Secure", bundle: .module),
                            tint: .green
                        )
                        .help(
                            Text(
                                "End-to-end encrypted via Osaurus Secure Channel",
                                bundle: .module
                            )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Copy affordance for Request / Response: collapses to a single
    /// button when only one body exists (no wire capture: HTTP API,
    /// MLX, Foundation, plugins), and expands to a Menu with
    /// explicit Server / Local items when both are present. Hidden
    /// entirely when neither body is captured.
    @ViewBuilder
    private func copyMenu(
        title: Text,
        icon: String,
        helpText: Text,
        localBody: String?,
        serverBody: String?
    ) -> some View {
        if localBody != nil || serverBody != nil {
            if localBody != nil && serverBody != nil {
                Menu {
                    Button(action: { copy(serverBody) }) {
                        Text("insights.body.copy.server", bundle: .module)
                    }
                    Button(action: { copy(localBody) }) {
                        Text("insights.body.copy.local", bundle: .module)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                        title
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground.opacity(0.5))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(helpText)
            } else {
                headerActionButton(
                    title: title,
                    icon: icon,
                    helpText: helpText,
                    action: { copy(serverBody ?? localBody) }
                )
            }
        }
    }

    private func sourceIcon(_ source: RequestSource) -> String {
        switch source {
        case .chatUI: return "bubble.left.and.bubble.right.fill"
        case .agent: return "person.2.fill"
        case .httpAPI: return "network"
        case .plugin: return "puzzlepiece.extension.fill"
        case .p2p: return "antenna.radiowaves.left.and.right"
        case .scheduled: return "clock.arrow.circlepath"
        case .channel: return "bubble.left.and.text.bubble.right.fill"
        case .schedule: return "calendar.badge.clock"
        case .watcher: return "eye.fill"
        case .selfSchedule: return "clock.badge.checkmark.fill"
        case .tool: return "wrench.and.screwdriver.fill"
        case .system: return "gearshape.fill"
        }
    }

    private func connectionModeIcon(_ mode: RequestMode) -> String {
        switch mode {
        case .local: return "cpu"
        case .remoteInference: return "cloud"
        case .remoteAgentRun: return "person.crop.circle.badge.checkmark"
        }
    }

    /// Short host label for the relay/host pill, derived from the connection's
    /// full endpoint URL. Falls back to nil so the pill is omitted when no
    /// endpoint was captured. The raw host is abbreviated by
    /// `InsightsDetailPane.abbreviatedHost` so a long agent address can't blow
    /// out the header row (the full endpoint stays available via the pill's
    /// tooltip).
    private func connectionHostLabel(_ connection: RequestConnectionInfo) -> String? {
        guard let endpoint = connection.remoteEndpoint,
            let host = URL(string: endpoint)?.host
        else { return nil }
        return Self.abbreviatedHost(host)
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
    /// Copy Request action.
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

    /// Tabs that make sense for this row. Non-inference rows (search, MCP,
    /// channel, Router) have no prompt or model params; their facts live in
    /// Overview, with raw bodies still reachable under Request / Response.
    private var availableTabs: [DetailTab] {
        if log.isInference || log.category == .inboundAPI {
            return DetailTab.allCases
        }
        return [.overview, .request, .response]
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
            case .overview: OverviewTab(log: log)
            case .prompt: PromptTab(log: log)
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
    case request
    case response
    case params

    var icon: String {
        switch self {
        case .overview: return "list.bullet.rectangle"
        case .prompt: return "text.bubble"
        case .request: return "arrow.up.circle"
        case .response: return "arrow.down.circle"
        case .params: return "slider.horizontal.3"
        }
    }

    @ViewBuilder
    var label: some View {
        switch self {
        case .overview: Text("Overview", bundle: .module)
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

// MARK: - Params Tab

// MARK: - Overview Tab

/// Plain-language summary for reviewers: what happened, where the data
/// went, who drove it, and how it ended — before any raw JSON. Category-
/// specific sections surface the facts that matter for that kind of row
/// (search query and providers, fetched URLs, MCP server and arguments,
/// channel destination, Router purpose).
private struct OverviewTab: View {
    @Environment(\.theme) private var theme

    let log: RequestLog

    private var details: [String: String] { log.egress?.details ?? [:] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard
                whereSection
                categorySection
                whoSection
                if let error = log.errorMessage {
                    errorSection(error)
                }
                integritySection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let isRemote = log.locality == .remote
        let tint: Color = isRemote ? .orange : .green
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isRemote ? "icloud.and.arrow.up" : "laptopcomputer")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryHeadline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summarySubline)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.2), lineWidth: 1))
        )
    }

    private var summaryHeadline: String {
        let outcome = log.isError ? L("failed") : L("completed")
        switch log.category {
        case .inference:
            return log.locality == .remote
                ? L("Model request sent to \(log.destinationDisplay) — \(outcome)")
                : L("Model ran on this Mac — \(outcome)")
        case .compaction:
            return log.locality == .remote
                ? L("Conversation summary sent to \(log.destinationDisplay) — \(outcome)")
                : L("Conversation summarized on this Mac — \(outcome)")
        case .webSearch:
            return L("Web search sent to \(log.destinationDisplay) — \(outcome)")
        case .urlExtract:
            return details["mode"] == "hosted"
                ? L("Pages fetched through \(log.destinationDisplay) — \(outcome)")
                : L("Page fetched from \(log.destinationDisplay) — \(outcome)")
        case .mcpToolCall:
            return log.locality == .remote
                ? L("Tool call sent to MCP server \(log.destinationDisplay) — \(outcome)")
                : L("Tool call to local MCP server \(log.destinationDisplay) — \(outcome)")
        case .channelDelivery:
            return L("Message delivered to \(log.destinationDisplay) — \(details["outcome"] ?? outcome)")
        case .routerControl:
            return L("\(details["purpose"] ?? L("Router call")) — Osaurus Router — \(outcome)")
        case .inboundAPI:
            return log.source == .p2p
                ? L("Request from a paired peer — \(outcome)")
                : L("Request from an API client — \(outcome)")
        case .pluginCall:
            return L("Plugin call — \(outcome)")
        case .pluginLog:
            return L("Plugin log line")
        case .embedding:
            return log.locality == .remote
                ? L("Embeddings computed by \(log.destinationDisplay) — \(outcome)")
                : L("Embeddings computed on this Mac — \(outcome)")
        case .audioTranscription:
            return log.locality == .remote
                ? L("Audio sent to \(log.destinationDisplay) for transcription — \(outcome)")
                : L("Audio transcribed on this Mac — \(outcome)")
        case .speechSynthesis:
            return log.locality == .remote
                ? L("Text sent to \(log.destinationDisplay) for speech — \(outcome)")
                : L("Speech synthesized on this Mac — \(outcome)")
        case .mediaGeneration:
            return log.locality == .remote
                ? L("Media request sent to \(log.destinationDisplay) — \(outcome)")
                : L("Media generated on this Mac — \(outcome)")
        case .system:
            return log.title
        }
    }

    private var summarySubline: String {
        var parts: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        parts.append(df.string(from: log.timestamp))
        parts.append(log.formattedDuration)
        if let e = log.egress {
            if let b = e.bytesSent, b > 0 { parts.append(L("\(ActivitySummary.formattedBytes(b)) sent")) }
            if let b = e.bytesReceived, b > 0 { parts.append(L("\(ActivitySummary.formattedBytes(b)) received")) }
        }
        if let i = log.inputTokens, let o = log.outputTokens, i + o > 0 {
            parts.append(L("\(i) in / \(o) out tokens"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Where

    @ViewBuilder
    private var whereSection: some View {
        let isRemote = log.locality == .remote
        section(
            icon: isRemote ? "icloud.and.arrow.up" : "lock.laptopcomputer",
            title: Text("Where the data went", bundle: .module),
            tint: isRemote ? .orange : .green
        ) {
            DetailRow(
                label: Text("Locality", bundle: .module),
                value: isRemote ? L("Left this Mac (cloud)") : L("Stayed on this Mac"),
                valueColor: isRemote ? .orange : .green
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
                            valueColor: .green
                        )
                    } else if log.category == .inference || log.category == .compaction {
                        DetailRow(
                            label: Text("Privacy Filter", bundle: .module),
                            value: L("Not applied"),
                            valueColor: theme.secondaryText
                        )
                    }
                }
            } else if let model = log.model {
                DetailRow(label: Text("Model", bundle: .module), value: model)
            }
            if let ip = log.clientIP, log.category == .inboundAPI {
                DetailRow(label: Text("Caller address", bundle: .module), value: ip)
            }
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
        case .inference, .compaction: inferenceSection
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
        section(icon: "magnifyingglass", title: Text("Search", bundle: .module), tint: .blue) {
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
                DetailRow(label: Text("Failures", bundle: .module), value: f, valueColor: .red.opacity(0.8))
            }
        }
        if let preview = details["result_preview"], !preview.isEmpty {
            section(icon: "link", title: Text("Top results", bundle: .module), tint: theme.secondaryText) {
                ForEach(preview.split(separator: "\n").map(String.init), id: \.self) { url in
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private var extractSection: some View {
        section(icon: "doc.text.magnifyingglass", title: Text("Fetched pages", bundle: .module), tint: .blue) {
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
                DetailRow(label: Text("Failures", bundle: .module), value: f, valueColor: .red.opacity(0.8))
            }
        }
        if let urls = details["urls"], !urls.isEmpty {
            section(icon: "link", title: Text("URLs", bundle: .module), tint: theme.secondaryText) {
                ForEach(urls.split(separator: "\n").map(String.init), id: \.self) { url in
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private var mcpSection: some View {
        section(icon: "wrench.and.screwdriver", title: Text("MCP tool call", bundle: .module), tint: .teal) {
            if let s = details["server"] { DetailRow(label: Text("Server", bundle: .module), value: s) }
            if let t = details["tool"] { DetailRow(label: Text("Tool", bundle: .module), value: t) }
            if let e = details["exposed_as"] { DetailRow(label: Text("Exposed as", bundle: .module), value: e) }
            if let t = details["transport"] { DetailRow(label: Text("Transport", bundle: .module), value: t) }
            if let h = details["execution_host"] { DetailRow(label: Text("Runs in", bundle: .module), value: h) }
            if let c = details["command"] { DetailRow(label: Text("Command", bundle: .module), value: c) }
        }
        if let args = details["arguments"], !args.isEmpty {
            codeSection(icon: "arrow.up.circle", title: Text("Arguments sent", bundle: .module), code: args)
        }
        if let result = details["result_preview"], !result.isEmpty {
            codeSection(icon: "arrow.down.circle", title: Text("Result (preview)", bundle: .module), code: result)
        }
    }

    @ViewBuilder
    private var channelSection: some View {
        section(icon: "paperplane", title: Text("Channel delivery", bundle: .module), tint: .blue) {
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
        section(icon: "network", title: Text("Router call", bundle: .module), tint: .blue) {
            if let p = details["purpose"] { DetailRow(label: Text("Purpose", bundle: .module), value: p) }
            DetailRow(label: Text("Method", bundle: .module), value: log.method)
            DetailRow(label: Text("Path", bundle: .module), value: log.path)
            if let q = details["query_string"] { DetailRow(label: Text("Query", bundle: .module), value: q) }
            DetailRow(label: Text("HTTP status", bundle: .module), value: "\(log.statusCode)")
        }
    }

    @ViewBuilder
    private var inferenceSection: some View {
        section(icon: "cpu", title: Text("Model request", bundle: .module), tint: .purple) {
            if let model = log.model { DetailRow(label: Text("Model", bundle: .module), value: model) }
            if let i = log.inputTokens, let o = log.outputTokens {
                DetailRow(label: Text("Tokens", bundle: .module), value: L("\(i) in → \(o) out"))
            }
            if let speed = log.tokensPerSecond, speed > 0 {
                DetailRow(label: Text("Speed", bundle: .module), value: String(format: "%.1f tok/s", speed))
            }
            if let reason = log.finishReason {
                DetailRow(label: Text("Finish reason", bundle: .module), value: reason.rawValue)
            }
            if let tools = log.toolCalls, !tools.isEmpty {
                DetailRow(
                    label: Text("Tool calls", bundle: .module),
                    value: tools.map(\.name).joined(separator: ", ")
                )
            }
            if let mode = log.connection?.mode, mode != .local {
                DetailRow(label: Text("Mode", bundle: .module), value: mode.displayName)
            }
            DetailRow(
                label: Text("Content", bundle: .module),
                value: log.hasStoredContent
                    ? L("Stored — see Prompt / Request / Response")
                    : L("Not stored (Privacy › Activity Log)"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var embeddingSection: some View {
        section(icon: "point.3.connected.trianglepath.dotted", title: Text("Embedding", bundle: .module), tint: .mint) {
            if let model = log.model { DetailRow(label: Text("Model", bundle: .module), value: model) }
            if let n = details["texts"] { DetailRow(label: Text("Texts embedded", bundle: .module), value: n) }
            if let d = details["dims"] { DetailRow(label: Text("Dimensions", bundle: .module), value: d) }
            if let c = details["chars"] { DetailRow(label: Text("Input size", bundle: .module), value: L("\(c) characters")) }
            if let p = details["purpose"] { DetailRow(label: Text("Purpose", bundle: .module), value: p) }
            DetailRow(
                label: Text("Content", bundle: .module),
                value: L("Texts are not copied into the log — only counts and sizes"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        section(icon: "waveform", title: Text("Transcription", bundle: .module), tint: .green) {
            if let model = log.model { DetailRow(label: Text("Model", bundle: .module), value: model) }
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
            DetailRow(
                label: Text("Content", bundle: .module),
                value: log.hasStoredContent
                    ? L("Transcript stored — see Response")
                    : L("Transcript not stored (Privacy › Activity Log)"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var speechSection: some View {
        section(icon: "speaker.wave.2", title: Text("Speech synthesis", bundle: .module), tint: .yellow) {
            if let model = log.model { DetailRow(label: Text("Model / voice", bundle: .module), value: model) }
            if let v = details["voice"] { DetailRow(label: Text("Voice", bundle: .module), value: v) }
            if let c = details["chars"] { DetailRow(label: Text("Text size", bundle: .module), value: L("\(c) characters")) }
            if let a = details["audio_seconds"] { DetailRow(label: Text("Audio produced", bundle: .module), value: L("\(a) s")) }
            if let p = details["provider"] { DetailRow(label: Text("Provider", bundle: .module), value: p) }
            if let t = details["trigger"] { DetailRow(label: Text("Triggered by", bundle: .module), value: t) }
            if details["cancelled"] == "true" {
                DetailRow(label: Text("Playback", bundle: .module), value: L("Stopped by the user before it finished"))
            }
            DetailRow(
                label: Text("Content", bundle: .module),
                value: log.hasStoredContent
                    ? L("Spoken text stored — see Request")
                    : L("Spoken text not stored (Privacy › Activity Log)"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var mediaSection: some View {
        section(icon: "photo.on.rectangle.angled", title: Text("Media generation", bundle: .module), tint: .pink) {
            if let model = log.model { DetailRow(label: Text("Model", bundle: .module), value: model) }
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
            DetailRow(
                label: Text("Content", bundle: .module),
                value: log.hasStoredContent
                    ? L("Prompt stored — see Request")
                    : L("Prompt not stored (Privacy › Activity Log)"),
                valueColor: theme.secondaryText
            )
        }
    }

    @ViewBuilder
    private var systemEventSection: some View {
        section(icon: "checkmark.shield", title: Text("Chain of custody", bundle: .module), tint: theme.secondaryText) {
            if let summary = log.systemEventSummary {
                DetailRow(label: Text("What happened", bundle: .module), value: summary)
            }
            ForEach(details.keys.sorted().filter { $0 != "event" }, id: \.self) { key in
                DetailRow(label: Text(verbatim: Self.systemDetailLabel(key)), value: details[key] ?? "")
            }
        }
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
        if !details.isEmpty {
            section(icon: "info.circle", title: Text("Details", bundle: .module), tint: theme.secondaryText) {
                ForEach(details.keys.sorted(), id: \.self) { key in
                    DetailRow(label: Text(verbatim: key), value: details[key] ?? "")
                }
            }
        }
    }

    // MARK: Who

    @ViewBuilder
    private var whoSection: some View {
        section(icon: "person.crop.circle", title: Text("Who drove this", bundle: .module), tint: theme.secondaryText) {
            DetailRow(label: Text("Source", bundle: .module), value: log.source.displayName)
            if let name = log.agentName {
                DetailRow(label: Text("Agent", bundle: .module), value: name)
            } else if let id = log.agentId {
                DetailRow(label: Text("Agent", bundle: .module), value: id.uuidString)
            }
            if let session = log.sessionId {
                DetailRow(label: Text("Session", bundle: .module), value: session.uuidString)
            }
            if let turn = log.turnId {
                DetailRow(label: Text("Turn", bundle: .module), value: turn.uuidString)
            }
            if let parent = log.egress?.details["parent_turn_id"] {
                DetailRow(label: Text("Delegated from turn", bundle: .module), value: parent)
            }
            if let rid = log.requestId {
                DetailRow(label: Text("Request ID", bundle: .module), value: rid)
            }
            if let plugin = log.pluginId {
                DetailRow(label: Text("Plugin", bundle: .module), value: plugin)
            }
            if let ua = log.userAgent {
                DetailRow(label: Text("User agent", bundle: .module), value: ua)
            }
            if let key = log.connection?.accessKeyId {
                DetailRow(label: Text("Access key", bundle: .module), value: key)
            }
            if let aud = log.connection?.audience {
                DetailRow(label: Text("Audience", bundle: .module), value: aud)
            }
        }
    }

    // MARK: Error / integrity

    private func errorSection(_ message: String) -> some View {
        section(icon: "exclamationmark.triangle.fill", title: Text("Error", bundle: .module), tint: .red) {
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.red.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var integritySection: some View {
        if let seq = log.seq {
            section(icon: "checkmark.seal", title: Text("Log integrity", bundle: .module), tint: theme.secondaryText) {
                DetailRow(label: Text("Record", bundle: .module), value: "#\(seq)")
                if let hash = log.hash {
                    DetailRow(label: Text("Hash", bundle: .module), value: hash)
                }
                if let prev = log.prevHash {
                    DetailRow(label: Text("Previous", bundle: .module), value: prev)
                }
                Text("Each record is chained to the one before it with SHA-256. Use Verify on the Insights page to check the whole log.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(
        icon: String,
        title: Text,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint)
                title
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.15), lineWidth: 1))
            )
        }
    }

    private func codeSection(icon: String, title: Text, code: String) -> some View {
        section(icon: icon, title: title, tint: theme.secondaryText) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                if let connection = log.connection {
                    connectionSection(connection)
                }
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

    /// Connection + attribution details for a remote run (outbound relay/host,
    /// transport, mode) or an attributed inbound request (access key + audience).
    private func connectionSection(_ connection: RequestConnectionInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                icon: "antenna.radiowaves.left.and.right",
                text: Text("Connection", bundle: .module),
                color: .blue
            )

            VStack(spacing: 0) {
                if let mode = connection.mode {
                    DetailRow(label: Text("Mode", bundle: .module), value: mode.displayName)
                }
                if let transport = connection.transport {
                    DetailRow(
                        label: Text("Transport", bundle: .module),
                        value: transport.displayName
                    )
                }
                if let endpoint = connection.remoteEndpoint {
                    DetailRow(label: Text("Endpoint", bundle: .module), value: endpoint)
                }
                if let audience = connection.audience {
                    DetailRow(label: Text("Audience", bundle: .module), value: audience)
                }
                if let keyId = connection.accessKeyId {
                    DetailRow(label: Text("Access Key", bundle: .module), value: keyId)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.15), lineWidth: 1)
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
