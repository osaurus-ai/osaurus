//
//  NotificationService.swift
//  osaurus
//
//  Local notifications for model download completion
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private let categoryId = "OSU_MODEL_READY"
    private let actionOpenId = "OSU_OPEN_MODELS"

    private override init() {
        super.init()
    }

    func configureOnLaunch() {
        center.delegate = self
        // Register category with an action to open the Model Manager window
        let openAction = UNNotificationAction(
            identifier: actionOpenId,
            title: "Open Models",
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
        let content = UNMutableNotificationContent()
        content.title = "Plugin verification failed"
        content.body = "\(name) @ \(version)"

        let request = UNNotificationRequest(
            identifier: "plugin-verify-fail-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    func postModelReady(modelId: String, modelName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Model ready"
        content.body = "\(modelName) is downloaded and ready to use."
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

    func postPluginUpdatesAvailable(count: Int, pluginNames: [String]) {
        guard count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Plugin updates available"
        if count == 1 {
            content.body = "\(pluginNames.first ?? "1 plugin") has an update available."
        } else {
            content.body = "\(count) plugins have updates available."
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
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let info = response.notification.request.content.userInfo
        let modelId = info["modelId"] as? String

        if response.actionIdentifier == actionOpenId
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        {
            Task { @MainActor in
                AppDelegate.shared?.showManagementWindow(
                    initialTab: .models,
                    deeplinkModelId: modelId,
                    deeplinkFile: nil
                )
            }
        }
    }
}
