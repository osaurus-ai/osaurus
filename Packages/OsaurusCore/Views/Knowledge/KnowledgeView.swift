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

    // Curation review state (Phase 2).
    @State private var openTickets: [KnowledgeTicket] = []
    @State private var pendingProposals: [KnowledgeProposal] = []
    @State private var reviewingProposal: KnowledgeProposal?

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
                            "Point Osaurus at a folder of markdown (guides, templates, standards) and grant it to agents so they can consult it on demand."
                        ),
                        examples: [
                            .init(
                                icon: "doc.text",
                                title: L("Guides & Policies"),
                                description: L("How your team does things, written down")
                            ),
                            .init(
                                icon: "square.on.square",
                                title: L("Templates"),
                                description: L("Wording you reuse, like email replies")
                            ),
                            .init(
                                icon: "book",
                                title: L("How-To Steps"),
                                description: L("Simple instructions for everyday tasks")
                            ),
                        ],
                        primaryAction: .init(
                            title: L("Add Collection"),
                            icon: "plus",
                            handler: { isCreating = true }
                        ),
                        hasAppeared: hasAppeared
                    )
                    .padding(.horizontal, 32)
                } else {
                    ScrollView {
                        curationSection
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
                                    onSync: {
                                        showSuccess("Syncing \"\(collection.name)\"…")
                                        Task {
                                            let outcome = await knowledgeManager.syncNow(collection)
                                            showSuccess(outcome.message)
                                        }
                                    },
                                    onValidateOKF: {
                                        Task.detached(priority: .userInitiated) {
                                            let failing = await KnowledgeIndexService.shared
                                                .okfNonconformingDocuments(collectionId: collection.id.uuidString)
                                            await MainActor.run {
                                                if failing.isEmpty {
                                                    showSuccess("Every document has a category (type)")
                                                } else {
                                                    let sample = failing.prefix(3).joined(separator: ", ")
                                                    showSuccess(
                                                        "\(failing.count) document(s) need a category — add a `type:` line to: \(sample)\(failing.count > 3 ? "…" : "")"
                                                    )
                                                }
                                            }
                                        }
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
                onSave: { name, summary, folderPath, remoteURL in
                    isCreating = false
                    if let remoteURL, !remoteURL.isEmpty {
                        showSuccess("Cloning \"\(name)\"…")
                        Task {
                            do {
                                let created = try await knowledgeManager.createFromGit(
                                    name: name,
                                    summary: summary,
                                    remoteURL: remoteURL
                                )
                                showSuccess("Cloned \"\(created.name)\", indexing in the background")
                            } catch {
                                showSuccess("Clone failed: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        Task {
                            let created = await knowledgeManager.create(
                                name: name,
                                summary: summary,
                                folderPath: folderPath
                            )
                            showSuccess("Added \"\(created.name)\", indexing in the background")
                        }
                    }
                },
                onCancel: { isCreating = false }
            )
        }
        .sheet(item: $editingCollection) { collection in
            KnowledgeCollectionEditorSheet(
                collection: collection,
                onSave: { name, summary, folderPath, _ in
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
        .sheet(item: $reviewingProposal) { proposal in
            KnowledgeProposalReviewSheet(
                proposal: proposal,
                collectionName: knowledgeManager.collection(
                    for: UUID(uuidString: proposal.collectionId) ?? UUID()
                )?.name ?? proposal.collectionId,
                onApprove: { editedContent in
                    reviewingProposal = nil
                    Task.detached(priority: .userInitiated) {
                        do {
                            try await KnowledgeCurationService.shared.approve(
                                proposalId: proposal.id,
                                overrideContent: editedContent
                            )
                            await MainActor.run { showSuccess("Approved proposal #\(proposal.id)") }
                        } catch {
                            await MainActor.run { showSuccess("Approve failed: \(error.localizedDescription)") }
                        }
                    }
                },
                onDismissProposal: {
                    reviewingProposal = nil
                    Task.detached(priority: .userInitiated) {
                        try? await KnowledgeCurationService.shared.dismissProposal(proposalId: proposal.id)
                        await MainActor.run { showSuccess("Dismissed proposal #\(proposal.id)") }
                    }
                },
                onCancel: { reviewingProposal = nil }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .knowledgeCurationChanged)) { _ in
            reloadCuration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .knowledgeCollectionsChanged)) { _ in
            reloadCuration()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            reloadCuration()
        }
    }

    // MARK: - Curation

    @ViewBuilder
    private var curationSection: some View {
        if !pendingProposals.isEmpty || !openTickets.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Curation", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                ForEach(pendingProposals) { proposal in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.badge.ellipsis")
                            .font(.system(size: 13))
                            .foregroundColor(theme.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Proposal #\(proposal.id): \(proposal.relPath)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(proposal.rationale)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button {
                            reviewingProposal = proposal
                        } label: {
                            Text("Review", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
                }

                ForEach(openTickets) { ticket in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.bubble")
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ticket #\(ticket.id): \(ticket.relPath)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(ticket.reason)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button {
                            Task.detached(priority: .userInitiated) {
                                try? await KnowledgeCurationService.shared.dismissTicket(ticketId: ticket.id)
                            }
                        } label: {
                            Text("Dismiss", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
    }

    /// Load open tickets + pending proposals off the main thread (the
    /// database serializes on its own queue).
    private func reloadCuration() {
        Task.detached(priority: .utility) {
            if !KnowledgeDatabase.shared.isOpen {
                try? KnowledgeDatabase.shared.open()
            }
            guard KnowledgeDatabase.shared.isOpen else { return }
            let tickets = (try? KnowledgeDatabase.shared.listTickets(collectionIds: nil, status: .open)) ?? []
            let proposals = (try? KnowledgeDatabase.shared.listProposals(status: .pending)) ?? []
            await MainActor.run {
                openTickets = tickets
                pendingProposals = proposals
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
    let onSync: () -> Void
    let onValidateOKF: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// OKF conformance, computed on appear so the badge shows status at a
    /// glance rather than hiding it behind a click.
    private enum OKFStatus: Equatable {
        case unknown
        case conformant
        case nonconforming(Int)
    }
    @State private var okfStatus: OKFStatus = .unknown

    private var okfIcon: String {
        switch okfStatus {
        case .conformant: return "checkmark.seal.fill"
        case .nonconforming: return "exclamationmark.triangle.fill"
        case .unknown: return "checkmark.seal"
        }
    }

    private var okfLabel: String {
        switch okfStatus {
        case .conformant: return "All categorized"
        case .nonconforming(let count):
            return count == 1 ? "1 doc needs a category" : "\(count) docs need a category"
        case .unknown: return "Checking categories…"
        }
    }

    private var okfColor: Color {
        switch okfStatus {
        case .conformant: return .green
        case .nonconforming: return .orange
        case .unknown: return theme.secondaryText
        }
    }

    private var okfHelp: String {
        switch okfStatus {
        case .conformant:
            return
                "Every document has a category, so agents can filter the library by it. Following the Open Knowledge Format (OKF)."
        case .nonconforming(let count):
            return
                "\(count) document(s) have no category. Add a `type:` line (e.g. `type: policy`) to the top of each file so agents can filter by it. Click for the list."
        case .unknown:
            return "Checking that every document declares a category (its `type`)…"
        }
    }

    private func refreshOKFStatus() async {
        let failing = await KnowledgeIndexService.shared
            .okfNonconformingDocuments(collectionId: collection.id.uuidString)
        okfStatus = failing.isEmpty ? .conformant : .nonconforming(failing.count)
    }

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
                if collection.isGitRepository {
                    Text("git", bundle: .module)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accentColor.opacity(0.18)))
                        .foregroundColor(theme.accentColor)
                        .help(collection.gitRemoteURL ?? "Local git repository (no remote)")
                }
            }
            if collection.isGitRepository, let remote = collection.gitRemoteURL {
                Text(remote)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(action: {
                onValidateOKF()
                Task { await refreshOKFStatus() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: okfIcon)
                        .font(.system(size: 9))
                    Text(verbatim: okfLabel)
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(okfColor.opacity(0.15)))
                .foregroundColor(okfColor)
            }
            .buttonStyle(.plain)
            .help(okfHelp)
            .task(id: collection.updatedAt) { await refreshOKFStatus() }
            if !collection.folderExists {
                Text("Folder not found. Search serves the last indexed state.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            HStack(spacing: 10) {
                if collection.isGitRepository {
                    cardButton("Sync", icon: "arrow.triangle.2.circlepath.circle", action: onSync)
                }
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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
    /// `remoteURL` is non-nil only in create mode when the user chose to
    /// clone from a git URL instead of picking a local folder.
    let onSave: (_ name: String, _ summary: String, _ folderPath: String, _ remoteURL: String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var summary: String
    @State private var folderPath: String
    @State private var remoteURL: String = ""

    init(
        collection: KnowledgeCollection?,
        onSave: @escaping (_ name: String, _ summary: String, _ folderPath: String, _ remoteURL: String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.collection = collection
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: collection?.name ?? "")
        _summary = State(initialValue: collection?.summary ?? "")
        _folderPath = State(initialValue: collection?.folderPath ?? "")
    }

    private var trimmedRemote: String {
        remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSource =
            !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (collection == nil && !trimmedRemote.isEmpty)
        return hasName && hasSource
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
                TextField("What this corpus contains, shown to agents", text: $summary)
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

            if collection == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or clone from a git URL", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    TextField("https://github.com/team/knowledge.git", text: $remoteURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text(
                        "Clones into Osaurus-managed storage and keeps the git link for Sync. Uses your existing git credentials (credential helper or SSH agent). Leave empty to use the folder above.",
                        bundle: .module
                    )
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
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
                        folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
                        (collection == nil && !trimmedRemote.isEmpty) ? trimmedRemote : nil
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

// MARK: - Proposal Review Sheet

private struct KnowledgeProposalReviewSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    private enum ViewMode: String, CaseIterable {
        case diff = "Changes"
        case edit = "Edit"
    }

    let proposal: KnowledgeProposal
    let collectionName: String
    /// Receives the reviewer's edited content, or nil when unedited.
    let onApprove: (String?) -> Void
    let onDismissProposal: () -> Void
    let onCancel: () -> Void

    @State private var viewMode: ViewMode = .diff
    /// Editable copy of the proposed content; the reviewer's version
    /// wins on approve.
    @State private var editedContent: String
    /// Current on-disk document ("" for a new document); loaded off-main.
    @State private var currentContent: String = ""
    @State private var diffLoaded = false
    @State private var diffLines: [KnowledgeDiff.Line] = []

    init(
        proposal: KnowledgeProposal,
        collectionName: String,
        onApprove: @escaping (String?) -> Void,
        onDismissProposal: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.proposal = proposal
        self.collectionName = collectionName
        self.onApprove = onApprove
        self.onDismissProposal = onDismissProposal
        self.onCancel = onCancel
        _editedContent = State(initialValue: proposal.newContent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Proposal #\(proposal.id)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("[\(collectionName)] \(proposal.relPath)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                if let ticketId = proposal.ticketId {
                    Text("Answers ticket #\(ticketId)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                Text(proposal.rationale)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch viewMode {
            case .diff:
                diffPane
            case .edit:
                editPane
            }

            Text(
                "Approving writes this content into the collection folder and re-indexes it. Your edits in the Edit tab are what gets written. Dismissing reopens the linked ticket.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)

            HStack {
                Button {
                    onDismissProposal()
                } label: {
                    Text("Dismiss Proposal", bundle: .module)
                        .foregroundColor(.red)
                }
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    let edited = editedContent == proposal.newContent ? nil : editedContent
                    onApprove(edited)
                } label: {
                    Text(editedContent == proposal.newContent ? "Approve" : "Approve Edited", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear(perform: loadDiff)
    }

    // MARK: - Panes

    @ViewBuilder
    private var diffPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(currentContent.isEmpty ? "New document" : "Changes vs. current document", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            ScrollView {
                if !diffLoaded {
                    Text("Loading…", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .padding(10)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diffLines) { line in
                            diffRow(line)
                        }
                    }
                    .padding(6)
                }
            }
            .frame(minHeight: 240, maxHeight: 380)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
        }
    }

    private func diffRow(_ line: KnowledgeDiff.Line) -> some View {
        let (prefix, color, background): (String, Color, Color) = {
            switch line.kind {
            case .context: return (" ", theme.tertiaryText, .clear)
            case .added: return ("+", Color.green, Color.green.opacity(0.08))
            case .removed: return ("-", Color.red, Color.red.opacity(0.08))
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            Text(prefix)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(line.kind == .context ? theme.primaryText : color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(background)
    }

    @ViewBuilder
    private var editPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Edit before approving", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            TextEditor(text: $editedContent)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 240, maxHeight: 380)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
        }
    }

    // MARK: - Diff loading

    /// Read the current document off-main and diff it against the
    /// proposal. A missing file (new document) diffs against empty.
    private func loadDiff() {
        guard !diffLoaded else { return }
        let relPath = proposal.relPath
        let collectionId = proposal.collectionId
        let newContent = proposal.newContent
        Task.detached(priority: .userInitiated) {
            var current = ""
            if let uuid = UUID(uuidString: collectionId),
                let collection = await MainActor.run(body: {
                    KnowledgeManager.shared.collection(for: uuid)
                })
            {
                let fileURL = collection.folderURL.standardizedFileURL
                    .appendingPathComponent(relPath).standardizedFileURL
                let folderPath = collection.folderURL.standardizedFileURL.path
                let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
                if fileURL.path.hasPrefix(prefix) {
                    current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                }
            }
            let lines = KnowledgeDiff.lines(old: current, new: newContent)
            await MainActor.run {
                currentContent = current
                diffLines = lines
                diffLoaded = true
            }
        }
    }
}
