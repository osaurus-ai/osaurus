//
//  NotificationService.swift
//  osaurus
//
//  Local notifications for model download completion
//

import AppKit
import Foundation
import UserNotifications

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
    center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
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

  // MARK: - UNUserNotificationCenterDelegate

  func userNotificationCenter(
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
      DispatchQueue.main.async {
        AppDelegate.shared?.showModelManagerWindow(deeplinkModelId: modelId, file: nil)
      }
    }
  }
}
