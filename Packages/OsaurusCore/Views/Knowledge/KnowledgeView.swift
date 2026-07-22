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

    /// A freshly created collection awaiting the "grant to agents" prompt.
    /// Set right after `create`/`createFromGit` succeeds so the user can
    /// grant access inline instead of hunting through each agent's settings.
    @State private var grantingCollection: KnowledgeCollection?

    /// The collection whose detail sheet is open (tap a card to set it).
    @State private var detailCollection: KnowledgeCollection?

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
                            "Point Osaurus at a folder of guides, templates, and standards and grant it to agents so they can consult it on demand. Markdown, plain text, code, PDF, Word, Excel, PowerPoint, and CSV files are supported."
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
                                    isIndexing: knowledgeManager.indexingCollectionIds.contains(collection.id),
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
                                                    showSuccess(L("Every document has a category (type)"))
                                                } else {
                                                    let sample = failing.prefix(3).joined(separator: ", ")
                                                    let summary =
                                                        failing.count == 1
                                                        ? "1 document needs a category"
                                                        : "\(failing.count) documents need a category"
                                                    showSuccess(
                                                        "\(summary) — add a `type:` line to: \(sample)\(failing.count > 3 ? "…" : "")"
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
                                    },
                                    onOpenDetail: {
                                        detailCollection = collection
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
                                grantingCollection = created
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
                            grantingCollection = created
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
        .sheet(item: $grantingCollection) { collection in
            KnowledgeGrantAgentsSheet(
                collection: collection,
                onDone: { grantedCount in
                    grantingCollection = nil
                    if grantedCount > 0 {
                        showSuccess(
                            grantedCount == 1
                                ? L("Granted \"\(collection.name)\" to 1 agent")
                                : L("Granted \"\(collection.name)\" to \(grantedCount) agents")
                        )
                    }
                }
            )
        }
        .sheet(item: $detailCollection) { collection in
            KnowledgeCollectionDetailSheet(
                collection: collection,
                onEdit: {
                    detailCollection = nil
                    // Defer so the detail sheet finishes dismissing before the
                    // editor sheet is presented — presenting two sheets in the
                    // same runloop tick drops the second one.
                    DispatchQueue.main.async { editingCollection = collection }
                },
                onDelete: {
                    detailCollection = nil
                    knowledgeManager.delete(id: collection.id)
                    showSuccess("Deleted \"\(collection.name)\"")
                },
                onClose: { detailCollection = nil }
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
                            // Refresh the list explicitly rather than relying only
                            // on the `.knowledgeCurationChanged` notification, which
                            // approve posts after re-index/git and can be delayed or
                            // missed — leaving the approved card on screen.
                            await MainActor.run {
                                reloadCuration()
                                showSuccess(L("Approved proposal #\(proposal.id)"))
                            }
                        } catch {
                            await MainActor.run { showSuccess("Approve failed: \(error.localizedDescription)") }
                        }
                    }
                },
                onDismissProposal: {
                    reviewingProposal = nil
                    Task.detached(priority: .userInitiated) {
                        try? await KnowledgeCurationService.shared.dismissProposal(proposalId: proposal.id)
                        await MainActor.run {
                            reloadCuration()
                            showSuccess(L("Dismissed proposal #\(proposal.id)"))
                        }
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
        // A curation notification posted while this view wasn't mounted (e.g. a
        // ticket filed from a chat window with Settings closed) is missed —
        // NotificationCenter doesn't replay, and switching Settings tabs won't
        // re-fire `.onAppear` on this kept-alive view. Reloading whenever a
        // window becomes key self-heals that stale state the moment the user
        // brings Settings forward. The reload is a cheap off-main DB read.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reloadCuration()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
            reloadCuration()
        }
        // Self-healing refresh. The curation list is otherwise driven by
        // notifications + appear/window-key hooks, all of which are unreliable
        // for this kept-alive Settings view: a `.knowledgeCurationChanged`
        // posted (e.g. a ticket filed from a chat window) while this view isn't
        // mounted is lost, and SwiftUI won't re-fire `.onAppear` when the user
        // returns. A light poll keeps tickets/proposals current regardless; the
        // reload is id-diffed (see `reloadCuration`) so an unchanged list never
        // re-renders. `.task` is cancelled when the view goes away.
        .task {
            while !Task.isCancelled {
                reloadCuration()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
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
                Text(
                    "Agents flag documents that look out of date. A Curator agent proposes a fix here for you to approve — nothing changes until you do.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(pendingProposals) { proposal in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.badge.ellipsis")
                            .font(.system(size: 13))
                            .foregroundColor(theme.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: L("Proposal #%lld: %@"), proposal.id, proposal.relPath))
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
                            Text(String(format: L("Ticket #%lld: %@"), ticket.id, ticket.relPath))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Text(ticket.reason)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(2)
                            Text("Waiting for a curator to propose a fix", bundle: .module)
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                        Spacer(minLength: 8)
                        Button {
                            startCurator(for: ticket)
                        } label: {
                            Text("Update with a curator", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        Button {
                            Task.detached(priority: .userInitiated) {
                                try? await KnowledgeCurationService.shared.dismissTicket(ticketId: ticket.id)
                            }
                        } label: {
                            Text("Dismiss", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
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

    /// A curator agent that can act on `collectionId`: knowledge on, curator
    /// on, and this collection granted. `nil` when the user hasn't set one up.
    private func curatorAgent(forCollectionId collectionId: String) -> Agent? {
        guard let uuid = UUID(uuidString: collectionId) else { return nil }
        return AgentManager.shared.agents.first { agent in
            agent.settings.knowledgeEnabled
                && agent.settings.knowledgeCuratorEnabled
                && agent.settings.knowledgeCollectionIds.contains(uuid)
        }
    }

    /// Give the user a forward action beyond Dismiss: open a chat with a
    /// curator agent whose composer is pre-filled with a briefing for this
    /// ticket, so the user lands with the request ready to send instead of a
    /// blank window. The curator does the proposing through the normal chat +
    /// tool path; the proposal then returns here for approval.
    private func startCurator(for ticket: KnowledgeTicket) {
        guard let agent = curatorAgent(forCollectionId: ticket.collectionId) else {
            showSuccess(
                L("No curator yet — turn on Features → Knowledge → Curator for an agent that can use this collection.")
            )
            return
        }
        let windowId = ChatWindowManager.shared.createWindow(agentId: agent.id)
        // Seed the composer so the window isn't a blank prompt. The reviewer
        // can edit or send as-is; the curator uses propose_knowledge_update,
        // which lands back here as a pending proposal for approval.
        let collectionName =
            (UUID(uuidString: ticket.collectionId)
            .flatMap { KnowledgeManager.shared.collection(for: $0)?.name }) ?? ""
        let collectionClause = collectionName.isEmpty ? "" : " in the \"\(collectionName)\" collection"
        let briefing =
            "Please work knowledge ticket #\(ticket.id) for `\(ticket.relPath)`\(collectionClause).\n"
            + "Reported issue: \(ticket.reason)\n\n"
            + "Read the current document, and if it is out of date, use "
            + "propose_knowledge_update to draft a corrected version for my "
            + "approval. Keep the existing frontmatter. Do not change anything "
            + "until I approve the proposal."
        ChatWindowManager.shared.windowState(id: windowId)?.session.input = briefing
        showSuccess(L("Opened \(agent.name) with a briefing for ticket #\(ticket.id). Review it and hit send."))
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
                // Assign only on a real change so the periodic poll can't churn
                // the view every tick. Both lists are single-status queries, so
                // comparing ids is sufficient to detect add/remove/status moves.
                if tickets.map(\.id) != openTickets.map(\.id) { openTickets = tickets }
                if proposals.map(\.id) != pendingProposals.map(\.id) { pendingProposals = proposals }
            }
        }
    }

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Knowledge"),
            subtitle: L("Folders of documents your agents can search and read on demand"),
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
    @ObservedObject private var agentManager = AgentManager.shared

    let collection: KnowledgeCollection
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onReindex: () -> Void
    let isIndexing: Bool
    let onSync: () -> Void
    let onValidateOKF: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenDetail: () -> Void

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

    /// Agents that can actually reach this collection: knowledge on and the
    /// collection granted. Keeps the manager's display order so the stacked
    /// avatars stay stable across redraws.
    private var grantedAgents: [Agent] {
        agentManager.agents
            .filter { $0.settings.knowledgeEnabled && $0.settings.knowledgeCollectionIds.contains(collection.id) }
    }

    /// Overlapping avatars of the agents with access, capped so the row stays
    /// compact, followed by an "N agents" count. Surfaces the grant at a
    /// glance instead of hiding it inside each agent's settings.
    @ViewBuilder
    private var grantedAgentsRow: some View {
        let agents = grantedAgents
        let shown = Array(agents.prefix(4))
        HStack(spacing: 6) {
            if agents.isEmpty {
                Image(systemName: "person.slash")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Text("No agents with access", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else {
                HStack(spacing: -8) {
                    ForEach(shown) { agent in
                        AgentAvatarView(
                            mascotId: agent.avatar,
                            name: agent.name,
                            tint: theme.accentColor,
                            diameter: 20,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 9,
                            borderWidth: 0
                        )
                        .overlay(Circle().stroke(theme.secondaryBackground, lineWidth: 1.5))
                    }
                }
                Text(
                    agents.count == 1
                        ? L("1 agent")
                        : String(format: L("%lld agents"), agents.count)
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
            }
        }
        .help(
            agents.isEmpty
                ? L("No agents can use this collection yet")
                : L("Agents with access: \(agents.map(\.name).joined(separator: ", "))")
        )
    }

    private var okfHelp: String {
        switch okfStatus {
        case .conformant:
            return
                "Every document has a category, so agents can filter the library by it. Following the Open Knowledge Format (OKF)."
        case .nonconforming(let count):
            return count == 1
                ? "1 document has no category. Add a `type:` line (e.g. `type: policy`) to the top of the file so agents can filter by it. Click for the list."
                : "\(count) documents have no category. Add a `type:` line (e.g. `type: policy`) to the top of each file so agents can filter by it. Click for the list."
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
            grantedAgentsRow
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
            .onChange(of: isIndexing) { indexing in
                // Recompute the category badge once the pass completes and
                // the index reflects the folder on disk.
                if !indexing { Task { await refreshOKFStatus() } }
            }
            if !collection.folderExists {
                Text("Folder not found. Search serves the last indexed state.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }

            HStack(spacing: 10) {
                if collection.isGitRepository {
                    cardButton("Sync", icon: "arrow.triangle.2.circlepath.circle", action: onSync)
                }
                if isIndexing {
                    indexingIndicator
                } else {
                    cardButton("Re-index", icon: "arrow.triangle.2.circlepath", action: onReindex)
                }
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
        // Tapping empty areas of the card opens its detail. The inner
        // Buttons and Toggle consume their own taps, so this fires only on
        // the non-control regions and never fights the row actions.
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onOpenDetail() }
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : 10)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8).delay(animationDelay),
            value: hasAppeared
        )
    }

    /// Non-interactive counterpart to the Re-index button, shown while a
    /// pass is in flight so the action reads as busy rather than tappable.
    private var indexingIndicator: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("Indexing…", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground)
        )
        .help(Text("Indexing in progress", bundle: .module))
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

            StyledSettingsTextField(
                label: "Name",
                text: $name,
                placeholder: "WordPress Development",
                help: ""
            )

            StyledSettingsTextField(
                label: "Summary",
                text: $summary,
                placeholder: "What this corpus contains, shown to agents",
                help: ""
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                HStack(spacing: 10) {
                    TextField("/path/to/knowledge-folder", text: $folderPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Button {
                        chooseFolder()
                    } label: {
                        Text("Choose…", bundle: .module)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                Text(
                    "Files in this folder are indexed in place and never modified. Markdown, plain text, code, and documents (PDF, Word, Excel, PowerPoint, CSV) are supported; YAML frontmatter (`type`, `tags`, …) in markdown is used for filtering.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Git sync is temporarily disabled for the initial Knowledge
            // Collections ship — the clone-from-URL entry point is hidden so no
            // remote-backed collection can be created. `onSave` already passes a
            // nil `remoteURL` whenever this field is empty, so the create path
            // stays local-only. Restore this block to re-enable git sync.
            /*
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
            */

            HStack {
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
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
                .buttonStyle(SettingsButtonStyle(isPrimary: true))
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
        panel.prompt = L("Choose")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
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
                Text(String(format: L("Proposal #%lld"), proposal.id))
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
                    Text(String(format: L("Answers ticket #%lld"), ticketId))
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

// MARK: - Grant To Agents Sheet

/// Shown right after a collection is created so the user can grant it to
/// agents without leaving Knowledge. Closes the UX gap where a new
/// collection was invisible to every agent until the user dug through each
/// agent's Features → Knowledge section. Granting flips `knowledgeEnabled`
/// on and adds the collection id; built-in agents are omitted because
/// `AgentManager.update` refuses to persist them.
private struct KnowledgeGrantAgentsSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let collection: KnowledgeCollection
    /// Passes the number of agents actually granted (0 when none/skipped).
    let onDone: (Int) -> Void

    /// Editable agents, in display order. Built-in agents are excluded up
    /// front since their grants can't be saved.
    private let agents: [Agent]
    @State private var selectedIds: Set<UUID>

    init(collection: KnowledgeCollection, onDone: @escaping (Int) -> Void) {
        self.collection = collection
        self.onDone = onDone
        let editable = AgentManager.shared.agents.filter { !$0.isBuiltIn }
        self.agents = editable
        // Pre-select agents that already have knowledge on, so the common
        // "grant this to my knowledge-using agents" path is one click.
        _selectedIds = State(
            initialValue: Set(editable.filter { $0.settings.knowledgeEnabled }.map(\.id))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Grant \"\(collection.name)\" to agents", bundle: .module)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(
                    "Pick which agents can search and read this collection. You can change this later in each agent's Features → Knowledge section.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if agents.isEmpty {
                Text(
                    "No agents to grant yet. Create an agent, then enable Knowledge for it in its Features section.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(agents) { agent in
                            agentRow(agent)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
            }

            HStack {
                Spacer()
                Button {
                    onDone(0)
                } label: {
                    Text(agents.isEmpty ? "Close" : "Skip", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .keyboardShortcut(.cancelAction)
                if !agents.isEmpty {
                    Button {
                        grant()
                    } label: {
                        Text("Grant Access", bundle: .module)
                    }
                    .buttonStyle(SettingsButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }

    private func agentRow(_ agent: Agent) -> some View {
        let selected = selectedIds.contains(agent.id)
        return Button {
            if selected {
                selectedIds.remove(agent.id)
            } else {
                selectedIds.insert(agent.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !agent.settings.knowledgeEnabled {
                    Text("Enables Knowledge", bundle: .module)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Add the collection to every selected agent and turn Knowledge on so
    /// the grant takes effect. Agents already holding the grant are left
    /// untouched (no redundant write).
    private func grant() {
        var granted = 0
        for agent in agents where selectedIds.contains(agent.id) {
            if agent.settings.knowledgeEnabled
                && agent.settings.knowledgeCollectionIds.contains(collection.id)
            {
                continue
            }
            var updated = agent
            updated.settings.knowledgeEnabled = true
            if !updated.settings.knowledgeCollectionIds.contains(collection.id) {
                updated.settings.knowledgeCollectionIds.append(collection.id)
            }
            AgentManager.shared.update(updated)
            granted += 1
        }
        onDone(granted)
    }
}

// MARK: - Collection Detail Sheet

/// Opened by tapping a collection card. Gathers everything about one
/// collection in a single place: its source/status, index stats, the agents
/// that can reach it (grant/revoke inline), and the indexed documents —
/// closing the gap where this all lived across separate screens.
private struct KnowledgeCollectionDetailSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let collection: KnowledgeCollection
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var confirmingDelete = false
    @State private var documents: [KnowledgeDocument] = []
    @State private var docsLoaded = false
    @State private var nonconformingCount = 0

    /// Re-read from the manager so edits/toggles made elsewhere while this is
    /// open stay reflected; falls back to the captured value if it vanished.
    private var live: KnowledgeCollection {
        knowledgeManager.collection(for: collection.id) ?? collection
    }
    private var isIndexing: Bool {
        knowledgeManager.indexingCollectionIds.contains(collection.id)
    }
    /// Built-in agents are omitted: their grants can't be persisted.
    private var editableAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    infoSection
                    statsSection
                    accessSection
                    documentsSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear(perform: loadData)
    }

    // MARK: Header / Footer

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 20))
                .foregroundColor(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                if !live.summary.isEmpty {
                    Text(live.summary)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                "",
                isOn: Binding(
                    get: { live.isEnabled },
                    set: { enabled in
                        var updated = live
                        updated.isEnabled = enabled
                        knowledgeManager.update(updated)
                    }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("Delete", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(isDestructive: true))
            .confirmationDialog(
                Text(String(format: L("Delete \"%@\"?"), live.name)),
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text("Delete Collection", bundle: .module)
                }
                Button(role: .cancel) {} label: {
                    Text("Cancel", bundle: .module)
                }
            } message: {
                Text(
                    "This removes the collection and its search index from Osaurus. The folder and its files on disk are not touched.",
                    bundle: .module
                )
            }
            Button(action: onEdit) {
                Text("Edit", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle())
            Spacer()
            Button(action: onClose) {
                Text("Done", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: Sections

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title, bundle: .module)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.secondaryText)
            .textCase(.uppercase)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Location")
            HStack(spacing: 6) {
                Image(systemName: live.folderExists ? "folder.fill" : "folder.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundColor(live.folderExists ? theme.tertiaryText : .orange)
                Text(live.folderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if live.isGitRepository {
                    Text("git", bundle: .module)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accentColor.opacity(0.18)))
                        .foregroundColor(theme.accentColor)
                }
            }
            if live.isGitRepository, let remote = live.gitRemoteURL {
                Text(remote)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !live.folderExists {
                Text("Folder not found. Search serves the last indexed state.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Text(
                String(
                    format: L("Created %@ · Updated %@"),
                    live.createdAt.formatted(date: .abbreviated, time: .shortened),
                    live.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Status")
            HStack(spacing: 8) {
                statPill(
                    icon: "doc.text",
                    text: docsLoaded
                        ? (documents.count == 1
                            ? L("1 document")
                            : String(format: L("%lld documents"), documents.count))
                        : L("Loading…"),
                    color: theme.secondaryText
                )
                if docsLoaded && !documents.isEmpty {
                    let categorized = documents.count - nonconformingCount
                    statPill(
                        icon: nonconformingCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        text: nonconformingCount == 0
                            ? L("All categorized")
                            : String(format: L("%lld of %lld categorized"), categorized, documents.count),
                        color: nonconformingCount == 0 ? .green : .orange
                    )
                }
                if isIndexing {
                    statPill(icon: "arrow.triangle.2.circlepath", text: L("Indexing…"), color: theme.accentColor)
                }
            }
        }
    }

    private func statPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Agents with access")
            if editableAgents.isEmpty {
                Text("No agents with access", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(editableAgents) { agent in
                        accessRow(agent)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
            }
        }
    }

    private func accessRow(_ agent: Agent) -> some View {
        let granted = agent.settings.knowledgeCollectionIds.contains(collection.id)
        return HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: theme.accentColor,
                diameter: 24,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 11,
                borderWidth: 0
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { granted }, set: { _ in toggleAccess(agent) }))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
        }
        .padding(10)
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Documents")
            if !docsLoaded {
                Text("Loading…", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            } else if documents.isEmpty {
                Text("No documents indexed yet", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(documents, id: \.id) { doc in
                        documentRow(doc)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.secondaryBackground))
            }
        }
    }

    private func documentRow(_ doc: KnowledgeDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title.isEmpty ? doc.relPath : doc.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(doc.relPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(verbatim: doc.docType.isEmpty ? L("Uncategorized") : doc.docType)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(
                        doc.docType.isEmpty ? Color.orange.opacity(0.15) : theme.accentColor.opacity(0.15)
                    )
                )
                .foregroundColor(doc.docType.isEmpty ? .orange : theme.accentColor)
        }
        .padding(10)
    }

    // MARK: Actions

    private func toggleAccess(_ agent: Agent) {
        var updated = agent
        if updated.settings.knowledgeCollectionIds.contains(collection.id) {
            updated.settings.knowledgeCollectionIds.removeAll { $0 == collection.id }
        } else {
            updated.settings.knowledgeEnabled = true
            updated.settings.knowledgeCollectionIds.append(collection.id)
        }
        agentManager.update(updated)
    }

    /// Read documents + OKF conformance off the main thread (the knowledge DB
    /// serializes on its own queue and must not be touched from main).
    private func loadData() {
        let collectionId = collection.id.uuidString
        Task.detached(priority: .userInitiated) {
            if !KnowledgeDatabase.shared.isOpen {
                try? KnowledgeDatabase.shared.open()
            }
            let docs: [KnowledgeDocument] =
                (try? KnowledgeDatabase.shared.listDocuments(collectionIds: [collectionId], limit: 2000)) ?? []
            let failing = await KnowledgeIndexService.shared.okfNonconformingDocuments(collectionId: collectionId)
            await MainActor.run {
                documents = docs
                nonconformingCount = failing.count
                docsLoaded = true
            }
        }
    }
}
