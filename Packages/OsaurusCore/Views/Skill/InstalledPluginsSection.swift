//
//  InstalledPluginsSection.swift
//  osaurus
//
//  A management surface for plugins installed by the Claude plugin
//  importer. Aggregates the four backing stores (skills, schedules,
//  slash commands, MCP providers) by their shared `pluginId` and
//  exposes a one-click uninstall.
//
//  Rendered at the top of `SkillsView` when any plugin-tagged artifacts
//  exist. Stays invisible otherwise so the skill list still feels like
//  the primary surface for users who haven't imported a Claude plugin.
//

import SwiftUI

// MARK: - Layout constants

/// Magic-number repository for this file. Keeping them in one place
/// makes it easy to tweak the section's overall density without
/// hunting through view bodies.
private enum Metrics {
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 4

    static let headerCornerRadius: CGFloat = 9
    static let headerHPadding: CGFloat = 10
    static let headerVPadding: CGFloat = 9
    static let headerGlyphSize: CGFloat = 26

    static let rowCornerRadius: CGFloat = 7
    static let rowHPadding: CGFloat = 10
    static let rowVPadding: CGFloat = 7
    static let rowGlyphSize: CGFloat = 24

    /// Time the aggregator waits for a burst of model changes to settle
    /// before re-aggregating. Sized for the worst-case import (≈170 skills
    /// trickling in one-by-one from claude-for-legal).
    static let refreshDebounce: Duration = .milliseconds(200)

    static let expandAnimation: Animation = .easeInOut(duration: 0.18)
    static let hoverAnimation: Animation = .easeInOut(duration: 0.15)
}

// MARK: - Artifact kind

/// The four artifact families a Claude plugin can install. Centralising
/// the display metadata here keeps the row chips and header totals in
/// sync, and lets the aggregator drive its bookkeeping from a single
/// `KeyPath`-indexed counter type.
private enum ArtifactKind: CaseIterable {
    case skill
    case schedule
    case command
    case mcp

    var icon: String {
        switch self {
        case .skill: return "sparkles"
        case .schedule: return "calendar.badge.clock"
        case .command: return "text.bubble.fill"
        case .mcp: return "antenna.radiowaves.left.and.right"
        }
    }

    func tint(_ theme: any ThemeProtocol) -> Color {
        switch self {
        case .skill: return theme.accentColor
        case .schedule: return .orange
        case .command: return .blue
        case .mcp: return .purple
        }
    }

    /// Human-readable count string, with appropriate pluralisation.
    /// "MCP" is treated as an acronym (no plural form).
    func label(count: Int) -> String {
        switch self {
        case .mcp: return "\(count) MCP"
        case .skill: return "\(count) skill\(count == 1 ? "" : "s")"
        case .schedule: return "\(count) schedule\(count == 1 ? "" : "s")"
        case .command: return "\(count) command\(count == 1 ? "" : "s")"
        }
    }
}

/// Per-kind counters, indexed via key paths so a single helper can
/// increment any field. `Equatable` so the aggregator can avoid
/// publishing no-op updates.
private struct ArtifactCounts: Equatable {
    var skill = 0
    var schedule = 0
    var command = 0
    var mcp = 0

    var total: Int { skill + schedule + command + mcp }

    subscript(kind: ArtifactKind) -> Int {
        switch kind {
        case .skill: return skill
        case .schedule: return schedule
        case .command: return command
        case .mcp: return mcp
        }
    }

    static func + (lhs: ArtifactCounts, rhs: ArtifactCounts) -> ArtifactCounts {
        ArtifactCounts(
            skill: lhs.skill + rhs.skill,
            schedule: lhs.schedule + rhs.schedule,
            command: lhs.command + rhs.command,
            mcp: lhs.mcp + rhs.mcp
        )
    }
}

// MARK: - Aggregator

/// Aggregates installed-plugin artifacts across the four managers that
/// participate in Claude plugin imports. Observes each manager's
/// published state so the section refreshes automatically after an
/// install or uninstall.
@MainActor
final class InstalledPluginsAggregator: ObservableObject {
    /// Lightweight projection of a stdio MCP provider so the row UI can
    /// render command + execution-host badge + Restart without binding
    /// directly to `MCPProvider` (which is mutable and pulls in the
    /// providers array as a publishing source).
    struct InstalledStdioMCP: Identifiable, Equatable {
        let id: UUID
        /// e.g. `MyPlugin: server-everything`.
        let name: String
        let command: String
        let args: [String]
        let executionHost: MCPProviderExecutionHost

        /// `npx -y @scope/server-everything` style display string.
        var commandLine: String {
            args.isEmpty ? command : "\(command) \(args.joined(separator: " "))"
        }
    }

    struct Summary: Identifiable, Equatable {
        let pluginId: String
        /// User-friendly plugin name, e.g. "Commercial Legal".
        let displayName: String
        /// Source repository slug, e.g. "anthropics/claude-for-legal".
        let sourceLabel: String
        fileprivate let counts: ArtifactCounts
        /// Stdio MCP providers tagged with this plugin id. The expanded
        /// row exposes per-server command + Restart so users don't have
        /// to dig into the MCP tab to bounce a flaky subprocess.
        let stdioMCPs: [InstalledStdioMCP]

        var id: String { pluginId }
        var totalCount: Int { counts.total }
    }

    @Published private(set) var plugins: [Summary] = []
    @Published fileprivate private(set) var totals = ArtifactCounts()

    private let skillManager: SkillManager
    private let scheduleManager: ScheduleManager
    private let slashCommands: SlashCommandRegistry
    private let mcpManager: MCPProviderManager

    init(
        skillManager: SkillManager = .shared,
        scheduleManager: ScheduleManager = .shared,
        slashCommands: SlashCommandRegistry = .shared,
        mcpManager: MCPProviderManager = .shared
    ) {
        self.skillManager = skillManager
        self.scheduleManager = scheduleManager
        self.slashCommands = slashCommands
        self.mcpManager = mcpManager
        // First scan is deferred to the next runloop tick: running it
        // synchronously in `init` piles work onto the same tick that
        // presents the Import sheet from a Menu button and beachballs.
        // Owning the kick-off here (rather than relying on the view's
        // `.onAppear`) also means an empty initial state can't strand
        // the section invisible.
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        var perPlugin: [String: ArtifactCounts] = [:]
        var perPluginStdio: [String: [InstalledStdioMCP]] = [:]

        func bump(_ pluginId: String?, _ field: WritableKeyPath<ArtifactCounts, Int>) {
            guard let pluginId, Self.isClaudePluginId(pluginId) else { return }
            perPlugin[pluginId, default: ArtifactCounts()][keyPath: field] += 1
        }

        for skill in skillManager.skills {
            bump(skill.pluginId, \.skill)
        }
        for schedule in scheduleManager.schedules {
            bump(schedule.parameters[ScheduleManager.pluginIdParameterKey], \.schedule)
        }
        for command in slashCommands.customCommands {
            bump(command.pluginId, \.command)
        }
        for provider in mcpManager.configuration.providers {
            bump(provider.pluginId, \.mcp)
            if let pluginId = provider.pluginId,
                Self.isClaudePluginId(pluginId),
                provider.transport == .stdio
            {
                perPluginStdio[pluginId, default: []].append(
                    InstalledStdioMCP(
                        id: provider.id,
                        name: provider.name,
                        command: provider.command,
                        args: provider.args,
                        executionHost: provider.executionHost
                    )
                )
            }
        }

        let summaries =
            perPlugin
            .map { id, counts in
                Summary(
                    pluginId: id,
                    displayName: Self.displayName(for: id),
                    sourceLabel: Self.sourceLabel(for: id),
                    counts: counts,
                    stdioMCPs: (perPluginStdio[id] ?? []).sorted { $0.name < $1.name }
                )
            }
            .sorted { $0.displayName < $1.displayName }

        let aggregate = perPlugin.values.reduce(ArtifactCounts(), +)

        if summaries != plugins { plugins = summaries }
        if aggregate != totals { totals = aggregate }
    }

    // MARK: Plugin id helpers

    /// Limit aggregation to Claude plugins installed by the Claude plugin
    /// importer. Osaurus has its own internal plugin system (`PluginManager`)
    /// whose skills are tagged with ids like `osaurus.browser` or
    /// `ai.osaurus.<name>`; those are managed elsewhere and must not show
    /// up under the Claude plugin uninstall surface.
    static func isClaudePluginId(_ id: String) -> Bool {
        id.hasPrefix("github:")
    }

    /// Friendly title-cased plugin name. `github:owner/repo/my-plugin`
    /// becomes "My Plugin". Falls back to the raw id when the format is
    /// unexpected.
    static func displayName(for pluginId: String) -> String {
        guard let parts = githubIdComponents(pluginId) else { return pluginId }
        return
            parts.plugin
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// `owner/repo` slug from `github:owner/repo/plugin`.
    static func sourceLabel(for pluginId: String) -> String {
        guard let parts = githubIdComponents(pluginId) else { return pluginId }
        return "\(parts.owner)/\(parts.repo)"
    }

    private static func githubIdComponents(_ id: String) -> (
        owner: String, repo: String, plugin: String
    )? {
        guard id.hasPrefix("github:") else { return nil }
        let tail = id.dropFirst("github:".count)
        let parts = tail.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

// MARK: - Section View

/// Header + list of installed Claude plugin bundles, with one-click
/// uninstall. Renders nothing when no plugin-tagged artifacts exist.
struct InstalledPluginsSection: View {
    @Environment(\.theme) private var theme
    @StateObject private var aggregator = InstalledPluginsAggregator()

    // `SkillManager`, `ScheduleManager`, and `SlashCommandRegistry` use
    // Swift's Observation framework (`@Observable`); SwiftUI re-renders this
    // view automatically when their state is read inside the body, so plain
    // references suffice. `MCPProviderManager` still conforms to the older
    // `ObservableObject` protocol, which is why it needs an explicit
    // `@ObservedObject` wrapper to participate in invalidation.
    private let skillManager = SkillManager.shared
    private let scheduleManager = ScheduleManager.shared
    private let slashCommands = SlashCommandRegistry.shared
    @ObservedObject private var mcpManager = MCPProviderManager.shared

    let onMessage: (String, Bool) -> Void

    @State private var pendingUninstall: InstalledPluginsAggregator.Summary?
    @State private var isExpanded = true
    @State private var isHeaderHovered = false
    /// Coalesces aggregator refreshes during heavy imports — claude-for-legal
    /// lands ~170 skills one-by-one, and refreshing on every tick produced
    /// visible jank behind the import sheet.
    @State private var refreshDebounceTask: Task<Void, Never>?

    var body: some View {
        // `.onAppear` and `.onChange` are attached to the outer Group
        // rather than to `content` so they fire even on the initial empty
        // render. Attaching them inside the `if` branch breaks first-time
        // population — see SkillsView regression history.
        Group {
            if !aggregator.plugins.isEmpty {
                content.themedAlert(
                    "Uninstall plugin?",
                    isPresented: Binding(
                        get: { pendingUninstall != nil },
                        set: { if !$0 { pendingUninstall = nil } }
                    ),
                    message: pendingUninstall.map(Self.confirmMessage(for:)) ?? "",
                    primaryButton: .destructive("Uninstall") {
                        if let target = pendingUninstall { confirmUninstall(target) }
                        pendingUninstall = nil
                    },
                    secondaryButton: .cancel("Cancel")
                )
            }
        }
        .onAppear { aggregator.refresh() }
        .onChange(of: skillManager.skills.count) { _, _ in scheduleRefresh() }
        .onChange(of: scheduleManager.schedules.count) { _, _ in scheduleRefresh() }
        .onChange(of: slashCommands.customCommands.count) { _, _ in scheduleRefresh() }
        .onChange(of: mcpManager.configuration.providers.count) { _, _ in
            scheduleRefresh()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                pluginList
            }
        }
        .padding(Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cardCornerRadius)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var pluginList: some View {
        VStack(spacing: 4) {
            ForEach(aggregator.plugins) { plugin in
                PluginRow(
                    plugin: plugin,
                    onUninstall: { pendingUninstall = plugin }
                )
            }
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            )
        )
    }

    // MARK: Header

    /// The whole header row is one accordion toggle. `contentShape` makes
    /// the gaps between icon/label/chevron clickable too — without it the
    /// user can only land on the literal subviews.
    private var header: some View {
        HStack(spacing: 10) {
            headerGlyph
            headerLabels
            Spacer(minLength: 8)
            chevron
        }
        .padding(.horizontal, Metrics.headerHPadding)
        .padding(.vertical, Metrics.headerVPadding)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Metrics.headerCornerRadius)
                .fill(theme.primaryBackground.opacity(isHeaderHovered ? 0.35 : 0))
        )
        .onHover(perform: handleHeaderHover)
        .onTapGesture { toggleExpanded() }
        .animation(Metrics.hoverAnimation, value: isHeaderHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(localized: "Installed Plugins, \(aggregator.plugins.count)"))
        .accessibilityHint(Text(isExpanded ? "Collapse list" : "Expand list"))
    }

    private var headerLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Installed Plugins", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("\(aggregator.plugins.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
            }
            Text(headerTotals)
                .font(.system(size: 10.5))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var headerGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.22),
                            theme.accentColor.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
        .frame(width: Metrics.headerGlyphSize, height: Metrics.headerGlyphSize)
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(theme.secondaryText)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .animation(Metrics.expandAnimation, value: isExpanded)
            .padding(6)
            .background(
                Circle().fill(theme.primaryBackground.opacity(isHeaderHovered ? 0.6 : 0))
            )
    }

    private var headerTotals: String {
        let parts = ArtifactKind.allCases.compactMap { kind -> String? in
            let count = aggregator.totals[kind]
            return count > 0 ? kind.label(count: count) : nil
        }
        return parts.isEmpty ? "No artifacts" : parts.joined(separator: " · ")
    }

    private func handleHeaderHover(_ hovering: Bool) {
        isHeaderHovered = hovering
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func toggleExpanded() {
        withAnimation(Metrics.expandAnimation) { isExpanded.toggle() }
    }

    // MARK: Actions

    private static func confirmMessage(for plugin: InstalledPluginsAggregator.Summary)
        -> String
    {
        let items = pluralize(plugin.totalCount, "item")
        return """
            Remove all \(items) installed from \(plugin.displayName)? \
            This deletes its skills, schedules, slash commands, and MCP providers.
            """
    }

    private func confirmUninstall(_ plugin: InstalledPluginsAggregator.Summary) {
        let label = plugin.displayName
        let items = Self.pluralize(plugin.totalCount, "item")
        Task { @MainActor in
            _ = await ClaudePluginInstaller.shared.uninstall(pluginId: plugin.pluginId)
            await skillManager.refresh()
            aggregator.refresh()
            onMessage("Uninstalled \(items) from \(label)", false)
        }
    }

    /// Debounce aggregator refreshes so a burst of changes (e.g. installing
    /// 170+ skills in a row during a Claude plugin import) only triggers
    /// one re-aggregation after the stream settles.
    private func scheduleRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: Metrics.refreshDebounce)
            guard !Task.isCancelled else { return }
            aggregator.refresh()
        }
    }

    private static func pluralize(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

// MARK: - Row

/// Single plugin row: icon, friendly title + source slug, artifact-type
/// chips, and an uninstall affordance that fades in on hover.
/// Plugins that ship stdio MCP servers also get an inline expander that
/// reveals per-server command + Restart so users don't have to navigate
/// to the MCP tab to bounce a flaky subprocess.
private struct PluginRow: View {
    @Environment(\.theme) private var theme

    let plugin: InstalledPluginsAggregator.Summary
    let onUninstall: () -> Void

    @State private var isHovered = false
    @State private var isExpanded = false

    private var hasStdioMCPs: Bool { !plugin.stdioMCPs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if hasStdioMCPs {
                    expandToggle
                } else {
                    Spacer().frame(width: 14)
                }
                glyph
                titleStack
                Spacer(minLength: 8)
                chips
                uninstallButton
            }
            .padding(.horizontal, Metrics.rowHPadding)
            .padding(.vertical, Metrics.rowVPadding)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasStdioMCPs {
                    withAnimation(Metrics.expandAnimation) { isExpanded.toggle() }
                }
            }

            if isExpanded && hasStdioMCPs {
                stdioMCPList
                    .padding(.leading, 36)
                    .padding(.trailing, Metrics.rowHPadding)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.rowCornerRadius)
                .fill(theme.primaryBackground.opacity(isHovered ? 0.55 : 0))
        )
        .animation(Metrics.hoverAnimation, value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .contextMenu {
            Button(role: .destructive, action: onUninstall) {
                Label(localized: "Uninstall", systemImage: "trash")
            }
        }
    }

    private var expandToggle: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.secondaryText)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(Metrics.expandAnimation, value: isExpanded)
            .frame(width: 14)
    }

    private var stdioMCPList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plugin.stdioMCPs) { server in
                StdioMCPRow(server: server)
            }
        }
    }

    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentColor.opacity(0.12))
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
        .frame(width: Metrics.rowGlyphSize, height: Metrics.rowGlyphSize)
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(plugin.displayName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Text(plugin.sourceLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var chips: some View {
        HStack(spacing: 3) {
            ForEach(ArtifactKind.allCases, id: \.self) { kind in
                let count = plugin.counts[kind]
                if count > 0 {
                    ArtifactChip(icon: kind.icon, count: count, tint: kind.tint(theme))
                }
            }
        }
    }

    /// Icon at rest; expands to show the "Uninstall" label on row hover
    /// so the destructive action is obvious without crowding the resting
    /// state.
    private var uninstallButton: some View {
        Button(action: onUninstall) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                if isHovered {
                    Text("Uninstall", bundle: .module)
                        .font(.system(size: 10.5, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .foregroundColor(theme.errorColor)
            .padding(.horizontal, isHovered ? 8 : 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.errorColor.opacity(isHovered ? 0.16 : 0.08))
            )
            .animation(Metrics.hoverAnimation, value: isHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .localizedHelp("Uninstall \(plugin.displayName)")
    }
}

// MARK: - Stdio MCP row

/// Per-server row shown under an expanded `PluginRow`. Renders the
/// command line (middle-truncated so the binary stays visible), the
/// execution-host badge, and a Restart button that bounces the
/// subprocess via `MCPProviderManager.reconnect`.
private struct StdioMCPRow: View {
    @Environment(\.theme) private var theme

    let server: InstalledPluginsAggregator.InstalledStdioMCP

    @State private var isRestarting = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(server.commandLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            executionHostBadge
            restartButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.primaryBackground.opacity(0.35))
        )
    }

    private var executionHostBadge: some View {
        let isSandbox = server.executionHost == .sandbox
        return Text(isSandbox ? "Sandbox" : "Host")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(isSandbox ? theme.accentColor : .orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(
                        (isSandbox ? theme.accentColor : .orange).opacity(0.14)
                    )
            )
    }

    private var restartButton: some View {
        Button(action: restart) {
            HStack(spacing: 3) {
                if isRestarting {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text("Restart", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.accentColor.opacity(0.12))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isRestarting)
        .localizedHelp("Restart the stdio MCP subprocess")
    }

    private func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        Task { @MainActor in
            // Swallow errors here — the provider card itself surfaces
            // failures via `MCPProviderState.lastError`, and the user is
            // about to scroll to it anyway. Failing silently in this row
            // beats showing two competing error messages.
            try? await MCPProviderManager.shared.reconnect(providerId: server.id)
            isRestarting = false
        }
    }
}

// MARK: - Chip

/// Small pill showing an artifact-type icon plus its count.
private struct ArtifactChip: View {
    let icon: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}
