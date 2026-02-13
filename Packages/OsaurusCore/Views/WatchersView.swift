//
//  WatchersView.swift
//  osaurus
//
//  Management view for creating, editing, and viewing file system watchers.
//

import AppKit
import SwiftUI

// MARK: - Watchers View

struct WatchersView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var watcherManager = WatcherManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var isCreating = false
    @State private var editingWatcher: Watcher?
    @State private var hasAppeared = false
    @State private var successMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Content
            ZStack {
                if watcherManager.watchers.isEmpty {
                    SettingsEmptyState(
                        icon: "eye.fill",
                        title: "Create Your First Watcher",
                        subtitle: "Monitor folders for changes and trigger agent tasks automatically.",
                        examples: [
                            .init(
                                icon: "arrow.down.circle",
                                title: "Downloads Organizer",
                                description: "Auto-sort files into folders by type"
                            ),
                            .init(
                                icon: "camera",
                                title: "Screenshot Manager",
                                description: "Rename and organize screenshots"
                            ),
                            .init(
                                icon: "externaldrive.connected.to.line.below",
                                title: "Dropbox Automation",
                                description: "Process shared files on change"
                            ),
                        ],
                        primaryAction: .init(title: "Create Watcher", icon: "plus", handler: { isCreating = true }),
                        hasAppeared: hasAppeared
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 300), spacing: 20),
                                GridItem(.flexible(minimum: 300), spacing: 20),
                            ],
                            spacing: 20
                        ) {
                            ForEach(Array(watcherManager.watchers.enumerated()), id: \.element.id) {
                                index,
                                watcher in
                                WatcherCard(
                                    watcher: watcher,
                                    isRunning: watcherManager.isRunning(watcher.id),
                                    animationDelay: Double(index) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onToggle: { enabled in
                                        watcherManager.setEnabled(watcher.id, enabled: enabled)
                                    },
                                    onRunNow: {
                                        watcherManager.runNow(watcher.id)
                                        showSuccess("Triggered \"\(watcher.name)\"")
                                    },
                                    onEdit: {
                                        editingWatcher = watcher
                                    },
                                    onDelete: {
                                        watcherManager.delete(id: watcher.id)
                                        showSuccess("Deleted \"\(watcher.name)\"")
                                    }
                                )
                            }
                        }
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                // Success toast
                if let message = successMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(message, type: .success)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .sheet(isPresented: $isCreating) {
            WatcherEditorSheet(
                mode: .create,
                onSave: { watcher in
                    watcherManager.create(
                        name: watcher.name,
                        instructions: watcher.instructions,
                        personaId: watcher.personaId,
                        parameters: watcher.parameters,
                        watchPath: watcher.watchPath,
                        watchBookmark: watcher.watchBookmark,
                        folderPath: watcher.folderPath,
                        folderBookmark: watcher.folderBookmark,
                        isEnabled: watcher.isEnabled,
                        recursive: watcher.recursive,
                        responsiveness: watcher.responsiveness
                    )
                    isCreating = false
                    showSuccess("Created \"\(watcher.name)\"")
                },
                onCancel: {
                    isCreating = false
                }
            )
        }
        .sheet(item: $editingWatcher) { watcher in
            WatcherEditorSheet(
                mode: .edit(watcher),
                onSave: { updated in
                    watcherManager.update(updated)
                    editingWatcher = nil
                    showSuccess("Updated \"\(updated.name)\"")
                },
                onCancel: {
                    editingWatcher = nil
                }
            )
        }
        .onAppear {
            watcherManager.refresh()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Watchers",
            subtitle: "Monitor folders for changes and trigger agent tasks automatically",
            count: watcherManager.watchers.isEmpty ? nil : watcherManager.watchers.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Refresh watchers") {
                watcherManager.refresh()
            }
            HeaderPrimaryButton("Create Watcher", icon: "plus") {
                isCreating = true
            }
        }
    }

    // MARK: - Success Toast

    private func showSuccess(_ message: String) {
        withAnimation(theme.springAnimation()) {
            successMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.animationQuick()) {
                successMessage = nil
            }
        }
    }
}

// MARK: - Watcher Card

private struct WatcherCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var personaManager = PersonaManager.shared

    let watcher: Watcher
    let isRunning: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    private var persona: Persona? {
        guard let personaId = watcher.personaId else { return nil }
        return personaManager.persona(for: personaId)
    }

    private var watcherColor: Color {
        let hash = abs(watcher.name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        if isRunning {
                            Circle()
                                .fill(theme.accentColor.opacity(0.2))
                            ProgressView()
                                .scaleEffect(0.5)
                        } else {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [watcherColor.opacity(0.15), watcherColor.opacity(0.05)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            Circle()
                                .strokeBorder(watcherColor.opacity(0.4), lineWidth: 2)

                            Text(watcher.name.prefix(1).uppercased())
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(watcherColor)
                        }
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(watcher.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            statusBadge
                        }

                        Text(watcher.displayWatchPath)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Menu {
                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(action: onRunNow) {
                            Label("Trigger Now", systemImage: "play.fill")
                        }
                        .disabled(isRunning)
                        Divider()
                        Button {
                            onToggle(!watcher.isEnabled)
                        } label: {
                            Label(
                                watcher.isEnabled ? "Pause" : "Resume",
                                systemImage: watcher.isEnabled ? "pause.circle" : "play.circle"
                            )
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
                }

                // Instructions excerpt
                if !watcher.instructions.isEmpty {
                    Text(watcher.instructions)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                compactStats
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(cardBackground)
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .shadow(
                color: isRunning
                    ? theme.accentColor.opacity(0.15) : Color.black.opacity(isHovered ? 0.08 : 0.04),
                radius: isHovered ? 10 : 5,
                x: 0,
                y: isHovered ? 3 : 2
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay), value: hasAppeared)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .themedAlert(
            "Delete Watcher",
            isPresented: $showDeleteConfirm,
            message: "Are you sure you want to delete \"\(watcher.name)\"? This action cannot be undone.",
            primaryButton: .destructive("Delete", action: onDelete),
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(theme.cardBackground)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isHovered
                    ? watcherColor.opacity(0.25)
                    : (isRunning ? theme.accentColor.opacity(0.3) : theme.cardBorder),
                lineWidth: isRunning || isHovered ? 1.5 : 1
            )
    }

    private var hoverGradient: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        watcherColor.opacity(isHovered ? 0.06 : 0),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        if isRunning {
            badgeLabel("Running", color: theme.accentColor)
        } else if watcher.isEnabled {
            badgeLabel("Watching", color: theme.successColor)
        } else {
            badgeLabel("Paused", color: .orange)
        }
    }

    private func badgeLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Compact Stats

    @ViewBuilder
    private var compactStats: some View {
        HStack(spacing: 0) {
            statItem(icon: "bolt.fill", text: "Agent")
            statDot

            statItem(
                icon: "folder.fill",
                text: watcher.recursive ? "Recursive" : "Shallow"
            )

            if let lastTriggered = watcher.lastTriggeredAt {
                statDot
                statItem(icon: "clock", text: relativeTimeString(for: lastTriggered))
            }

            if let personaName = persona?.name, persona?.isBuiltIn == false {
                statDot
                statItem(icon: "person.fill", text: personaName)
            }

            Spacer(minLength: 0)
        }
    }

    private func statItem(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    private var statDot: some View {
        Circle()
            .fill(theme.tertiaryText.opacity(0.4))
            .frame(width: 3, height: 3)
            .padding(.horizontal, 8)
    }

    private func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Watcher Editor Sheet

struct WatcherEditorSheet: View {
    enum Mode {
        case create
        case edit(Watcher)
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var personaManager = PersonaManager.shared

    let mode: Mode
    let onSave: (Watcher) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var instructions = ""
    @State private var selectedPersonaId: UUID?
    @State private var isEnabled = true
    @State private var recursive = false
    @State private var responsiveness: Responsiveness = .balanced
    @State private var selectedWatchPath: String?
    @State private var selectedWatchBookmark: Data?
    @State private var selectedFolderPath: String?
    @State private var selectedFolderBookmark: Data?
    @State private var useCustomWorkspace = false
    @State private var hasAppeared = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingId: UUID? {
        if case .edit(let watcher) = mode { return watcher.id }
        return nil
    }

    private var existingCreatedAt: Date? {
        if case .edit(let watcher) = mode { return watcher.createdAt }
        return nil
    }

    private var existingLastTriggeredAt: Date? {
        if case .edit(let watcher) = mode { return watcher.lastTriggeredAt }
        return nil
    }

    private var existingLastChatSessionId: UUID? {
        if case .edit(let watcher) = mode { return watcher.lastChatSessionId }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    watcherInfoSection
                    watchedFolderSection
                    workspaceFolderSection
                    instructionsSection
                    monitoringSection
                    personaSection
                }
                .padding(24)
            }

            footerView
        }
        .frame(width: 580, height: 680)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            if case .edit(let watcher) = mode {
                loadWatcher(watcher)
            }
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isEditing ? "pencil.circle.fill" : "eye.badge.clock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Watcher" : "Create Watcher")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(
                    isEditing
                        ? "Modify your file system watcher" : "Set up a folder monitoring agent"
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Watcher Info Section

    private var watcherInfoSection: some View {
        WatcherEditorSection(title: "Watcher Info", icon: "info.circle.fill") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    WatcherTextField(
                        placeholder: "e.g., Downloads Organizer",
                        text: $name,
                        icon: "textformat"
                    )
                }

                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(
                                isEnabled
                                    ? theme.successColor : theme.tertiaryText
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enabled")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(isEnabled ? "Watcher is active" : "Watcher is paused")
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isEnabled
                                        ? theme.successColor.opacity(0.3)
                                        : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
            }
        }
    }

    // MARK: - Watched Folder Section

    private var hasWatchFolder: Bool { selectedWatchPath != nil }

    private var watchedFolderSection: some View {
        WatcherEditorSection(title: "Watched Folder", icon: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                hasWatchFolder
                                    ? theme.accentColor.opacity(0.1) : theme.tertiaryBackground
                            )
                        Image(
                            systemName: hasWatchFolder
                                ? "folder.fill" : "folder.badge.questionmark"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(
                            hasWatchFolder ? theme.accentColor : theme.tertiaryText
                        )
                    }
                    .frame(width: 36, height: 36)

                    if let path = selectedWatchPath {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)
                            Text(path)
                                .font(.system(size: 10))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text("No folder selected")
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    }

                    Spacer()

                    if hasWatchFolder {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedWatchPath = nil
                                selectedWatchBookmark = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: selectWatchFolder) {
                        Text("Browse")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Text("The agent will be triggered when files in this folder change.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    private func selectWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Folder to Watch"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            withAnimation(.easeOut(duration: 0.2)) {
                selectedWatchPath = url.path
                selectedWatchBookmark = bookmark
            }
        } catch {
            print("[WatcherEditor] Failed to create watch bookmark: \(error)")
        }
    }

    // MARK: - Workspace Folder Section

    private var workspaceFolderSection: some View {
        WatcherEditorSection(title: "Agent Workspace", icon: "folder.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 8) {
                        Image(
                            systemName: useCustomWorkspace
                                ? "folder.badge.gearshape" : "checkmark.circle.fill"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(
                            useCustomWorkspace ? theme.secondaryText : theme.successColor
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                useCustomWorkspace
                                    ? "Custom workspace" : "Use watched folder"
                            )
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            Text(
                                useCustomWorkspace
                                    ? "Agent works in a different directory"
                                    : "Agent works in the watched folder"
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $useCustomWorkspace)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                if useCustomWorkspace {
                    HStack(spacing: 12) {
                        if let path = selectedFolderPath {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                Text(path)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } else {
                            Text("No workspace folder selected")
                                .font(.system(size: 13))
                                .foregroundColor(theme.placeholderText)
                        }

                        Spacer()

                        Button(action: selectWorkspaceFolder) {
                            Text("Browse")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor.opacity(0.1))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: useCustomWorkspace)
        }
    }

    private func selectWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Agent Workspace"
        panel.prompt = "Select"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            withAnimation(.easeOut(duration: 0.2)) {
                selectedFolderPath = url.path
                selectedFolderBookmark = bookmark
            }
        } catch {
            print("[WatcherEditor] Failed to create workspace bookmark: \(error)")
        }
    }

    // MARK: - Instructions Section

    private var instructionsSection: some View {
        WatcherEditorSection(title: "Instructions", icon: "text.alignleft") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if instructions.isEmpty {
                        Text(
                            "What should the agent do when changes are detected?"
                        )
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .padding(.top, 12)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                    }

                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .foregroundColor(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100, maxHeight: 150)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                Text(
                    "The agent will receive these instructions along with a list of changed files."
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Monitoring Section

    private var monitoringSection: some View {
        WatcherEditorSection(title: "Monitoring Options", icon: "gear") {
            VStack(alignment: .leading, spacing: 16) {
                // Recursive toggle
                HStack {
                    HStack(spacing: 8) {
                        Image(
                            systemName: recursive
                                ? "arrow.triangle.2.circlepath" : "arrow.right"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(
                            recursive ? theme.accentColor : theme.tertiaryText
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(recursive ? "Recursive" : "Shallow")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(
                                recursive
                                    ? "Monitor all subdirectories"
                                    : "Monitor top-level files only"
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                        }
                    }

                    Spacer()

                    Toggle("", isOn: $recursive)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )

                // Responsiveness picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Responsiveness")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Picker("Responsiveness", selection: $responsiveness) {
                        ForEach(Responsiveness.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(responsiveness.displayDescription)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .animation(.easeOut(duration: 0.15), value: responsiveness)
                }
            }
        }
    }

    // MARK: - Persona Section

    private var personaSection: some View {
        WatcherEditorSection(title: "Persona", icon: "person.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                WatcherPersonaPicker(
                    selectedPersonaId: $selectedPersonaId,
                    personas: personaManager.personas.filter { !$0.isBuiltIn }
                )
                .frame(maxWidth: .infinity)

                Text("The persona determines the agent's behavior and available tools.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(WatcherSecondaryButtonStyle())

            Button(isEditing ? "Save Changes" : "Create Watcher") {
                saveWatcher()
            }
            .buttonStyle(WatcherPrimaryButtonStyle())
            .disabled(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || selectedWatchPath == nil
            )
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    // MARK: - Helpers

    private func loadWatcher(_ watcher: Watcher) {
        name = watcher.name
        instructions = watcher.instructions
        selectedPersonaId = watcher.personaId
        isEnabled = watcher.isEnabled
        recursive = watcher.recursive
        responsiveness = watcher.responsiveness
        selectedWatchPath = watcher.watchPath
        selectedWatchBookmark = watcher.watchBookmark
        selectedFolderPath = watcher.folderPath
        selectedFolderBookmark = watcher.folderBookmark
        useCustomWorkspace = watcher.folderPath != nil && watcher.folderPath != watcher.watchPath
    }

    private func saveWatcher() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty, selectedWatchPath != nil else {
            return
        }

        let watcher = Watcher(
            id: existingId ?? UUID(),
            name: trimmedName,
            instructions: trimmedInstructions,
            personaId: selectedPersonaId,
            watchPath: selectedWatchPath,
            watchBookmark: selectedWatchBookmark,
            folderPath: useCustomWorkspace ? selectedFolderPath : nil,
            folderBookmark: useCustomWorkspace ? selectedFolderBookmark : nil,
            isEnabled: isEnabled,
            recursive: recursive,
            responsiveness: responsiveness,
            lastTriggeredAt: existingLastTriggeredAt,
            lastChatSessionId: existingLastChatSessionId,
            createdAt: existingCreatedAt ?? Date(),
            updatedAt: Date()
        )

        onSave(watcher)
    }
}

// MARK: - Editor Section

private struct WatcherEditorSection<Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Text Field

private struct WatcherTextField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    @Binding var text: String
    let icon: String?

    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isFocused ? theme.accentColor : theme.tertiaryText
                    )
                    .frame(width: 16)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }

                TextField(
                    "",
                    text: $text,
                    onEditingChanged: { editing in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isFocused = editing
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused
                                ? theme.accentColor.opacity(0.5)
                                : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }
}

// MARK: - Persona Picker

private struct WatcherPersonaPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selectedPersonaId: UUID?
    let personas: [Persona]

    @State private var isHovering = false
    @State private var showingPopover = false

    private var selectedPersona: Persona? {
        if let id = selectedPersonaId {
            return personas.first(where: { $0.id == id })
        }
        return nil
    }

    private var selectedPersonaName: String {
        selectedPersona?.name ?? "Default"
    }

    private func personaColor(for name: String) -> Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(personaColor(for: selectedPersonaName).opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(personaColor(for: selectedPersonaName))
                    )

                Text(selectedPersonaName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer(minLength: 0)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isHovering || showingPopover
                                    ? theme.accentColor.opacity(0.5)
                                    : theme.inputBorder,
                                lineWidth: isHovering || showingPopover ? 1.5 : 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                WatcherPersonaOptionRow(
                    name: "Default",
                    description: "Uses the default system behavior",
                    isSelected: selectedPersonaId == nil,
                    action: {
                        selectedPersonaId = nil
                        showingPopover = false
                    }
                )

                if !personas.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    ForEach(personas, id: \.id) { persona in
                        WatcherPersonaOptionRow(
                            name: persona.name,
                            description: persona.description,
                            isSelected: selectedPersonaId == persona.id,
                            action: {
                                selectedPersonaId = persona.id
                                showingPopover = false
                            }
                        )
                    }
                }
            }
            .padding(8)
            .frame(minWidth: 280)
            .background(theme.cardBackground)
        }
    }
}

private struct WatcherPersonaOptionRow: View {
    @Environment(\.theme) private var theme

    let name: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.tertiaryBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Button Styles

private struct WatcherPrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

private struct WatcherSecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

#Preview {
    WatchersView()
}
