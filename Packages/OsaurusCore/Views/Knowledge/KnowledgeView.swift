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

/// Sub-navigation for the Knowledge tab.
///
/// History earns its own tab because it is unbounded and the collections are
/// not: the write log keeps up to 2000 records per collection, and a single
/// afternoon of agent work produced enough rows in testing to push the
/// collection grid off screen. It stays hidden until an agent has actually
/// written something.
enum KnowledgeTab: String, CaseIterable {
    case collections
    case history

    var title: String {
        switch self {
        case .collections: return L("Collections")
        case .history: return L("History")
        }
    }
}

private struct CollectionCreateRequest: Identifiable {
    let id = UUID()
    var name = ""
    /// Project the created collection is granted to (a project page's Add
    /// Collection shortcut).
    var grantProjectId: UUID?
}

struct KnowledgeView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var knowledgeManager = KnowledgeManager.shared

    private var theme: any ThemeProtocol { themeManager.currentTheme }

    /// The open create sheet. Its prefill travels with it: a sheet built
    /// from separate state can render before that state lands.
    @State private var createRequest: CollectionCreateRequest?
    @State private var editingCollection: KnowledgeCollection?
    @State private var hasAppeared = false
    @State private var successMessage: String?
    /// Style of the toast currently shown. Failures render as warnings; a
    /// refused revert wearing a green checkmark reads as "reverted".
    @State private var toastType: SimpleToastType = .success

    /// A freshly created collection awaiting the "grant to agents" prompt.
    /// Set right after `create`/`createFromGit` succeeds so the user can
    /// grant access inline instead of hunting through each agent's settings.
    @State private var grantingCollection: KnowledgeCollection?

    /// The collection whose detail sheet is open (tap a card to set it).
    @State private var detailCollection: KnowledgeCollection?

    // Curation review state (Phase 2).
    @State private var openTickets: [KnowledgeTicket] = []
    @State private var pendingProposals: [KnowledgeProposal] = []
    /// Recent agent writes, grouped by run, for the history + revert section.
    @State private var writeRuns: [KnowledgeWriteRun] = []
    @State private var reviewingProposal: KnowledgeProposal?
    @State private var selectedTab: KnowledgeTab = .collections
    @State private var searchText = ""

    private var filteredCollections: [KnowledgeCollection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return knowledgeManager.collections }
        return knowledgeManager.collections.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(theme.motion.springAnimation, value: hasAppeared)

            ZStack {
                if knowledgeManager.collections.isEmpty {
                    SettingsEmptyState(
                        icon: "books.vertical.fill",
                        title: "Add Your First Knowledge Collection",
                        subtitle: L(
                            "Point Osaurus at a folder of guides, templates, and standards and grant it to agents so they can consult it on demand. Markdown, plain text, code, PDF, Word, Excel, PowerPoint, and CSV files are supported."
                        ),
                        examples: [
                            .init(
                                icon: "doc.text",
                                title: L("Guides & Policies"),
                                description: L("How your team does things, written down"),
                                action: { createCollection(named: L("Guides & Policies")) }
                            ),
                            .init(
                                icon: "square.on.square",
                                title: L("Templates"),
                                description: L("Wording you reuse, like email replies"),
                                action: { createCollection(named: L("Templates")) }
                            ),
                            .init(
                                icon: "book",
                                title: L("How-To Steps"),
                                description: L("Simple instructions for everyday tasks"),
                                action: { createCollection(named: L("How-To Steps")) }
                            ),
                        ],
                        primaryAction: .init(
                            title: L("Add Collection"),
                            icon: "plus",
                            handler: { createRequest = CollectionCreateRequest() }
                        ),
                        hasAppeared: hasAppeared
                    )
                    .padding(.horizontal, theme.space.s32)
                    // Falls back to Collections rather than showing an empty
                    // tab: the selector is gone once the log is, and a
                    // selection left pointing at it would strand the view.
                } else if selectedTab == .history, !writeRuns.isEmpty {
                    ScrollView {
                        fullHistorySection
                    }
                    .opacity(hasAppeared ? 1 : 0)
                } else {
                    ScrollView {
                        curationSection
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 300), spacing: theme.libraryGridGap),
                                GridItem(.flexible(minimum: 300), spacing: theme.libraryGridGap),
                            ],
                            spacing: theme.libraryGridGap
                        ) {
                            ForEach(Array(filteredCollections.enumerated()), id: \.element.id) {
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
                        .settingsPageInsets()
                    }
                    .opacity(hasAppeared ? 1 : 0)
                }

                if let message = successMessage {
                    VStack {
                        Spacer()
                        ThemedToastView(message, type: toastType)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, theme.space.s16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .sheet(item: $createRequest) { request in
            KnowledgeCollectionEditorSheet(
                collection: nil,
                initialName: request.name,
                onSave: {
                    [grantProjectId = request.grantProjectId]
                    name, summary, folderPath, remoteURL, includeGlobs, excludeGlobs in
                    createRequest = nil
                    if let remoteURL, !remoteURL.isEmpty {
                        showSuccess("Cloning \"\(name)\"…")
                        Task {
                            do {
                                let created = try await knowledgeManager.createFromGit(
                                    name: name,
                                    summary: summary,
                                    remoteURL: remoteURL
                                )
                                grantToRequestingProject(created, projectId: grantProjectId)
                                showSuccess("Cloned \"\(created.name)\", indexing in the background")
                                grantingCollection = created
                            } catch {
                                showSuccess(
                                    "Clone failed: \(error.localizedDescription)",
                                    type: .error
                                )
                            }
                        }
                    } else {
                        Task {
                            let created = await knowledgeManager.create(
                                name: name,
                                summary: summary,
                                folderPath: folderPath,
                                includeGlobs: includeGlobs,
                                excludeGlobs: excludeGlobs
                            )
                            grantToRequestingProject(created, projectId: grantProjectId)
                            showSuccess("Added \"\(created.name)\", indexing in the background")
                            grantingCollection = created
                        }
                    }
                },
                onCancel: { createRequest = nil }
            )
        }
        .sheet(item: $editingCollection) { collection in
            KnowledgeCollectionEditorSheet(
                collection: collection,
                onSave: { name, summary, folderPath, _, includeGlobs, excludeGlobs in
                    var updated = collection
                    updated.name = name
                    updated.summary = summary
                    updated.folderPath = folderPath
                    updated.includeGlobs = includeGlobs
                    updated.excludeGlobs = excludeGlobs
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
                            await MainActor.run {
                                showSuccess(
                                    "Approve failed: \(error.localizedDescription)",
                                    type: .error
                                )
                            }
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
            withAnimation(theme.motion.standard.delay(0.05)) {
                hasAppeared = true
            }
            reloadCuration()
            applyPendingCreateRequest()
            applyPendingDetailRequest()
        }
        // Deep link from the project page's Add Collection shortcut: pop the
        // create sheet directly instead of landing the user on the tab to
        // click the same button again. One-shot; also handled in `.onAppear`
        // for the case where the request is set before this view mounts.
        .onReceive(ManagementStateManager.shared.$pendingKnowledgeCreate) { pending in
            if pending != nil { applyPendingCreateRequest() }
        }
        .onReceive(ManagementStateManager.shared.$pendingKnowledgeDetailId) { pending in
            if pending != nil { applyPendingDetailRequest() }
        }
        // The deep link can land before the lazily loaded registry has the
        // collection; retry when collections settle.
        .onReceive(knowledgeManager.$collections) { _ in
            applyPendingDetailRequest()
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

    private func applyPendingDetailRequest() {
        guard let id = ManagementStateManager.shared.pendingKnowledgeDetailId,
            let collection = knowledgeManager.collections.first(where: { $0.id == id })
        else { return }
        ManagementStateManager.shared.pendingKnowledgeDetailId = nil
        detailCollection = collection
    }

    private func createCollection(named name: String) {
        createRequest = CollectionCreateRequest(name: name)
    }

    private func applyPendingCreateRequest() {
        guard let request = ManagementStateManager.shared.pendingKnowledgeCreate else { return }
        ManagementStateManager.shared.pendingKnowledgeCreate = nil
        createRequest = CollectionCreateRequest(name: request.prefillName, grantProjectId: request.grantProjectId)
    }

    /// Grant a freshly created collection to the deep link's project, so the
    /// user returns to the project page with the new collection already
    /// checked instead of having to toggle it on themselves.
    private func grantToRequestingProject(_ collection: KnowledgeCollection, projectId: UUID?) {
        guard let projectId, var project = ProjectManager.shared.project(for: projectId) else {
            return
        }
        guard !project.knowledgeCollectionIds.contains(collection.id) else { return }
        project.knowledgeCollectionIds.append(collection.id)
        ProjectManager.shared.update(project)
    }

    // MARK: - Curation

    @ViewBuilder
    private var curationSection: some View {
        if !pendingProposals.isEmpty || !openTickets.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                Text("Curation", bundle: .module)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Text(
                    "Agents leave a note here when a document looks out of date but fixing it was not the task at hand. Open one in a chat to have an agent correct it; you review the change before it is saved.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                // Drain-only. Nothing creates proposals any more — the tool
                // and the curator role are gone — but drafts already queued
                // are the user's, so they get reviewed rather than discarded
                // on upgrade. This block and the `proposals` table go once
                // these can reasonably be assumed drained.
                if !pendingProposals.isEmpty {
                    Text(
                        "Left over from the old review flow. Approve or dismiss these; agents now write documents directly, with your approval at the time.",
                        bundle: .module
                    )
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(pendingProposals) { proposal in
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "doc.badge.ellipsis")
                            .glyphSize(13)
                            .foregroundColor(theme.text.link)
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(String(format: L("Proposal #%lld: %@"), proposal.id, proposal.relPath))
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                                .foregroundColor(theme.text.primary)
                            Text(proposal.rationale)
                                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button {
                            reviewingProposal = proposal
                        } label: {
                            Text("Review", bundle: .module)
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        }
                    }
                    .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
                    .settingsChrome(.inset)
                }

                ForEach(openTickets) { ticket in
                    HStack(spacing: theme.space.s8) {
                        Image(systemName: "exclamationmark.bubble")
                            .glyphSize(13)
                            .foregroundColor(theme.status.warning.foreground)
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(String(format: L("Ticket #%lld: %@"), ticket.id, ticket.relPath))
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                                .foregroundColor(theme.text.primary)
                            Text(ticket.reason)
                                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .lineLimit(2)
                            Text("Open this in a chat to have it fixed", bundle: .module)
                                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                                .foregroundColor(theme.status.warning.foreground)
                        }
                        Spacer(minLength: 8)
                        Button {
                            startTicketFix(for: ticket)
                        } label: {
                            Text("Fix in a chat", bundle: .module)
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        }
                        Button {
                            Task.detached(priority: .userInitiated) {
                                try? await KnowledgeCurationService.shared.dismissTicket(ticketId: ticket.id)
                            }
                        } label: {
                            Text("Dismiss", bundle: .module)
                                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                                .foregroundColor(theme.text.secondary)
                        }
                    }
                    .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
                    .settingsChrome(.inset)
                }
            }
            .padding(.horizontal, theme.settingsPageInset)
            .padding(.top, theme.settingsPageTop)
        }
    }

    /// An agent that can act on `collectionId`.
    /// on, and this collection granted. `nil` when the user hasn't set one up.
    /// Any agent granted this collection can now fix a ticket: write access
    /// follows the grant, not a separate curator role.
    private func agentGranted(forCollectionId collectionId: String) -> Agent? {
        guard let uuid = UUID(uuidString: collectionId) else { return nil }
        return AgentManager.shared.agents.first { agent in
            agent.settings.knowledgeEnabled
                && agent.settings.knowledgeCollectionIds.contains(uuid)
        }
    }

    /// Give the user a forward action beyond Dismiss: open a chat with a
    /// granted agent whose composer is pre-filled with a briefing for this
    /// ticket, so the user lands with the request ready to send instead of a
    /// blank window. The agent corrects the document with `write_knowledge`
    /// through the normal chat + tool path, showing a diff for approval.
    private func startTicketFix(for ticket: KnowledgeTicket) {
        guard let agent = agentGranted(forCollectionId: ticket.collectionId) else {
            showSuccess(
                L("No agent has this collection yet. Grant it to one in Features → Knowledge."),
                type: .warning
            )
            return
        }
        let windowId = ChatWindowManager.shared.createWindow(agentId: agent.id)
        // Seed the composer so the window isn't a blank prompt. The reviewer
        // can edit or send as-is; the agent fixes the document with
        // `write_knowledge`, which shows a diff for approval at call time.
        let collectionName =
            (UUID(uuidString: ticket.collectionId)
            .flatMap { KnowledgeManager.shared.collection(for: $0)?.name }) ?? ""
        let collectionClause = collectionName.isEmpty ? "" : " in the \"\(collectionName)\" collection"
        let briefing =
            "Please work knowledge ticket #\(ticket.id) for `\(ticket.relPath)`\(collectionClause).\n"
            + "Reported issue: \(ticket.reason)\n\n"
            + "Read the current document, and if it is out of date, use "
            + "write_knowledge to correct it. Keep the existing frontmatter. "
            + "I will review the diff before it is saved."
        ChatWindowManager.shared.windowState(id: windowId)?.session.input = briefing
        showSuccess(L("Opened \(agent.name) with a briefing for ticket #\(ticket.id). Review it and hit send."))
    }

    /// The History tab: every run, with collection and reverted filters.
    ///
    /// The only surface for agent writes. The Collections tab used to carry a
    /// duplicate strip of the same rows; with a tab of its own, that was the
    /// same list rendered twice on one screen.
    private var fullHistorySection: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(
                "Everything agents have written to your collections, newest first. Reverting puts the document back the way it was before that run.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            historyList
        }
        .settingsPageInsets()
    }

    private var historyList: some View {
        KnowledgeWriteHistoryView(
            runs: writeRuns,
            onRevertRun: { run in
                Task {
                    let failures = await KnowledgeWriteService.shared.revertRun(
                        runId: run.runId
                    )
                    // A single-document run gets a sentence about that
                    // document. The batch arithmetic ("Reverted 0 of 1")
                    // is only for runs where partial success is possible.
                    if let only = run.records.first, run.records.count == 1 {
                        if failures.isEmpty {
                            showSuccess(L("Reverted \(only.relPath)"))
                        } else {
                            showSuccess(
                                L(
                                    "Did not revert \(only.relPath): the document changed after the agent wrote it."
                                ),
                                type: .warning
                            )
                        }
                    } else if failures.isEmpty {
                        showSuccess(
                            run.records.count == 1
                                ? L("Reverted 1 document") : L("Reverted \(run.records.count) documents"))
                    } else {
                        // Best-effort per record: say what could not be put
                        // back rather than implying the whole run undid.
                        showSuccess(
                            L(
                                "Reverted \(run.records.count - failures.count) of \(run.records.count) documents. The rest changed after the agent wrote them, so they were left alone."
                            ),
                            type: .warning
                        )
                    }
                    reloadCuration()
                }
            },
            onRevertRecord: { record in
                Task {
                    do {
                        try await KnowledgeWriteService.shared.revert(recordId: record.id)
                        showSuccess(L("Reverted \(record.relPath)"))
                    } catch {
                        showSuccess(
                            L("Could not revert: \(error.localizedDescription)"),
                            type: .warning
                        )
                    }
                    reloadCuration()
                }
            }
        )
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
            // The write log is a separate store (it is primary data, not a
            // rebuildable index), so it opens independently.
            if !KnowledgeWriteLogDatabase.shared.isOpen {
                try? KnowledgeWriteLogDatabase.shared.open()
            }
            let writes =
                (try? KnowledgeWriteLogDatabase.shared.recentRecords(limit: 200)) ?? []
            let names = await MainActor.run {
                Dictionary(
                    uniqueKeysWithValues: KnowledgeManager.shared.collections.map {
                        ($0.id.uuidString, $0.name)
                    }
                )
            }
            let runs = KnowledgeWriteRun.group(writes, collectionNames: names)
            await MainActor.run {
                // Assign only on a real change so the periodic poll can't churn
                // the view every tick. Both lists are single-status queries, so
                // comparing ids is sufficient to detect add/remove/status moves.
                if tickets.map(\.id) != openTickets.map(\.id) { openTickets = tickets }
                if proposals.map(\.id) != pendingProposals.map(\.id) { pendingProposals = proposals }
                // Compare the flattened record ids AND their reverted state:
                // a revert changes no ids, only status, and the row has to
                // stop offering a button that would now fail.
                let incoming = runs.flatMap { $0.records.map { "\($0.id):\($0.isReverted)" } }
                let current = writeRuns.flatMap { $0.records.map { "\($0.id):\($0.isReverted)" } }
                if incoming != current { writeRuns = runs }
            }
        }
    }

    /// History (what agents wrote) opens as a pushed page; its button only
    /// appears once an agent has actually written something.
    @ViewBuilder
    private var headerView: some View {
        if selectedTab == .history, !writeRuns.isEmpty {
            SettingsPageHeader(
                title: "History",
                subtitle: "Everything agents added to or changed in your collections"
            )
            .settingsBackDestination(L("Knowledge"), verbatim: true) { selectedTab = .collections }
        } else {
            SettingsPageHeader(
                title: "Knowledge",
                subtitle: "Folders of documents your agents can search and read on demand",
                count: knowledgeManager.collections.count,
                onRefresh: {
                    knowledgeManager.scheduleIndexAll()
                    showSuccess("Incremental re-index started")
                },
                refreshHelp: "Re-index all collections",
                secondary: {
                    if !writeRuns.isEmpty {
                        SettingsButton(.secondary, L("History (\(writeRuns.count))"), icon: "clock.arrow.circlepath") {
                            withAnimation(theme.motion.quick) { selectedTab = .history }
                        }
                    }
                },
                primary: {
                    SettingsButton(.primary, "Add Collection", icon: "plus") {
                        createRequest = CollectionCreateRequest()
                    }
                },
                toolbar: {
                    if !knowledgeManager.collections.isEmpty {
                        SettingsHeaderToolbar(searchText: $searchText, searchPlaceholder: "Search collections")
                    }
                }
            )
        }
    }

    private func showSuccess(_ message: String, type: SimpleToastType = .success) {
        withAnimation(theme.motion.springAnimation) {
            successMessage = message
            toastType = type
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(theme.motion.quick) {
                successMessage = nil
            }
        }
    }
}

// MARK: - Collection Card

private struct KnowledgeCollectionCard: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var projectManager = ProjectManager.shared

    let collection: KnowledgeCollection
    let animationDelay: Double
    let hasAppeared: Bool
    let onToggle: (Bool) -> Void
    let onReindex: () -> Void
    let isIndexing: Bool
    let onSync: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenDetail: () -> Void

#if OSAURUS_DESIGN_SYSTEM
    var inspectionDisplayOnly = false
#endif

    /// OKF conformance, computed on appear so the badge shows status at a
    /// glance rather than hiding it behind a click.
    private enum OKFStatus: Equatable {
        case unknown
        case conformant
        case nonconforming(Int)
    }
    @State private var okfStatus: OKFStatus = .unknown

    /// Alert shown when the category chip is tapped: the uncategorized
    /// paths (empty when everything has a category).
    @State private var showingCategoryAlert = false
    @State private var uncategorizedPaths: [String] = []

    private var okfIcon: String {
        switch okfStatus {
        case .conformant: return "checkmark.seal.fill"
        case .nonconforming: return "tag.slash"
        case .unknown: return "checkmark.seal"
        }
    }

    private var okfLabel: String {
        switch okfStatus {
        case .conformant: return L("All categorized")
        case .nonconforming(let count):
            return count == 1
                ? L("1 doc uncategorized")
                : String(format: L("%lld docs uncategorized"), count)
        case .unknown: return L("Checking categories…")
        }
    }

    private var okfColor: Color {
        switch okfStatus {
        case .conformant: return theme.status.success.foreground
        case .nonconforming: return theme.text.secondary
        case .unknown: return theme.text.secondary
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
        HStack(spacing: theme.space.s6) {
            if agents.isEmpty {
                Image(systemName: "person.slash")
                    .glyphSize(10)
                    .foregroundColor(theme.text.tertiary)
                Text("No agents with access", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            } else {
                HStack(spacing: -8) {
                    ForEach(shown) { agent in
                        AgentAvatarView(
                            mascotId: agent.avatar,
                            name: agent.name,
                            tint: theme.action.primary.default.background,
                            diameter: 20,
                            customImageURL: agent.customAvatarURL,
                            monogramFontSize: 9,
                            borderWidth: 0
                        )
                        .overlay(Circle().stroke(theme.surface.subtle, lineWidth: theme.stroke.default))
                    }
                }
                Text(
                    agents.count == 1
                        ? L("1 agent")
                        : String(format: L("%lld agents"), agents.count)
                )
                .componentInspectionText(53, role: .caption, fallback: .footnote, theme: theme)
                .foregroundColor(theme.text.secondary)
            }
        }
        .help(
            agents.isEmpty
                ? L("No agents can use this collection yet")
                : L("Agents with access: \(agents.map(\.name).joined(separator: ", "))")
        )
    }

    /// Projects granting this collection to their chats. Purely informational
    /// — grants are edited in Settings → Projects; the card just surfaces the
    /// blast radius of disabling or deleting the collection.
    private var grantingProjects: [Project] {
        projectManager.projects.filter { $0.knowledgeCollectionIds.contains(collection.id) }
    }

    @ViewBuilder
    private var grantingProjectsRow: some View {
        let projects = grantingProjects
        if !projects.isEmpty {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "folder")
                    .glyphSize(10)
                    .foregroundColor(theme.text.secondary)
                Text(
                    projects.count == 1
                        ? String(format: L("Used by project %@"), projects[0].name)
                        : String(format: L("Used by %lld projects"), projects.count)
                )
                .componentInspectionText(53, role: .caption, fallback: .footnote, theme: theme)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .help(L("Projects using this collection: \(projects.map(\.name).joined(separator: ", ")). Change this in Projects."))
        }
    }

    private var okfHelp: String {
        switch okfStatus {
        case .conformant:
            return L(
                "Every document has a category, so agents can filter the library by it. Categories come from frontmatter `type:` or are inferred automatically from folder names."
            )
        case .nonconforming(let count):
            return count == 1
                ? L(
                    "1 document has no category. This is optional, agents can still search and read it. To let agents filter by category, add a `type:` line (e.g. `type: policy`) to the top of the file. Click for the list."
                )
                : String(
                    format: L(
                        "%lld documents have no category. This is optional, agents can still search and read them. To let agents filter by category, add a `type:` line (e.g. `type: policy`) to the top of each file. Click for the list."
                    ), count)
        case .unknown:
            return L("Checking that every document declares a category (its `type`)…")
        }
    }

    private var categoryAlertTitle: String {
        if uncategorizedPaths.isEmpty { return L("All documents categorized") }
        return uncategorizedPaths.count == 1
            ? L("1 document has no category")
            : String(format: L("%lld documents have no category"), uncategorizedPaths.count)
    }

    private var categoryAlertMessage: String {
        if uncategorizedPaths.isEmpty {
            return L(
                "Every document has a category, from its frontmatter `type:` or inferred from its folder name. Agents can filter this collection by category."
            )
        }
        let sample = uncategorizedPaths.prefix(8).joined(separator: "\n")
        let more = uncategorizedPaths.count - min(8, uncategorizedPaths.count)
        return L(
            "This is optional. Agents can still search and read these documents.\n\nTo let agents filter by category, move them into a folder (the folder name becomes the category) or add a `type:` line to their frontmatter.\n\n"
        ) + sample + (more > 0 ? "\n" + String(format: L("and %lld more"), more) : "")
    }

    private func refreshOKFStatus() async {
#if OSAURUS_DESIGN_SYSTEM
        if inspectionDisplayOnly { okfStatus = .conformant; return }
#endif
        let failing = await KnowledgeIndexService.shared
            .uncategorizedDocuments(collectionId: collection.id.uuidString)
        uncategorizedPaths = failing
        okfStatus = failing.isEmpty ? .conformant : .nonconforming(failing.count)
    }

    var body: some View {
        LibraryCard(
            title: collection.name,
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onOpenDetail
        ) {
            LibraryIcon(symbol: "books.vertical.fill", tint: theme.action.primary.default.background)
        } accessory: {
            Toggle("", isOn: Binding(get: { collection.isEnabled }, set: onToggle))
                .settingsSwitch()
        } content: {
            if !collection.summary.isEmpty {
                LibraryCardPreview(text: collection.summary)
            }
            // Folder path and git remote intentionally omitted — they
            // crowd the card and live in the detail sheet (tap the card).
            grantedAgentsRow
            grantingProjectsRow
            categoryChip
            if !collection.folderExistsCached {
                Text("Folder not found. Search serves the last indexed state.", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.status.warning.foreground)
            }
        } footer: {
            HStack(spacing: theme.space.s8) {
                if collection.isGitRepositoryCached {
                    SettingsButton(.secondary, "Sync", icon: "arrow.triangle.2.circlepath.circle", size: .compact, action: onSync)
                }
                SettingsButton(
                    .secondary,
                    isIndexing ? "Indexing…" : "Re-index",
                    icon: isIndexing ? nil : "arrow.triangle.2.circlepath",
                    isLoading: isIndexing,
                    size: .compact,
                    help: isIndexing ? "Indexing in progress" : nil,
                    action: onReindex
                )
                .disabled(isIndexing)
                SettingsButton(.secondary, "Edit", icon: "pencil", size: .compact, action: onEdit)
                Spacer()
                SettingsButton(.destructive, "Delete", icon: "trash", size: .compact, action: onDelete)
            }
        }
    }

    private var categoryChip: some View {
        Button(action: {
            Task {
                await refreshOKFStatus()
                showingCategoryAlert = true
            }
        }) {
            StatusChip(okfLabel, tint: okfColor, icon: okfIcon)
        }
        .buttonStyle(.plain)
        .help(okfHelp)
        .themedAlert(
            categoryAlertTitle,
            isPresented: $showingCategoryAlert,
            message: categoryAlertMessage,
            primaryButton: .cancel(L("OK"))
        )
        .task(id: collection.updatedAt) { await refreshOKFStatus() }
        .onChange(of: isIndexing) { indexing in
            // Recompute the category badge once the pass completes and
            // the index reflects the folder on disk.
            if !indexing { Task { await refreshOKFStatus() } }
        }
    }
}

// MARK: - Editor Sheet

private struct KnowledgeCollectionEditorSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    /// nil → create mode.
    let collection: KnowledgeCollection?
    /// `remoteURL` is non-nil only in create mode when the user chose to
    /// clone from a git URL instead of picking a local folder.
    let onSave:
        (
            _ name: String, _ summary: String, _ folderPath: String, _ remoteURL: String?,
            _ includeGlobs: [String], _ excludeGlobs: [String]
        ) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var summary: String
    @State private var folderPath: String
    @State private var remoteURL: String = ""
    @State private var includeGlobs: String
    @State private var excludeGlobs: String

    init(
        collection: KnowledgeCollection?,
        initialName: String = "",
        onSave: @escaping (
            _ name: String, _ summary: String, _ folderPath: String, _ remoteURL: String?,
            _ includeGlobs: [String], _ excludeGlobs: [String]
        ) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.collection = collection
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: collection?.name ?? initialName)
        _summary = State(initialValue: collection?.summary ?? "")
        _folderPath = State(initialValue: collection?.folderPath ?? "")
        _includeGlobs = State(initialValue: (collection?.includeGlobs ?? []).joined(separator: ", "))
        _excludeGlobs = State(initialValue: (collection?.excludeGlobs ?? []).joined(separator: ", "))
    }

    /// Split a comma-or-newline separated pattern field into trimmed,
    /// non-empty patterns.
    private static func parseGlobs(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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
        VStack(alignment: .leading, spacing: theme.space.s16) {
            Text(collection == nil ? "Add Knowledge Collection" : "Edit Knowledge Collection", bundle: .module)
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.cardTitle)
                .foregroundColor(theme.text.primary)

            SettingsTextFieldRow(
                label: "Name",
                text: $name,
                placeholder: "WordPress Development",
                help: ""
            )

            SettingsTextFieldRow(
                label: "Summary (optional)",
                text: $summary,
                placeholder: "What this corpus contains, shown to agents",
                help: ""
            )

            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Folder", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                HStack(spacing: theme.space.s8) {
                    SettingsTextField(placeholder: "/path/to/knowledge-folder", text: $folderPath, monospaced: true)
                    Button {
                        chooseFolder()
                    } label: {
                        Text("Choose…", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary, size: .compact)
                }
                Text(
                    "Files in this folder are indexed in place and never modified. Markdown, plain text, code, and documents (PDF, Word, Excel, PowerPoint, CSV) are supported; YAML frontmatter (`type`, `tags`, …) in markdown is used for filtering.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: theme.space.s6) {
                Text("Index filters (optional)", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                SettingsTextFieldRow(
                    label: "Include",
                    text: $includeGlobs,
                    placeholder: "docs/**, *.md",
                    help: "",
                    monospaced: true
                )
                SettingsTextFieldRow(
                    label: "Exclude",
                    text: $excludeGlobs,
                    placeholder: "src/**, test/**",
                    help: "",
                    monospaced: true
                )
                Text(
                    "Junk and .gitignore files are skipped automatically. Most folders need nothing here.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    globHintRow("Include: index only matching files, e.g. docs/**")
                    globHintRow("Exclude: skip matching files. Wins over Include.")
                    globHintRow("* matches inside a folder, ** across folders.")
                    globHintRow("Editing re-indexes the collection.")
                }
            }

            // Git sync is temporarily disabled for the initial Knowledge
            // Collections ship — the clone-from-URL entry point is hidden so no
            // remote-backed collection can be created. `onSave` already passes a
            // nil `remoteURL` whenever this field is empty, so the create path
            // stays local-only. Restore this block to re-enable git sync.
            /*
            if collection == nil {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    Text("Or clone from a git URL", bundle: .module)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    SettingsTextField(
                        placeholder: "https://github.com/team/knowledge.git",
                        text: $remoteURL,
                        monospaced: true
                    )
                    Text(
                        "Clones into Osaurus-managed storage and keeps the git link for Sync. Uses your existing git credentials (credential helper or SSH agent). Leave empty to use the folder above.",
                        bundle: .module
                    )
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
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
                .assignedSettingsButtonStyle()
                .keyboardShortcut(.cancelAction)
                Button {
                    onSave(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary.trimmingCharacters(in: .whitespacesAndNewlines),
                        folderPath.trimmingCharacters(in: .whitespacesAndNewlines),
                        (collection == nil && !trimmedRemote.isEmpty) ? trimmedRemote : nil,
                        Self.parseGlobs(includeGlobs),
                        Self.parseGlobs(excludeGlobs)
                    )
                } label: {
                    Text(collection == nil ? "Add" : "Save", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        .frame(width: 460)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
    }

    /// One bulleted hint line under the index-filter fields.
    private func globHintRow(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
            Text("•")
            Text(text, bundle: .module)
                .fixedSize(horizontal: false, vertical: true)
        }
        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
        .foregroundColor(theme.text.tertiary)
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
    private var theme: any ThemeProtocol { themeManager.currentTheme }

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
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: L("Proposal #%lld"), proposal.id))
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                AssignedBaseSegmentedPicker(
                    selection: $viewMode,
                    options: ViewMode.allCases.map { .init($0, $0.rawValue) },
                    size: .compact
                )
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text("[\(collectionName)] \(proposal.relPath)")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                if let ticketId = proposal.ticketId {
                    Text(String(format: L("Answers ticket #%lld"), ticketId))
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
                Text(proposal.rationale)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.primary)
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
            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)

            HStack {
                Button {
                    onDismissProposal()
                } label: {
                    Text("Dismiss Proposal", bundle: .module)
                        .foregroundColor(theme.status.error.foreground)
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
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        .frame(width: 680)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .onAppear(perform: loadDiff)
    }

    // MARK: - Panes

    @ViewBuilder
    private var diffPane: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text(currentContent.isEmpty ? "New document" : "Changes vs. current document", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            ScrollView {
                if !diffLoaded {
                    Text("Loading…", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diffLines) { line in
                            diffRow(line)
                        }
                    }
                    .padding(.horizontal, theme.space.s6).padding(.vertical, theme.space.s6)
                }
            }
            .frame(minHeight: 240, maxHeight: 380)
            .settingsChrome(.inset)
        }
    }

    private func diffRow(_ line: KnowledgeDiff.Line) -> some View {
        let (prefix, color, background): (String, Color, Color) = {
            switch line.kind {
            case .context: return (" ", theme.text.tertiary, .clear)
            case .added: return ("+", theme.status.success.foreground, theme.status.success.background)
            case .removed: return ("-", theme.status.error.foreground, theme.status.error.background)
            }
        }()
        return HStack(alignment: .top, spacing: theme.space.s6) {
            Text(prefix)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(color)
            Text(line.text.isEmpty ? " " : line.text)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                .foregroundColor(line.kind == .context ? theme.text.primary : color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, theme.space.s4)
        .padding(.vertical, theme.space.s2)
        .background(background)
    }

    @ViewBuilder
    private var editPane: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text("Edit before approving", bundle: .module)
                .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
            SettingsTextEditor(text: $editedContent, minHeight: 240, maxHeight: 380, monospaced: true)
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
    private var theme: any ThemeProtocol { themeManager.currentTheme }

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
        VStack(alignment: .leading, spacing: theme.space.s16) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text("Grant \"\(collection.name)\" to agents", bundle: .module)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Text(
                    "Pick which agents can search and read this collection. You can change this later in each agent's Features → Knowledge section.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if agents.isEmpty {
                Text(
                    "No agents to grant yet. Create an agent, then enable Knowledge for it in its Features section.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, theme.space.s24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(agents) { agent in
                            agentRow(agent)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
                .settingsChrome(.inset)
            }

            HStack {
                Spacer()
                Button {
                    onDone(0)
                } label: {
                    Text(agents.isEmpty ? "Close" : "Skip", bundle: .module)
                }
                .assignedSettingsButtonStyle()
                .keyboardShortcut(.cancelAction)
                if !agents.isEmpty {
                    Button {
                        grant()
                    } label: {
                        Text("Grant Access", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        .frame(width: 460)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
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
            HStack(spacing: theme.space.s8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .glyphSize(14)
                    .foregroundColor(selected ? theme.text.link : theme.text.tertiary)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(agent.name)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                    if !agent.displayDescription.isEmpty {
                        Text(agent.displayDescription)
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !agent.settings.knowledgeEnabled {
                    Text("Enables Knowledge", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(theme.text.secondary)
                }
            }
            .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
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
    private var theme: any ThemeProtocol { themeManager.currentTheme }

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
                VStack(alignment: .leading, spacing: theme.settingsSectionGap) {
                    infoSection
                    statsSection
                    accessSection
                    documentsSection
                }
                .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
            }
            Divider()
            footer
        }
        .fittedSheetFrame(width: 560, height: 640)
        .background(theme.surface.canvas)
        .environment(\.theme, theme)
        .onAppear(perform: loadData)
    }

    // MARK: Header / Footer

    private var header: some View {
        SettingsDetailHeader(
            icon: "books.vertical.fill",
            title: live.name,
            subtitle: live.summary
        ) {
            EmptyView()
        } actions: {
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
            .settingsSwitch()
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
    }

    private var footer: some View {
        HStack(spacing: theme.space.s8) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("Delete", bundle: .module)
            }
            .assignedSettingsButtonStyle(.destructive)
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
            .assignedSettingsButtonStyle()
            Spacer()
            Button(action: onClose) {
                Text("Done", bundle: .module)
            }
            .assignedSettingsButtonStyle(.primary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
    }

    // MARK: Sections

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title, bundle: .module)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
            .foregroundColor(theme.text.secondary)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            sectionHeader("Location")
            HStack(spacing: theme.space.s6) {
                Image(systemName: live.folderExistsCached ? "folder.fill" : "folder.badge.questionmark")
                    .glyphSize(11)
                    .foregroundColor(live.folderExistsCached ? theme.text.tertiary : .orange)
                Text(live.folderPath)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if live.isGitRepositoryCached {
                    StatusChip(L("git"), tone: .accent)
                        .foregroundColor(theme.text.link)
                }
            }
            if live.isGitRepositoryCached, let remote = live.gitRemoteURL {
                Text(remote)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !live.folderExistsCached {
                Text("Folder not found. Search serves the last indexed state.", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
            }
            Text(
                String(
                    format: L("Created %@ · Updated %@"),
                    live.createdAt.formatted(date: .abbreviated, time: .shortened),
                    live.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            )
            .componentInspectionText(53, role: .caption, fallback: .footnote, theme: theme)
            .foregroundColor(theme.text.tertiary)
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            sectionHeader("Status")
            HStack(spacing: theme.space.s8) {
                statPill(
                    icon: "doc.text",
                    text: docsLoaded
                        ? (documents.count == 1
                            ? L("1 document")
                            : String(format: L("%lld documents"), documents.count))
                        : L("Loading…"),
                    color: theme.text.secondary
                )
                if docsLoaded && !documents.isEmpty {
                    let categorized = documents.count - nonconformingCount
                    statPill(
                        icon: nonconformingCount == 0 ? "checkmark.seal.fill" : "tag.slash",
                        text: nonconformingCount == 0
                            ? L("All categorized")
                            : String(format: L("%lld of %lld categorized"), categorized, documents.count),
                        color: nonconformingCount == 0 ? .green : theme.text.secondary
                    )
                }
                if isIndexing {
                    statPill(
                        icon: "arrow.triangle.2.circlepath",
                        text: L("Indexing…"),
                        color: theme.action.primary.default.background
                    )
                }
            }
        }
    }

    private func statPill(icon: String, text: String, color: Color) -> some View {
        StatusChip(text, tint: color, icon: icon)
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            sectionHeader("Agents with access")
            if editableAgents.isEmpty {
                Text("No agents with access", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(editableAgents) { agent in
                        accessRow(agent)
                    }
                }
                .settingsChrome(.inset)
            }
        }
    }

    private func accessRow(_ agent: Agent) -> some View {
        let granted = agent.settings.knowledgeCollectionIds.contains(collection.id)
        return HStack(spacing: theme.space.s8) {
            AgentAvatarView(
                mascotId: agent.avatar,
                name: agent.name,
                tint: theme.action.primary.default.background,
                diameter: 24,
                customImageURL: agent.customAvatarURL,
                monogramFontSize: 11,
                borderWidth: 0
            )
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(agent.name)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                if !agent.displayDescription.isEmpty {
                    Text(agent.displayDescription)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { granted }, set: { _ in toggleAccess(agent) }))
                .settingsSwitch()
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            sectionHeader("Documents")
            if !docsLoaded {
                Text("Loading…", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            } else if documents.isEmpty {
                Text("No documents indexed yet", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(documents, id: \.id) { doc in
                        documentRow(doc)
                    }
                }
                .settingsChrome(.inset)
            }
        }
    }

    private func documentRow(_ doc: KnowledgeDocument) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "doc.text")
                .glyphSize(12)
                .foregroundColor(theme.text.tertiary)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(doc.title.isEmpty ? doc.relPath : doc.title)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text(doc.relPath)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StatusChip(
                doc.effectiveType.isEmpty
                    ? L("Uncategorized")
                    : doc.isTypeInferred
                        ? String(format: L("%@ (auto)"), doc.effectiveType) : doc.effectiveType,
                tone: doc.effectiveType.isEmpty ? .neutral : .accent
            )
            .help(
                doc.isTypeInferred
                    ? L("Category inferred from the folder name. Add a `type:` line to the file's frontmatter to override it.")
                    : ""
            )
        }
        .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s8)
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
            let failing = await KnowledgeIndexService.shared.uncategorizedDocuments(collectionId: collectionId)
            await MainActor.run {
                documents = docs
                nonconformingCount = failing.count
                docsLoaded = true
            }
        }
    }
}

#if OSAURUS_DESIGN_INSPECTOR
extension KnowledgeView {
    static func inspectionPopulatedCard(_ indexing: Bool) -> some View {
        var card = KnowledgeCollectionCard(collection: KnowledgeCollection(id: UUID(uuidString: "ABC00000-0000-4000-8000-000000000053")!, name: "Local reference library", summary: "Populated original knowledge card. Local display only; no collection, folder grant or index is created.", folderPath: "/private/tmp/osaurus-inspector-nonexistent-collection"), animationDelay: 0, hasAppeared: true, onToggle: { _ in }, onReindex: {}, isIndexing: indexing, onSync: {}, onEdit: {}, onDelete: {}, onOpenDetail: {})
        card.inspectionDisplayOnly = true
        return card.allowsHitTesting(false)
    }
}
#endif
