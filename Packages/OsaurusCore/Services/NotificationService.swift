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
    /// CLI, `swift test`). Resolve it lazily behind a headless guard so
    /// merely touching `NotificationService.shared` — e.g. via the
    /// agent-DB storage-quota warning during a headless eval run —
    /// can't crash; every post method no-ops when `center` is nil.
    private lazy var center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? .current() : nil

    private let categoryId = "OSU_MODEL_READY"
    private let actionOpenId = "OSU_OPEN_MODELS"

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
        center.setNotificationCategories([category])

        // Request authorization (best-effort; user may have already granted/denied)
        Task.detached {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
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
        // without a queue hop on the hot path; the actual UNNotification
        // submission still hops to MainActor via Task.
        Task { @MainActor in
            guard let center = self.center else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(agentName) · \(title)"
            content.body = body
            var info: [String: Any] = [
                "agentId": agentId.uuidString,
                "source": "agent",
            ]
            if let viewRef, !viewRef.isEmpty { info["viewRef"] = viewRef }
            content.userInfo = info

            let request = UNNotificationRequest(
                identifier: "agent-\(agentId.uuidString)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
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

        let isPluginNotification = info["pluginCount"] != nil
        let modelId = info["modelId"] as? String

        Task { @MainActor in
            AppDelegate.shared?.showManagementWindow(
                initialTab: isPluginNotification ? .plugins : .models,
                deeplinkModelId: modelId,
                deeplinkFile: nil
            )
        }
    }
}
