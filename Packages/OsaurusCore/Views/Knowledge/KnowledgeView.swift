//
//  KnowledgeView.swift
//  osaurus
//
//  Management view for knowledge collections: register folders of
//  markdown as searchable corpora, re-index, and enable/disable.
//  Per-agent grants live in each agent's Features section.
//

import AppKit
import SwiftUI

// MARK: - Knowledge View

struct KnowledgeView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var isCreating = false
    @State private var editingCollection: KnowledgeCollection?
    @State private var hasAppeared = false
    @State private var successMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ZStack {
                if knowledgeManager.collections.isEmpty {
                    SettingsEmptyState(
                        icon: "books.vertical.fill",
                        title: L("Add Your First Knowledge Collection"),
                        subtitle: L(
                            "Point Osaurus at a folder of markdown — guides, templates, standards — and grant it to agents so they can consult it on demand."
                        ),
                        examples: [
                            .init(
                                icon: "doc.text",
                                title: L("Team Standards"),
                                description: L("Coding and testing guidelines agents must follow")
                            ),
                            .init(
                                icon: "square.on.square",
                                title: L("Templates"),
                                description: L("Master templates referenced when building")
                            ),
                            .init(
                                icon: "book",
                                title: L("How-to Guides"),
                                description: L("SOPs and runbooks for recurring tasks")
                            ),
                        ],
                        primaryAction: .init(
                            title: L("Add Collection"),
                            icon: "plus",
                            handler: { isCreating = true }
                        ),
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
                            ForEach(Array(knowledgeManager.collections.enumerated()), id: \.element.id) {
                                index,
                                collection in
                                KnowledgeCollectionCard(
                                    collection: collection,
                                    animationDelay: Double(index) * 0.05,
                                    hasAppeared: hasAppeared,
                                    onToggle: { enabled in
                                        var updated = collection
                                        updated.isEnabled = enabled
                                        knowledgeManager.update(updated)
                                    },
                                    onReindex: {
                                        knowledgeManager.scheduleIndex(of: collection, force: true)
                                        showSuccess("Re-indexing \"\(collection.name)\"")
                                    },
                                    onEdit: {
                                        editingCollection = collection
                                    },
                                    onDelete: {
                                        knowledgeManager.delete(id: collection.id)
                                        showSuccess("Deleted \"\(collection.name)\"")
                                    }
                                )
                            }
                        }
                        .padding(24)
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

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
            KnowledgeCollectionEditorSheet(
                collection: nil,
                onSave: { name, summary, folderPath in
                    let created = knowledgeManager.create(
                        name: name,
                        summary: summary,
                        folderPath: folderPath
                    )
                    isCreating = false
                    showSuccess("Added \"\(created.name)\" — indexing in the background")
                },
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $editingCollection) { collection in
            KnowledgeCollectionEditorSheet(
                collection: collection,
                onSave: { name, summary, folderPath in
                    var updated = collection
                    updated.name = name
                    updated.summary = summary
                    updated.folderPath = folderPath
                    knowledgeManager.update(updated)
                    editingCollection = nil
                    showSuccess("Updated \"\(name)\"")
                },
                onCancel: { editingCollection = nil }
            )
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
    }

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Knowledge"),
            subtitle: L("Folders of markdown your agents can search and read on demand"),
            count: knowledgeManager.collections.isEmpty ? nil : knowledgeManager.collections.count
        ) {
            HeaderIconButton("arrow.clockwise", help: "Re-index all collections") {
                knowledgeManager.scheduleIndexAll()
                showSuccess("Incremental re-index started")
            }
            HeaderPrimaryButton("Add Collection", icon: "plus") {
                isCreating = true
            }
        }
    }

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

// MARK: - Collection Card

private struct KnowledgeCollectionCard: View {
    @Environment(\.theme) private var theme

    let collection: KnowledgeCollection
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onReindex: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if !collection.summary.isEmpty {
                        Text(collection.summary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { collection.isEnabled }, set: onToggle))
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
            }

            HStack(spacing: 6) {
                Image(systemName: collection.folderExists ? "folder.fill" : "folder.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundColor(collection.folderExists ? theme.tertiaryText : .orange)
                Text(collection.folderPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !collection.folderExists {
                Text("Folder not found — search serves the last indexed state.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            HStack(spacing: 10) {
                cardButton("Re-index", icon: "arrow.triangle.2.circlepath", action: onReindex)
                cardButton("Edit", icon: "pencil", action: onEdit)
                Spacer()
                cardButton("Delete", icon: "trash", destructive: true, action: onDelete)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.primaryBorder, lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay),
            value: hasAppeared
        )
    }

    private func cardButton(
        _ title: LocalizedStringKey,
        icon: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title, bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(destructive ? .red : theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor Sheet

private struct KnowledgeCollectionEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// nil → create mode.
    let collection: KnowledgeCollection?
    let onSave: (_ name: String, _ summary: String, _ folderPath: String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var summary: String
    @State private var folderPath: String

    init(
        collection: KnowledgeCollection?,
        onSave: @escaping (_ name: String, _ summary: String, _ folderPath: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.collection = collection
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: collection?.name ?? "")
        _summary = State(initialValue: collection?.summary ?? "")
        _folderPath = State(initialValue: collection?.folderPath ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(collection == nil ? "Add Knowledge Collection" : "Edit Knowledge Collection", bundle: .module)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                TextField("WordPress Development", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Summary", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                TextField("What this corpus contains — shown to agents", text: $summary)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                HStack(spacing: 8) {
                    TextField("/path/to/markdown-folder", text: $folderPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button {
                        chooseFolder()
                    } label: {
                        Text("Choose…", bundle: .module)
                    }
                }
                Text(
                    "Markdown files in this folder are indexed in place and never modified. YAML frontmatter (`type`, `tags`, …) is used for filtering.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    onSave(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary.trimmingCharacters(in: .whitespacesAndNewlines),
                        folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                } label: {
                    Text(collection == nil ? "Add" : "Save", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
