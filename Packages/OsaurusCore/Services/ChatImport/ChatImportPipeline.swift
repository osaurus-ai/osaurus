//
//  ChatImportPipeline.swift
//  osaurus
//
//  Source → items: fetch, fast paths for the stable formats, the isolated
//  reader for the rest, verification, model grounding, and preflight.
//  Shared by `osaurus_import` (main chat) and `agent_draft` import (New
//  Agent chat).
//

import Foundation

enum ChatImportPipeline {
    struct Prepared: Sendable {
        var bundle: ChatImportBundle
        var review: ChatImportReview
        var reader: ChatImportReader.Outcome?
    }

    static func prepare(
        source: String,
        userText: String?,
        surface: ChatImportSurface,
        targetAgentId: UUID,
        targetAgentName: String? = nil,
        modelName: String? = nil
    ) async -> Prepared {
        let bundle = await ChatImportSourceResolver.resolve(source: source, userText: userText)
        let fast = ChatImportFastPaths.run(bundle)
        var items = fast.items
        var notes: [String] = []
        var readerOutcome: ChatImportReader.Outcome?

        let unread = bundle.documents.filter { !fast.consumedDocumentIds.contains($0.id) }
        if shouldRead(unread, fastItems: fast.items) {
            let outcome = await ChatImportReader.read(documents: unread, modelName: modelName)
            readerOutcome = outcome
            if let manifest = outcome.manifest {
                let verified = ChatImportVerifier.verify(
                    manifest: manifest, bundle: bundle, fastPathItems: items,
                    consumedDocumentIds: fast.consumedDocumentIds)
                items += verified.items
                notes += verified.notes
            } else if items.filter(\.isActionable).isEmpty, let page = ChatImportVerifier.pageAsSkill(bundle) {
                items.append(page)
            }
        }

        notes += ChatImportVerifier.cleanSavedText(&items)
        let catalog = await MainActor.run { ConfigModelReference.liveCatalog() }
        ChatImportVerifier.groundModels(&items, catalog: catalog)
        let environment = await ChatImportPreflight.liveEnvironment(targetAgentId: targetAgentId)
        await MainActor.run { ChatImportPreflight.annotate(&items, environment: environment) }

        let review = ChatImportReview(
            items: items, refusals: bundle.refusals, notes: notes, surface: surface, targetAgentName: targetAgentName)
        return Prepared(bundle: bundle, review: review, reader: readerOutcome)
    }

    /// The reader runs when something is left that the fast paths didn't
    /// understand. Repository docs (README and friends) only matter when
    /// the repo had no standard files.
    static func shouldRead(_ unread: [ChatImportDocument], fastItems: [ChatImportItem]) -> Bool {
        guard !unread.isEmpty else { return false }
        if fastItems.isEmpty { return true }
        return unread.contains { $0.path == nil || $0.path?.hasPrefix("link payload") == true }
    }

    /// Where new MCP servers connect for the post-apply test, and whose
    /// sandbox network setting the preflight reads.
    @MainActor
    static func mainChatTargetAgentId() -> UUID {
        let active = AgentManager.shared.activeAgent.id
        return active == Agent.configuratorId ? Agent.defaultId : active
    }
}
