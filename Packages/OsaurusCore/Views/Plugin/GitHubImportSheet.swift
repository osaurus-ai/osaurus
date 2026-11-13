//
//  GitHubImportSheet.swift
//  osaurus
//
//  Sheet for importing Claude plugins / skills from GitHub
//  repositories. Owned by the Plugins tab — historically lived under
//  `Views/Skill/` while Claude plugins were grouped with skills.
//

import SwiftUI

// MARK: - GitHub Import Sheet

struct GitHubImportSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var gitHubService = GitHubSkillService.shared

    let onImport: ([Skill]) -> Void
    let onCancel: () -> Void
    /// Optional callback for the richer "Claude plugin" install path. The
    /// sheet does the install itself; this callback fires once with the report
    /// so the caller can refresh dependent views (skills list, slash commands,
    /// etc.).
    var onPluginInstallComplete: ((ClaudePluginInstallReport) -> Void)? = nil

    // MARK: - State

    enum ImportState {
        case urlInput
        case loading
        case skillSelection(GitHubSkillsResult)
        case pluginSelection(GitHubPluginsResult)
        case importing(progress: Int, total: Int)
        case installComplete(ClaudePluginInstallReport)
        case error(GitHubSkillError)
    }

    @State private var urlInput: String = ""
    @State private var importState: ImportState = .urlInput
    @State private var selectedSkillPaths: Set<String> = []
    /// Selected plugins by name for the new-style flow.
    @State private var selectedPluginNames: Set<String> = []
    /// Whether to attach CLAUDE.md to imported skills.
    @State private var attachClaudeMd: Bool = true
    /// Whether to also import HTTP/SSE MCP servers from each plugin's `.mcp.json`.
    @State private var importMCPProviders: Bool = true
    /// Cross-plugin dependency graph populated in the background after the
    /// plugin list loads — see `loadDependencyGraph(for:)`. Empty by default
    /// so the picker behaves exactly as before for repos where no agent
    /// invokes a sibling skill.
    @State private var pluginDependencies: PluginDependencyGraph =
        PluginDependencyGraph(dependencies: [:])
    /// `displayName` of the plugin (if any) whose toggle triggered the most
    /// recent cascade of dependency-driven auto-selections. Drives the small
    /// "Selected because <name> invokes them" footer next to the plugin list.
    @State private var lastAutoSelectionSource: String? = nil
    /// Plugins that were auto-checked by the dependency graph since the last
    /// fresh toggle — kept separately so the footer can name them.
    @State private var lastAutoSelectedPlugins: [String] = []
    @State private var hasAppeared = false
    @State private var activeTask: Task<Void, Never>?
    @State private var dependencyResolverTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        VStack(spacing: theme.space.s0) {
            headerView
            contentView
            footerView
        }
        .fittedSheetFrame(width: 560, height: 540)
        .background(theme.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .themeElevation(theme.elevation.overlay)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.96)
        .animation(theme.motion.springAnimation, value: hasAppeared)
        .onAppear {
            withAnimation { hasAppeared = true }
        }
        .onDisappear {
            activeTask?.cancel()
            activeTask = nil
            dependencyResolverTask?.cancel()
            dependencyResolverTask = nil
        }
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsSheetHeader(
            icon: headerIcon,
            title: LocalizedStringKey(headerTitle),
            subtitleText: headerSubtitle,
            onClose: cancel
        )
    }

    private var headerIcon: String {
        switch importState {
        case .urlInput, .loading: return "link"
        case .skillSelection: return "sparkles"
        case .pluginSelection: return "shippingbox.fill"
        case .importing: return "arrow.down.circle"
        case .installComplete: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var headerTitle: String {
        switch importState {
        case .urlInput: return L("Import from GitHub")
        case .loading: return L("Connecting...")
        case .skillSelection(let result): return result.repoName
        case .pluginSelection(let result): return result.repoName
        case .importing: return L("Importing...")
        case .installComplete: return L("Import Complete")
        case .error: return L("Import Failed")
        }
    }

    private var headerSubtitle: String {
        switch importState {
        case .urlInput: return L("Paste a repository URL to get started")
        case .loading: return L("Fetching repository information")
        case .skillSelection(let result):
            return result.skills.count == 1
                ? L("1 skill available")
                : L("\(result.skills.count) skills available")
        case .pluginSelection(let result):
            return result.plugins.count == 1
                ? L("1 plugin available")
                : L("\(result.plugins.count) plugins available")
        case .importing: return L("Installing selected plugins")
        case .installComplete(let report):
            let totals =
                report.totalImportedSkills + report.totalImportedAgents
                + report.totalImportedCommands + report.totalImportedMCPProviders
            return totals == 1 ? L("1 item installed") : L("\(totals) items installed")
        case .error(let error): return error.localizedDescription
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch importState {
        case .urlInput:
            urlInputView
        case .loading:
            loadingView
        case .skillSelection(let result):
            skillSelectionView(result)
        case .pluginSelection(let result):
            pluginSelectionView(result)
        case .importing(let progress, let total):
            importingView(progress: progress, total: total)
        case .installComplete(let report):
            installCompleteView(report)
        case .error(let error):
            errorView(error)
        }
    }

    // MARK: - URL Input View

    private var urlInputView: some View {
        VStack(spacing: theme.space.s0) {
            Spacer()

            VStack(spacing: theme.space.s24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(theme.status.info.background)
                        .frame(width: 72, height: 72)

                    Circle()
                        .fill(theme.status.info.background)
                        .frame(width: 56, height: 56)

                    Image(systemName: "link.badge.plus")
                        .glyphSize(.xxlarge, weight: .medium)
                        .foregroundColor(theme.text.link)
                }

                VStack(spacing: theme.space.s8) {
                    Text("Enter Repository URL", bundle: .module)
                        .font(SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)

                    Text("Import skills from any GitHub repository", bundle: .module)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                }

                // URL input field
                SettingsTextField(
                    placeholder: L("github.com/owner/repository"),
                    text: $urlInput,
                    icon: "link",
                    onSubmit: fetchSkills
                )
                .frame(maxWidth: 360)
            }

            Spacer()
        }
        .padding(theme.space.s24)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: theme.space.s16) {
            Spacer()

            SettingsSpinner(size: .large, tint: theme.action.primary.default.background)

            Text("Fetching skills...", bundle: .module)
                .font(SettingsFont.body)
                .foregroundColor(theme.text.secondary)

            Spacer()
        }
    }

    // MARK: - Skill Selection View

    private func skillSelectionView(_ result: GitHubSkillsResult) -> some View {
        VStack(spacing: theme.space.s0) {
            // Repository info card
            HStack(spacing: theme.space.s10) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(
                            LinearGradient(
                                colors: [theme.surface.pressed, theme.surface.raised],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "folder.fill")
                        .glyphSize(.body, weight: .medium)
                        .foregroundColor(theme.text.link)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    if let description = result.repoDescription {
                        Text(description)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                StatusChip(L("\(selectedSkillPaths.count) selected"), tone: .accent)
            }
            .padding(theme.space.s12)
            .settingsChrome(.surface)
            .padding(.horizontal, theme.space.s16)
            .padding(.top, theme.space.s12)
            .padding(.bottom, theme.space.s8)

            // Select all header
            HStack {
                Button(action: {
                    withAnimation(theme.motion.quick) {
                        if selectedSkillPaths.count == result.skills.count {
                            selectedSkillPaths.removeAll()
                        } else {
                            selectedSkillPaths = Set(result.skills.map(\.path))
                        }
                    }
                }) {
                    HStack(spacing: theme.space.s8) {
                        Image(
                            systemName: selectedSkillPaths.count == result.skills.count
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .textStyle(.label)
                        .foregroundColor(
                            selectedSkillPaths.count == result.skills.count
                                ? theme.action.primary.default.background : theme.text.tertiary
                        )

                        Text("Select All", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Text("\(result.skills.count) skill\(result.skills.count == 1 ? "" : "s")", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s8)

            // Skills list
            ScrollView {
                LazyVStack(spacing: theme.space.s4) {
                    ForEach(result.skills) { skill in
                        GitHubSkillSelectionRow(
                            skill: skill,
                            isSelected: selectedSkillPaths.contains(skill.path)
                        ) {
                            withAnimation(theme.motion.quick) {
                                if selectedSkillPaths.contains(skill.path) {
                                    selectedSkillPaths.remove(skill.path)
                                } else {
                                    selectedSkillPaths.insert(skill.path)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.bottom, theme.space.s8)
            }
        }
    }

    // MARK: - Plugin Selection View (new-style marketplaces)

    private func pluginSelectionView(_ result: GitHubPluginsResult) -> some View {
        VStack(spacing: theme.space.s0) {
            // Repository info + selected count.
            HStack(spacing: theme.space.s10) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(
                            LinearGradient(
                                colors: [theme.surface.pressed, theme.surface.raised],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "shippingbox.fill")
                        .glyphSize(.body, weight: .medium)
                        .foregroundColor(theme.text.link)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    if let description = result.repoDescription {
                        Text(description)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                StatusChip(L("\(selectedPluginNames.count) selected"), tone: .accent)
            }
            .padding(theme.space.s12)
            .settingsChrome(.surface)
            .padding(.horizontal, theme.space.s16)
            .padding(.top, theme.space.s12)
            .padding(.bottom, theme.space.s8)

            // Select-all header + options.
            HStack(spacing: theme.space.s12) {
                Button(action: {
                    withAnimation(theme.motion.quick) {
                        if selectedPluginNames.count == result.plugins.count {
                            selectedPluginNames.removeAll()
                        } else {
                            selectedPluginNames = Set(result.plugins.map(\.name))
                        }
                    }
                }) {
                    HStack(spacing: theme.space.s8) {
                        Image(
                            systemName: selectedPluginNames.count == result.plugins.count
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .textStyle(.label)
                        .foregroundColor(
                            selectedPluginNames.count == result.plugins.count
                                ? theme.action.primary.default.background : theme.text.tertiary
                        )

                        Text("Select All", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Toggle("", isOn: $attachClaudeMd)
                    .settingsSwitch()
                Text("CLAUDE.md", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)

                Toggle("", isOn: $importMCPProviders)
                    .settingsSwitch()
                Text("MCP", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s8)

            // Auto-selection footer — only renders when the user just
            // toggled a plugin whose agents reference siblings.
            if let source = lastAutoSelectionSource, !lastAutoSelectedPlugins.isEmpty {
                HStack(alignment: .top, spacing: theme.space.s6) {
                    Image(systemName: "link")
                        .glyphSize(.micro, weight: .medium)
                        .foregroundColor(theme.text.link)
                        .padding(.top, theme.space.s2)
                    Text(
                        "Also selected: \(lastAutoSelectedPlugins.joined(separator: ", ")) — referenced by \(source).",
                        bundle: .module
                    )
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.bottom, theme.space.s4)
            }

            // Plugin list.
            ScrollView {
                LazyVStack(spacing: theme.space.s4) {
                    ForEach(result.plugins, id: \.name) { plugin in
                        ClaudePluginRow(
                            plugin: plugin,
                            isSelected: selectedPluginNames.contains(plugin.name)
                        ) {
                            togglePluginSelection(plugin.name)
                        }
                    }
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.bottom, theme.space.s8)
            }
        }
    }

    /// Toggle a plugin's selection and, if turning it ON, also auto-check
    /// any sibling plugins it depends on. Surfaces the cascade in the
    /// footer so the user can see what got pulled in.
    private func togglePluginSelection(_ name: String) {
        withAnimation(theme.motion.quick) {
            if selectedPluginNames.contains(name) {
                selectedPluginNames.remove(name)
                // Toggling off clears the auto-select footer so it isn't
                // stuck around showing stale state.
                if lastAutoSelectionSource == name {
                    lastAutoSelectionSource = nil
                    lastAutoSelectedPlugins = []
                }
            } else {
                selectedPluginNames.insert(name)
                let deps = pluginDependencies.transitiveDependencies(of: name)
                let newlyAdded = deps.subtracting(selectedPluginNames)
                if !newlyAdded.isEmpty {
                    selectedPluginNames.formUnion(deps)
                    lastAutoSelectionSource = name
                    lastAutoSelectedPlugins = newlyAdded.sorted()
                }
            }
        }
    }

    // MARK: - Install Complete View

    private func installCompleteView(_ report: ClaudePluginInstallReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                // Top-line counts.
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    InstallReportLine(
                        icon: "sparkles",
                        label: L("Skills"),
                        count: report.totalImportedSkills
                    )
                    InstallReportLine(
                        icon: "calendar.badge.clock",
                        label: L("Scheduled agents"),
                        count: report.totalImportedAgents
                    )
                    InstallReportLine(
                        icon: "text.bubble",
                        label: L("Slash commands"),
                        count: report.totalImportedCommands
                    )
                    InstallReportLine(
                        icon: "antenna.radiowaves.left.and.right",
                        label: L("MCP providers"),
                        count: report.totalImportedMCPProviders
                    )
                }
                .padding(theme.space.s12)
                .settingsChrome(.surface)

                if !report.allSchedulesNeedingCron.isEmpty {
                    InstallReportPendingSchedulesNotice(
                        items: report.allSchedulesNeedingCron,
                        onSelect: openScheduleEditor
                    )
                }

                if !report.allSkippedStdioServers.isEmpty {
                    InstallReportNotice(
                        icon: "terminal",
                        title: L("MCP servers need manual setup"),
                        message: L(
                            "These `.mcp.json` entries were malformed (no `command` and no `url`) and couldn't be imported:"
                        ),
                        items: report.allSkippedStdioServers
                    )
                }

                if !report.allStdioProvidersNeedingConfiguration.isEmpty {
                    InstallReportPendingProvidersNotice(
                        icon: "terminal.fill",
                        title: L("Stdio MCP servers need env vars"),
                        message: L(
                            "These stdio MCP servers were imported into the Osaurus sandbox but ship with `${VAR}` placeholders for sensitive env vars. Tap one to open its editor:"
                        ),
                        items: report.allStdioProvidersNeedingConfiguration,
                        onSelect: { openMCPProvider(id: $0) }
                    )
                }

                if !report.allStdioProvidersBlockedNoSandbox.isEmpty {
                    InstallReportNotice(
                        icon: "shippingbox.fill",
                        title: L("Sandbox unavailable — stdio MCP skipped"),
                        message: L(
                            "Imported stdio MCP servers run inside the Osaurus sandbox, which isn't available on this machine. These weren't installed:"
                        ),
                        items: report.allStdioProvidersBlockedNoSandbox
                    )
                }

                if !report.allPlaceholderTokensSkipped.isEmpty {
                    InstallReportPendingProvidersNotice(
                        icon: "key",
                        title: L("MCP servers need tokens"),
                        message: L(
                            "These servers ship with placeholder credentials. Tap one to open its editor and paste a real token:"
                        ),
                        items: report.allPlaceholderTokensSkipped,
                        onSelect: { openMCPProvider(id: $0) }
                    )
                }

                if !report.allOAuthProvidersNeedingSignIn.isEmpty {
                    InstallReportPendingProvidersNotice(
                        icon: "person.crop.circle.badge.questionmark",
                        title: L("MCP servers need OAuth sign-in"),
                        message: L(
                            "These providers use OAuth and were created disabled. Tap one to open its editor and complete sign-in:"
                        ),
                        items: report.allOAuthProvidersNeedingSignIn,
                        onSelect: { openMCPProvider(id: $0) }
                    )
                }

                if !report.allErrors.isEmpty {
                    InstallReportNotice(
                        icon: "exclamationmark.triangle",
                        title: L("Some items failed"),
                        message: L("These artifacts couldn't be installed:"),
                        items: report.allErrors
                    )
                }
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s12)
        }
    }

    // MARK: - Importing View

    private func importingView(progress: Int, total: Int) -> some View {
        VStack(spacing: theme.space.s20) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(theme.border.default, lineWidth: theme.stroke.focus * 1.5)
                    .frame(width: 56, height: 56)

                Circle()
                    .trim(from: 0, to: CGFloat(progress) / CGFloat(total))
                    .stroke(theme.status.info.foreground, style: StrokeStyle(lineWidth: theme.stroke.focus * 1.5, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))
                // Disable the implicit trim animation: with the
                // installer's parallel fetch + per-artifact tick, we
                // receive a burst of progress updates and any easeInOut
                // animation stomps on its predecessor, producing
                // visible jank instead of smooth motion.

                Text("\(progress)", bundle: .module)
                    .font(SettingsFont.detailTitle)
                    .foregroundColor(theme.text.primary)
            }

            VStack(spacing: theme.space.s4) {
                Text("Installing", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)

                Text("\(progress) of \(total)", bundle: .module)
                    .font(SettingsFont.caption)
                    .monospacedDigit()
                    .foregroundColor(theme.text.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Error View

    private func errorView(_ error: GitHubSkillError) -> some View {
        let isRateLimit: Bool
        if case .rateLimited = error { isRateLimit = true } else { isRateLimit = false }
        return VStack(spacing: theme.space.s20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.status.error.background)
                    .frame(width: 64, height: 64)

                Image(systemName: isRateLimit ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .glyphSize(.display)
                    .foregroundColor(theme.status.error.foreground)
            }

            VStack(spacing: theme.space.s6) {
                Text(
                    isRateLimit ? "GitHub rate limit reached" : "Something went wrong",
                    bundle: .module
                )
                .font(SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)

                Text(error.localizedDescription)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, theme.space.s32)
            }

            Button(action: { importState = .urlInput }) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "arrow.counterclockwise")
                        .glyphSize(.footnote, weight: .medium)
                    Text("Try Again", bundle: .module)
                        .font(SettingsFont.compactLabel)
                }
                .foregroundColor(theme.text.link)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .settingsChrome(.selected)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: theme.space.s10) {
            Spacer()

            switch importState {
            case .installComplete:
                Button(action: cancel) { Text("Done", bundle: .module) }
                    .assignedSettingsButtonStyle(.primary)
                    .keyboardShortcut(.return, modifiers: .command)

            default:
                Button(action: cancel) { Text("Cancel", bundle: .module) }
                    .assignedSettingsButtonStyle(.secondary)
            }

            switch importState {
            case .urlInput:
                Button {
                    fetchSkills()
                } label: {
                    Text("Continue", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)

            case .skillSelection:
                Button {
                    if case .skillSelection(let result) = importState {
                        importSelectedSkills(from: result)
                    }
                } label: {
                    Text(
                        "Import \(selectedSkillPaths.count) Skill\(selectedSkillPaths.count == 1 ? "" : "s")",
                        bundle: .module
                    )
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(selectedSkillPaths.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)

            case .pluginSelection:
                Button {
                    if case .pluginSelection(let result) = importState {
                        installSelectedPlugins(from: result)
                    }
                } label: {
                    Text(
                        "Install \(selectedPluginNames.count) Plugin\(selectedPluginNames.count == 1 ? "" : "s")",
                        bundle: .module
                    )
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(selectedPluginNames.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)

            case .loading, .importing, .error, .installComplete:
                EmptyView()
            }
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .background(
            theme.surface.subtle
                .overlay(
                    ThemeHairlineDivider(),
                    alignment: .top
                )
        )
    }

    // MARK: - Actions

    private func cancel() {
        activeTask?.cancel()
        activeTask = nil
        onCancel()
    }

    /// Deep-link from the install summary to the event editor. Dismisses
    /// this sheet, flips to the Events tab, and queues the editor to open
    /// for the requested schedule event id.
    private func openScheduleEditor(_ id: UUID) {
        ManagementStateManager.shared.selectedTab = .automations
        ManagementStateManager.shared.pendingEventEditId = id
        cancel()
    }

    /// Deep-link from the install summary to the Tools & MCP Services tab.
    /// Used by the OAuth + placeholder-token install notices so the user
    /// doesn't have to hunt through the sidebar for where Sign In lives.
    private func openMCPProvider(id: UUID?) {
        ManagementStateManager.shared.selectedTab = .tools
        ManagementStateManager.shared.pendingToolsSubTab = ToolsTab.services.rawValue
        ManagementStateManager.shared.pendingMCPProviderEditId = id
        cancel()
    }

    private func fetchSkills() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        activeTask?.cancel()
        importState = .loading

        activeTask = Task { @MainActor in
            do {
                // Prefer the richer plugin-aware fetch. If everything in the
                // repo is legacy (`skills: [String]` only), fall back to the
                // existing flat skill picker for backward compatibility.
                let plugins = try await gitHubService.fetchPlugins(from: url)
                guard !Task.isCancelled else { return }

                if plugins.isLegacyOnly {
                    let skills = plugins.plugins.flatMap { manifest -> [GitHubSkillPreview] in
                        manifest.skills.map {
                            GitHubSkillPreview(
                                path: $0.path,
                                pluginName: manifest.name,
                                pluginDescription: manifest.description
                            )
                        }
                    }
                    let legacyResult = GitHubSkillsResult(
                        repo: plugins.repo,
                        marketplace: plugins.marketplace,
                        skills: skills
                    )
                    selectedSkillPaths = Set(skills.map(\.path))
                    importState = .skillSelection(legacyResult)
                } else {
                    selectedPluginNames = Set(plugins.plugins.map(\.name))
                    importState = .pluginSelection(plugins)
                    // Resolve cross-plugin sibling dependencies in the
                    // background so the picker stays interactive while
                    // agent bodies are being fetched. The graph is only
                    // consumed by `togglePluginSelection`, which gracefully
                    // no-ops when it's still empty.
                    loadDependencyGraph(for: plugins)
                }
            } catch is CancellationError {
                return
            } catch let error as GitHubSkillError {
                guard !Task.isCancelled else { return }
                importState = .error(error)
            } catch {
                guard !Task.isCancelled else { return }
                importState = .error(.networkError(error))
            }
        }
    }

    /// Kick off `resolvePluginDependencies` in a background task. The
    /// resolver fetches every plugin's agent markdown files and scans them
    /// for sibling-skill references; the picker uses the resulting graph to
    /// auto-select cross-plugin dependencies when the user toggles a parent
    /// plugin on. We don't block on this — if it's still running when the
    /// user clicks Install, the resulting selection is whatever was
    /// explicitly checked.
    private func loadDependencyGraph(for plugins: GitHubPluginsResult) {
        dependencyResolverTask?.cancel()
        dependencyResolverTask = Task { @MainActor in
            let graph = await gitHubService.resolvePluginDependencies(plugins)
            guard !Task.isCancelled else { return }
            pluginDependencies = graph
        }
    }

    private func installSelectedPlugins(from result: GitHubPluginsResult) {
        let selected = result.plugins.filter { selectedPluginNames.contains($0.name) }
        guard !selected.isEmpty else { return }

        let selections = selected.map {
            ClaudePluginSelection(
                manifest: $0,
                importMCP: importMCPProviders,
                attachClaudeMd: attachClaudeMd
            )
        }
        let totalSteps = max(selections.reduce(0) { $0 + $1.totalSelected }, 1)

        activeTask?.cancel()
        importState = .importing(progress: 0, total: totalSteps)

        activeTask = Task { @MainActor in
            // Batch so SkillManager reloads `skills` once at the end instead
            // of after every per-skill save — which made the Skills view
            // behind this sheet flash continuously during a 170-skill import.
            let report = await SkillManager.shared.batchUpdates {
                await ClaudePluginInstaller.shared.install(
                    selections: selections,
                    from: result.repo,
                    progressHandler: { @MainActor current, total in
                        // Fires synchronously on the main actor; set `@State`
                        // directly so late progress Tasks can't overwrite
                        // `.installComplete`.
                        importState = .importing(progress: current, total: total)
                    }
                )
            }
            guard !Task.isCancelled else { return }
            onPluginInstallComplete?(report)
            importState = .installComplete(report)
        }
    }

    private func importSelectedSkills(from result: GitHubSkillsResult) {
        let selectedPaths = Array(selectedSkillPaths)
        guard !selectedPaths.isEmpty else { return }

        activeTask?.cancel()
        importState = .importing(progress: 0, total: selectedPaths.count)

        activeTask = Task { @MainActor in
            var importedSkills: [Skill] = []

            for (index, path) in selectedPaths.enumerated() {
                guard !Task.isCancelled else { return }
                importState = .importing(progress: index + 1, total: selectedPaths.count)

                do {
                    let content = try await gitHubService.fetchSkillContent(from: result.repo, skillPath: path)
                    guard !Task.isCancelled else { return }
                    let skill = try Skill.parseAnyFormat(from: content)
                    importedSkills.append(skill)
                } catch is CancellationError {
                    return
                } catch {
                    print("Failed to import skill at \(path): \(error)")
                }
            }

            guard !Task.isCancelled else { return }

            if !importedSkills.isEmpty {
                onImport(importedSkills)
            } else {
                importState = .error(.noSkillsFound)
            }
        }
    }
}

// MARK: - Skill Selection Row

private struct GitHubSkillSelectionRow: View {
    @Environment(\.theme) private var theme

    let skill: GitHubSkillPreview
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var skillColor: Color { theme.dataInk(seed: skill.displayName) }
    private var skillWash: Color { theme.dataWash(seed: skill.displayName) }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: theme.space.s10) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .fill(isSelected ? theme.action.primary.default.background : Color.clear)
                        .frame(width: 16, height: 16)

                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .stroke(
                            isSelected ? theme.action.primary.default.background : theme.border.strong,
                            lineWidth: theme.stroke.default
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .glyphSize(.tiny, weight: .bold)
                            .foregroundColor(theme.action.primary.default.foreground)
                    }
                }

                // Skill icon
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(skillWash)
                    Image(systemName: "sparkles")
                        .glyphSize(.micro, weight: .medium)
                        .foregroundColor(skillColor)
                }
                .frame(width: 26, height: 26)

                // Skill name
                Text(skill.displayName)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)

                Spacer()
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(isHovered ? .inset : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Plugin Row

private struct ClaudePluginRow: View {
    @Environment(\.theme) private var theme

    let plugin: ClaudePluginManifest
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var pluginColor: Color { theme.dataInk(seed: plugin.name) }
    private var pluginWash: Color { theme.dataWash(seed: plugin.name) }

    private var summaryLine: String {
        var pieces: [String] = []
        if !plugin.skills.isEmpty {
            pieces.append("\(plugin.skills.count) skill\(plugin.skills.count == 1 ? "" : "s")")
        }
        if !plugin.agents.isEmpty {
            pieces.append("\(plugin.agents.count) agent\(plugin.agents.count == 1 ? "" : "s")")
        }
        if !plugin.commands.isEmpty {
            pieces.append("\(plugin.commands.count) cmd\(plugin.commands.count == 1 ? "" : "s")")
        }
        if plugin.mcpJsonPath != nil { pieces.append("MCP") }
        if plugin.claudeMdPath != nil { pieces.append("CLAUDE.md") }
        return pieces.isEmpty ? "(no installable items)" : pieces.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: theme.space.s10) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .fill(isSelected ? theme.action.primary.default.background : Color.clear)
                        .frame(width: 16, height: 16)

                    RoundedRectangle(cornerRadius: theme.radius.small)
                        .stroke(
                            isSelected ? theme.action.primary.default.background : theme.border.strong,
                            lineWidth: theme.stroke.default
                        )
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .glyphSize(.tiny, weight: .bold)
                            .foregroundColor(theme.action.primary.default.foreground)
                    }
                }
                .padding(.top, theme.space.s4)

                // Plugin icon
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(pluginWash)
                    Image(systemName: "shippingbox")
                        .glyphSize(.footnote, weight: .medium)
                        .foregroundColor(pluginColor)
                }
                .frame(width: 28, height: 28)

                SettingsRowText(compact: true) {
                    Text(plugin.name)
                } description: {
                    if let description = plugin.description, !description.isEmpty {
                        Text(description)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(2)
                    }
                    Text(summaryLine)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(isHovered ? .inset : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Install Report Subviews

private struct InstallReportLine: View {
    @Environment(\.theme) private var theme

    let icon: String
    let label: String
    let count: Int

    var body: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.caption, weight: .medium)
                .foregroundColor(theme.text.link)
                .frame(width: 16)
            Text(label)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.primary)
            Spacer()
            Text("\(count)")
                .font(SettingsFont.compactLabel)
                // swiftlint:disable:next empty_count
                .foregroundColor(count > 0 ? theme.text.primary : theme.text.tertiary)
        }
    }
}

private struct InstallReportNotice: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let message: String
    let items: [String]
    /// Optional CTA shown next to the title (e.g. "Open MCP settings" to
    /// deep-link from the OAuth notice to the Remote MCP providers tab).
    var actionLabel: String?
    var onAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text(title)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer(minLength: 8)
                if let actionLabel, let onAction {
                    Button(action: onAction) {
                        Text(actionLabel)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.text.link)
                            .padding(.horizontal, theme.space.s8)
                            .padding(.vertical, theme.space.s4)
                            .settingsChrome(.selected)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            Text(message)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(items, id: \.self) { item in
                    Text("• \(item)")
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, theme.space.s4)
        }
        .padding(theme.space.s8)
        .settingsChrome(.status(.warning))
    }
}

/// Variant of `InstallReportNotice` that renders each pending schedule as a
/// button so the user can jump straight to the schedule editor instead of
/// hunting through the Automations tab manually.
private struct InstallReportPendingSchedulesNotice: View {
    @Environment(\.theme) private var theme

    let items: [ClaudePluginInstallReport.PendingSchedule]
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "exclamationmark.circle")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text("Automations need review", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
            }
            Text(
                "These agents had no machine-readable schedule and were created disabled. Tap one to set a cron expression:",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(items) { item in
                    Button(action: { onSelect(item.id) }) {
                        HStack(spacing: theme.space.s6) {
                            Text("•")
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.secondary)
                            Text(item.name)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.link)
                                .underline()
                                .lineLimit(2)
                            Image(systemName: "arrow.up.right.square")
                                .glyphSize(.tiny, weight: .semibold)
                                .foregroundColor(theme.text.link)
                            Spacer()
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.leading, theme.space.s4)
        }
        .padding(theme.space.s8)
        .settingsChrome(.status(.warning))
    }
}

/// Renders each `PendingMCPProvider` as a clickable button that deep-links
/// to the provider's editor. Used by the OAuth, placeholder-token, and
/// stdio-env-vars install notices so the user goes straight to the row
/// that needs attention instead of scanning a list of names.
private struct InstallReportPendingProvidersNotice: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: String
    let message: String
    let items: [ClaudePluginInstallReport.PendingMCPProvider]
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.status.warning.foreground)
                Text(title)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer(minLength: 8)
            }
            Text(message)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)

            VStack(alignment: .leading, spacing: theme.space.s4) {
                ForEach(items) { item in
                    Button(action: { onSelect(item.id) }) {
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            HStack(spacing: theme.space.s6) {
                                Text("•")
                                    .font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.secondary)
                                Text(item.name)
                                    .font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.link)
                                    .underline()
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right.square")
                                    .glyphSize(.tiny, weight: .semibold)
                                    .foregroundColor(theme.text.link)
                                Spacer()
                            }
                            if !item.missingKeys.isEmpty {
                                Text("needs: \(item.missingKeys.joined(separator: ", "))")
                                    .font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.secondary)
                                    .lineLimit(2)
                                    .padding(.leading, theme.space.s12)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.leading, theme.space.s4)
        }
        .padding(theme.space.s8)
        .settingsChrome(.status(.warning))
    }
}

// MARK: - Button Styles

// MARK: - Placeholder Modifier

private extension View {
    @ViewBuilder
    func placeholder<Content: View>(
        when shouldShow: Bool,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow {
                placeholder()
            }
            self
        }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        GitHubImportSheet(
            onImport: { _ in },
            onCancel: {}
        )
    }
#endif
