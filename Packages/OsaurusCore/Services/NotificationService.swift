//
//  NotificationService.swift
//  osaurus
//
//  Local notifications for model downloads and plugin updates
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// `UNUserNotificationCenter.current()` raises an Objective-C
    /// exception in processes without an app bundle (the `osaurus-evals`
    /// CLI, `swift test`, and the `xcodebuild test` xctest host, which has
    /// a bundle identifier but no app bundle). Resolve it lazily behind a
    /// headless guard so merely touching `NotificationService.shared` —
    /// e.g. via the agent-DB storage-quota warning during a headless eval
    /// run — can't crash; every post method no-ops when `center` is nil.
    private lazy var center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil && !RuntimeEnvironment.isUnderTests ? .current() : nil

    private let categoryId = "OSU_MODEL_READY"
    private let actionOpenId = "OSU_OPEN_MODELS"
    private let reviewChangesCategoryId = "OSU_PUBLISH_CHANGES_REQUESTED"
    private let reviewApprovedCategoryId = "OSU_PUBLISH_APPROVED"
    private let actionReviseId = "OSU_PUBLISH_REVISE"
    private let actionOpenListingId = "OSU_PUBLISH_OPEN"

    private override init() {
        super.init()
    }

    func configureOnLaunch() {
        guard let center else { return }
        center.delegate = self
        // Register category with an action to open the Model Manager window
        let openAction = UNNotificationAction(
            identifier: actionOpenId,
            title: L("Open Models"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let revise = UNNotificationAction(
            identifier: actionReviseId, title: L("Revise with Architect"), options: [.foreground])
        let openListing = UNNotificationAction(
            identifier: actionOpenListingId, title: L("Open Listing"), options: [.foreground])
        center.setNotificationCategories(
            Set(
                [
                    category,
                    UNNotificationCategory(
                        identifier: reviewChangesCategoryId, actions: [revise, openListing], intentIdentifiers: [],
                        options: []),
                    UNNotificationCategory(
                        identifier: reviewApprovedCategoryId, actions: [openListing], intentIdentifiers: [],
                        options: []),
                ] + DesktopNotificationChannel.categories()
            )
        )

        // Request authorization (best-effort; user may have already granted/denied)
        authorization = Task.detached {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
                ?? false
        }
    }

    /// The launch-time authorization request. Attention posts wait on it so
    /// the first request after launch isn't dropped before the user answers.
    private var authorization: Task<Bool, Never>?

    /// Submit a prepared request (`DesktopNotificationChannel`).
    /// `isCurrent` is checked after authorization settles, so an item
    /// answered in the meantime isn't posted late.
    func add(_ request: UNNotificationRequest, isCurrent: @escaping @MainActor () -> Bool = { true }) {
        guard let center else { return }
        let identifier = request.identifier
        let authorization = authorization
        Task {
            if let authorization, await !authorization.value {
                AttentionLog.info("desktop notification skipped id=\(identifier) reason=not_authorized")
                return
            }
            guard isCurrent() else { return }
            do {
                try await center.add(request)
            } catch {
                AttentionLog.error("desktop notification failed id=\(identifier) error=\(error.localizedDescription)")
            }
        }
    }

    func removeDelivered(identifiers: [String]) {
        center?.removeDeliveredNotifications(withIdentifiers: identifiers)
        center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func postPluginVerificationFailed(name: String, version: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Plugin verification failed")
        content.body = "\(name) @ \(version)"

        let request = UNNotificationRequest(
            identifier: "plugin-verify-fail-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    func postModelReady(modelId: String, modelName: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Model ready")
        content.body = L("\(modelName) is downloaded and ready to use.")
        content.userInfo = ["modelId": modelId]
        content.categoryIdentifier = categoryId

        // Deliver shortly after scheduling
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "model-ready-\(modelId)",
            content: content,
            trigger: trigger
        )
        center.add(request, withCompletionHandler: nil)
    }

    func postSafeModeActive() {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Osaurus started in safe mode")
        content.body = L("Plugins disabled after repeated crashes. Run \"osaurus tools reset\" in Terminal to recover.")
        let request = UNNotificationRequest(identifier: "safe-mode", content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// Post a notification on behalf of an agent (Phase 3 `notify` tool).
    /// Body and title are agent-supplied free text; we prefix the title
    /// with the agent's display name so the user can disambiguate when
    /// multiple agents are notifying concurrently. `viewRef` rides in
    /// `userInfo` so the click handler can deep-link to the Views tab —
    /// the deep-link wiring lands with the NextRunPanelView in this phase.
    nonisolated func postAgentEvent(
        agentId: UUID,
        agentName: String,
        title: String,
        body: String,
        viewRef: String?
    ) {
        // `nonisolated` so any thread (bridge serial queue) can call this
        // without a queue hop on the hot path; routing hops to MainActor.
        // Goes through `AttentionCenter` so the user's notification routing
        // (desktop / phone / push) and the Insights record apply.
        Task { @MainActor in
            let address = AgentManager.shared.agent(for: agentId)?.agentAddress
            AttentionCenter.shared.raise(
                AttentionItem(
                    kind: .agentNotice,
                    agent: .agent(name: agentName, address: address),
                    agentId: agentId,
                    title: "\(agentName) · \(title)",
                    body: body,
                    hasInlineCard: false,
                    link: .agentDetail(agentId: agentId, viewRef: (viewRef?.isEmpty == false) ? viewRef : nil)
                )
            )
        }
    }

    func postPluginUpdatesAvailable(count: Int, pluginNames: [String]) {
        guard count > 0, let center else { return }

        let content = UNMutableNotificationContent()
        content.title = L("Plugin updates available")
        if count == 1 {
            content.body = L("\(pluginNames.first ?? "1 plugin") has an update available.")
        } else {
            content.body = L("\(count) plugins have updates available.")
        }
        content.userInfo = ["pluginCount": count]

        let request = UNNotificationRequest(
            identifier: "plugin-updates-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - Workflows

    /// A background run parked on a form. Tapping opens the run's tab,
    /// where the form can be answered.
    func postWorkflowNeedsInput(_ dialog: PendingDialog) {
        AttentionCenter.shared.raise(
            AttentionItem(
                id: dialog.id,
                kind: .workflowDialog,
                title: L("\(dialog.workflowName) needs your input"),
                body: dialog.title,
                hasInlineCard: false,
                link: .workflowRun(dialog.runID)
            )
        ) { resolution in
            // A dismiss from the phone or notification ends the form the
            // same way the form's own Dismiss does, instead of leaving the
            // run parked.
            switch resolution.outcome {
            case .dismissed, .denied:
                DialogCoordinator.shared.dismiss(dialog.id)
            case .approved, .allowedForConversation, .replied, .timedOut, .abandoned:
                break
            }
        }
    }

    func removeWorkflowNeedsInput(dialogID: UUID) {
        AttentionCenter.shared.retract(id: dialogID)
    }

    /// Self-heal dispatched the Architect for a repeating failure. Tapping
    /// opens the background chat where the fix is being drafted.
    func postWorkflowSelfHeal(workflowName: String, repeats: Int, backgroundTaskID: UUID) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("\(workflowName) keeps failing")
        content.body = L("The same step failed \(repeats) runs in a row. The Architect is drafting a fix for you to review.")
        content.userInfo = ["backgroundTaskId": backgroundTaskID.uuidString]
        let request = UNNotificationRequest(
            identifier: "workflow-self-heal-\(backgroundTaskID.uuidString)", content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - Publishing review

    /// The Osaurus team approved or asked for changes on a submission.
    /// Changes requested offers Revise with Architect beside Open Listing.
    func postPublishReviewDecision(_ decision: PublishReviewDecision) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = decision.title
        content.body = decision.body
        content.userInfo = [
            "publishedTemplateId": decision.templateID.uuidString,
            "publishedKind": decision.kind.rawValue,
        ]
        content.categoryIdentifier = decision.changesRequested ? reviewChangesCategoryId : reviewApprovedCategoryId
        let request = UNNotificationRequest(
            identifier: "publish-review-\(decision.templateID.uuidString)", content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let info = response.notification.request.content.userInfo

        if DesktopNotificationChannel.handle(
            actionIdentifier: response.actionIdentifier == UNNotificationDefaultActionIdentifier
                ? "" : response.actionIdentifier,
            userInfo: info,
            replyText: (response as? UNTextInputNotificationResponse)?.userText
        ) {
            return
        }

        if let raw = info["publishedTemplateId"] as? String, let templateID = UUID(uuidString: raw) {
            let kind = (info["publishedKind"] as? String).flatMap(TemplateKind.init(rawValue:)) ?? .workflow
            let revise = response.actionIdentifier == actionReviseId
            Task { @MainActor in
                if revise {
                    PublishReviewRouter.revise(templateID: templateID, kind: kind)
                } else {
                    PublishReviewRouter.open(templateID: templateID, kind: kind)
                }
            }
            return
        }

        guard
            response.actionIdentifier == actionOpenId
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else {
            return
        }

        // Agent-originated notification: route to the agent's detail view
        // with the referenced saved view focused (spec §3.3 — viewRef
        // deep-link). `postAgentEvent` tags `source: "agent"` on
        // userInfo; that's our routing key so we don't have to guess
        // from the agentId alone.
        if (info["source"] as? String) == "agent",
            let agentIdString = info["agentId"] as? String,
            let agentId = UUID(uuidString: agentIdString)
        {
            let viewRef = info["viewRef"] as? String
            Task { @MainActor in
                // Routes through `showAgentDetail`, which opens the Agents tab
                // and defers the `.agentDetailDeeplink` post until the
                // management hierarchy has mounted (so the listening views have
                // attached their `.onReceive`, even on cold-launch).
                AppDelegate.shared?.showAgentDetail(
                    agentId: agentId,
                    tab: "views",
                    viewRef: viewRef
                )
            }
            return
        }

        if let raw = info["workflowRunId"] as? String, let runID = UUID(uuidString: raw) {
            Task { @MainActor in WorkflowRunLauncher.open(runID: runID) }
            return
        }

        if let raw = info["backgroundTaskId"] as? String, let taskID = UUID(uuidString: raw) {
            Task { @MainActor in BackgroundTaskManager.shared.openTaskWindowIfPresent(taskID) }
            return
        }

        if let raw = info["workflowId"] as? String, let workflowID = UUID(uuidString: raw) {
            Task { @MainActor in WorkflowRunLauncher.openTab(workflowID: workflowID) }
            return
        }

        let isPluginNotification = info["pluginCount"] != nil
        let modelId = info["modelId"] as? String

        Task { @MainActor in
            // The standalone Plugins section was retired; native plugins now
            // live under Tools → Native Plugins, so route plugin notifications
            // there.
            if isPluginNotification {
                ManagementStateManager.shared.pendingToolsSubTab = ToolsTab.nativePlugins.rawValue
            }
            // Model links ride shared state (see `pendingModelDeepLink`)
            // instead of the hosting-controller rebuild that
            // `showManagementWindow(deeplinkModelId:)` performs on a live
            // window, which orphans an open SwiftUI sheet.
            AppDelegate.shared?.showManagementWindow(initialTab: isPluginNotification ? .tools : .models)
            if let modelId, !isPluginNotification {
                ManagementStateManager.shared.pendingModelDeepLink = .init(modelId: modelId, file: nil)
            }
        }
    }
}
