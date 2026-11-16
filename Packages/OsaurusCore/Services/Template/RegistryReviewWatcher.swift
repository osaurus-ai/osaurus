//
//  RegistryReviewWatcher.swift
//  osaurus
//
//  Hears the Osaurus team's review decisions within seconds. While any
//  published listing waits for review and a watch token is stored, one
//  loop long-polls `GET /me/reviews`; each change lands in the record
//  store, and an approval or change request is announced with a toast (in
//  front) or a notification (in the background). Nothing pending, no
//  loop.
//

import AppKit
import Combine
import Foundation

@MainActor
public final class RegistryReviewWatcher: ObservableObject {
    public static let shared = RegistryReviewWatcher(
        api: WorkflowShareService.shared.api, onDecision: PublishReviewDecisionPresenter.present)

    /// True while the long-poll loop runs.
    @Published public private(set) var isWatching = false
    /// When the registry last answered, for "Watching for the decision".
    @Published public private(set) var lastHeardAt: Date?

    /// How long one request may wait on the registry (it caps at 25 s).
    static let waitSeconds = 25

    private let api: WorkflowsRegistryAPIClient
    private let records: WorkflowRegistryRecordStore
    private let tokens: RegistryReviewWatchTokens
    private let onDecision: @MainActor (PublishReviewDecision) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loop: Task<Void, Never>?
    /// Bumped per loop so a cancelled one can't outlive its replacement.
    private var generation = 0
    private var subscriptions: Set<AnyCancellable> = []

    init(
        api: WorkflowsRegistryAPIClient,
        records: WorkflowRegistryRecordStore = .shared,
        tokens: RegistryReviewWatchTokens = .shared,
        onDecision: @escaping @MainActor (PublishReviewDecision) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.records = records
        self.tokens = tokens
        self.onDecision = onDecision
        self.sleep = sleep
    }

    /// Watches from now on: starts the loop whenever a review is pending
    /// and a token is stored, stops it when neither holds.
    public func start() {
        guard subscriptions.isEmpty else { return }
        // `@Published` fires before the value changes; look after it has.
        records.$records.map { _ in () }.merge(with: tokens.changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reconcile() }
            .store(in: &subscriptions)
        reconcile()
    }

    public func stop() {
        subscriptions.removeAll()
        halt()
    }

    func reconcile() {
        let wanted =
            tokens.token(for: api.baseURL) != nil && !records.pendingReviewRecords(registry: api.baseURL).isEmpty
        if wanted, loop == nil {
            generation += 1
            let current = generation
            isWatching = true
            loop = Task { [weak self] in await self?.run(generation: current) }
        } else if !wanted, loop != nil {
            halt()
        }
    }

    private func halt() {
        generation += 1
        loop?.cancel()
        loop = nil
        isWatching = false
    }

    private func run(generation current: Int) async {
        var cursor: String?
        var failures = 0
        while !Task.isCancelled, current == generation {
            guard let token = tokens.token(for: api.baseURL) else { break }
            do {
                let answer = try await api.watchReviews(
                    token: token, since: cursor, wait: cursor == nil ? 0 : Self.waitSeconds)
                guard !Task.isCancelled, current == generation else { return }
                failures = 0
                lastHeardAt = Date()
                cursor = answer.cursor
                if answer.changed { apply(answer.items) }
            } catch WorkflowsRegistryAPIError.watchTokenRejected {
                // Revoked or unknown: the next signed action issues another.
                tokens.remove(for: api.baseURL)
                break
            } catch {
                guard !Task.isCancelled, current == generation else { return }
                failures += 1
                let seconds = min(60, 1 << min(failures, 6))
                do { try await sleep(.seconds(seconds)) } catch { return }
            }
        }
        guard current == generation else { return }
        loop = nil
        isWatching = false
        reconcile()
    }

    /// Folds watched states into the records; a decision that wasn't
    /// there before is announced.
    func apply(_ items: [WorkflowsRegistryWatchedReview]) {
        for item in items {
            guard let before = records.record(for: item.templateID, registry: api.baseURL) else { continue }
            var after = before
            after.apply(item)
            guard after != before else { continue }
            records.set(after)
            if after.hasUnseenDecision, after.review != before.review, let review = after.review {
                onDecision(
                    PublishReviewDecision(
                        templateID: after.templateID, kind: after.kind,
                        name: PublishReviewRouter.displayName(for: after), review: review,
                        listed: after.isListed))
            }
        }
    }
}

/// An approval or a change request, as the toast and notification say it.
public struct PublishReviewDecision: Equatable, Sendable {
    public let templateID: UUID
    public let kind: TemplateKind
    public let name: String
    public let review: WorkflowsRegistryReview
    /// In the store's lists after this decision.
    public let listed: Bool

    public var changesRequested: Bool { review.status == .rejected }

    public var title: String {
        changesRequested ? L("Changes requested: \(name)") : L("Approved: \(name) is in the store")
    }

    public var body: String {
        if let note = review.note { return note }
        if changesRequested {
            return listed
                ? L("Version \(review.version) wasn't approved. The listed version stays up.")
                : L("Version \(review.version) wasn't approved. It stays unlisted until a fixed version is.")
        }
        return L("Version \(review.version) is listed for everyone.")
    }
}

/// Puts a decision in front of the owner: a toast while Osaurus is in
/// front, a notification otherwise.
@MainActor
enum PublishReviewDecisionPresenter {
    static func present(_ decision: PublishReviewDecision) {
        guard NSApp?.isActive == true else {
            NotificationService.shared.postPublishReviewDecision(decision)
            return
        }
        let actionID = "publish.review.\(decision.templateID.uuidString)"
        let revise = decision.changesRequested && decision.kind == .workflow
        ToastManager.shared.unregisterActionHandler(for: actionID)
        ToastManager.shared.registerActionHandler(for: actionID) { _ in
            if revise {
                PublishReviewRouter.revise(templateID: decision.templateID, kind: decision.kind)
            } else {
                PublishReviewRouter.open(templateID: decision.templateID, kind: decision.kind)
            }
        }
        ToastManager.shared.show(
            Toast(
                type: .action, title: decision.title, message: decision.body,
                timeout: decision.changesRequested ? 0 : nil,
                actionTitle: revise ? L("Revise with Architect") : L("Open Listing"),
                action: .custom(id: actionID)))
    }
}

/// Where review decisions lead: the listing's dashboard, or the Architect.
@MainActor
enum PublishReviewRouter {
    /// The listing's dashboard: the Share sheet at Manage.
    static func open(templateID: UUID, kind: TemplateKind) {
        switch kind {
        case .workflow:
            ChatWindowManager.shared.showWorkflowsSurface(tab: .published)
            ManagementStateManager.shared.pendingWorkflowShare = templateID
        case .agent:
            AppDelegate.shared?.showManagementWindow(initialTab: .agents)
            ManagementStateManager.shared.pendingTemplateShare = templateID
        }
    }

    /// The Architect with the reviewer's message, for a workflow; an agent
    /// template opens its dashboard, where the message and its editor are.
    static func revise(templateID: UUID, kind: TemplateKind) {
        guard kind == .workflow,
            let record = WorkflowRegistryRecordStore.shared.record(for: templateID),
            let review = record.review,
            ArchitectLauncher.revise(templateID: templateID, name: displayName(for: record), review: review)
        else {
            open(templateID: templateID, kind: kind)
            return
        }
        WorkflowRegistryRecordStore.shared.markReviewSeen(templateID: templateID)
    }

    /// The name the owner knows the listing by.
    static func displayName(for record: WorkflowRegistryRecord) -> String {
        if let name = record.listingName, !name.isEmpty { return name }
        if record.kind == .workflow, let installed = InstalledWorkflowStore.shared.workflow(templateID: record.templateID) {
            return installed.name
        }
        if let template = TemplateStore.shared.allTemplates(kind: record.kind).first(where: { $0.id == record.templateID }) {
            return template.name
        }
        return record.slug
    }
}
