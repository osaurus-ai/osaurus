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
    struct Summary: Identifiable, Equatable {
        let pluginId: String
        /// User-friendly plugin name, e.g. "Commercial Legal".
        let displayName: String
        /// Source repository slug, e.g. "anthropics/claude-for-legal".
        let sourceLabel: String
        fileprivate let counts: ArtifactCounts

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
        // First scan is deferred to the view's `.onAppear`. Doing the
        // iterate-everything pass synchronously here piles work onto the
        // same runloop tick that presents the Import sheet from a `Menu`
        // button, which on macOS can turn the menu-popover/sheet dismissal
        // race into a hard beachball.
    }

    func refresh() {
        var perPlugin: [String: ArtifactCounts] = [:]

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
        }

        let summaries =
            perPlugin
            .map { id, counts in
                Summary(
                    pluginId: id,
                    displayName: Self.displayName(for: id),
                    sourceLabel: Self.sourceLabel(for: id),
                    counts: counts
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
    /// Coalesces aggregator refreshes during heavy imports — claude-for-legal
    /// lands ~170 skills one-by-one, and refreshing on every tick produced
    /// visible jank behind the import sheet.
    @State private var refreshDebounceTask: Task<Void, Never>?

    var body: some View {
        if aggregator.plugins.isEmpty {
            EmptyView()
        } else {
            content
                .themedAlert(
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
                .onAppear { aggregator.refresh() }
                .onChange(of: skillManager.skills.count) { _, _ in scheduleRefresh() }
                .onChange(of: scheduleManager.schedules.count) { _, _ in scheduleRefresh() }
                .onChange(of: slashCommands.customCommands.count) { _, _ in scheduleRefresh() }
                .onChange(of: mcpManager.configuration.providers.count) { _, _ in
                    scheduleRefresh()
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                VStack(spacing: 6) {
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
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggleExpanded) {
            HStack(spacing: 10) {
                headerGlyph
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Installed Plugins", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("\(aggregator.plugins.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    Text(headerTotals)
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var headerGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.18),
                            theme.accentColor.opacity(0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
        .frame(width: 22, height: 22)
    }

    private var headerTotals: String {
        let parts =
            ArtifactKind.allCases
            .compactMap { kind -> String? in
                let count = aggregator.totals[kind]
                return count > 0 ? kind.label(count: count) : nil
            }
        return parts.isEmpty ? "No artifacts" : parts.joined(separator: " · ")
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
    }

    // MARK: Actions

    private static func confirmMessage(for plugin: InstalledPluginsAggregator.Summary)
        -> String
    {
        let suffix = plugin.totalCount == 1 ? "" : "s"
        return
            "Remove all \(plugin.totalCount) item\(suffix) installed from \(plugin.displayName)? "
            + "This deletes its skills, schedules, slash commands, and MCP providers."
    }

    private func confirmUninstall(_ plugin: InstalledPluginsAggregator.Summary) {
        let label = plugin.displayName
        let total = plugin.totalCount
        Task { @MainActor in
            _ = await ClaudePluginInstaller.shared.uninstall(pluginId: plugin.pluginId)
            await skillManager.refresh()
            aggregator.refresh()
            let suffix = total == 1 ? "" : "s"
            onMessage("Uninstalled \(total) item\(suffix) from \(label)", false)
        }
    }

    /// Debounce aggregator refreshes so a burst of changes (e.g. installing
    /// 170+ skills in a row during a Claude plugin import) only triggers
    /// one re-aggregation after the stream settles.
    private func scheduleRefresh() {
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)  // 200 ms
            guard !Task.isCancelled else { return }
            aggregator.refresh()
        }
    }
}

// MARK: - Row

/// Single plugin row: icon, friendly title + source slug, artifact-type
/// chips, and an uninstall affordance that fades in on hover.
private struct PluginRow: View {
    @Environment(\.theme) private var theme

    let plugin: InstalledPluginsAggregator.Summary
    let onUninstall: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            glyph
            titleStack
            Spacer(minLength: 8)
            chips
            uninstallButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in isHovered = hovering }
        .contextMenu {
            Button(role: .destructive, action: onUninstall) {
                Label("Uninstall", systemImage: "trash")
            }
        }
    }

    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.accentColor.opacity(0.12))
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
        }
        .frame(width: 30, height: 30)
    }

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(plugin.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                Text(plugin.sourceLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(ArtifactKind.allCases, id: \.self) { kind in
                let count = plugin.counts[kind]
                if count > 0 {
                    ArtifactChip(icon: kind.icon, count: count, tint: kind.tint(theme))
                }
            }
        }
    }

    /// Icon-only when not hovered; expands to "🗑 Uninstall" on hover so
    /// the row stays uncluttered when the user isn't aiming for it.
    private var uninstallButton: some View {
        Button(action: onUninstall) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                if isHovered {
                    Text("Uninstall", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .foregroundColor(theme.errorColor)
            .padding(.horizontal, isHovered ? 9 : 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.errorColor.opacity(isHovered ? 0.14 : 0.08))
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .help("Uninstall \(plugin.displayName)")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.primaryBackground.opacity(isHovered ? 0.7 : 0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isHovered ? theme.accentColor.opacity(0.18) : .clear,
                        lineWidth: 1
                    )
            )
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
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}
