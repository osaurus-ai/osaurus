//
//  MacAppEventSource.swift
//  osaurus
//
//  The "Mac App" automation: fires when the chosen app opens, quits, or
//  comes to or leaves the front, from `NSWorkspace`'s app notifications
//  (no permission needed; docs/APP_EVENTS.md). One set of observers serves
//  every automation and is registered only while an enabled one needs it.
//  Nothing is caught up: an app opened while Osaurus was closed fires
//  nothing.
//

import AppKit
import Foundation

@MainActor
final class MacAppEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .macApp
    private unowned let manager: EventManager
    private var observers: [NSObjectProtocol] = []
    /// Whether an app is installed here; tests substitute one.
    var appInstalled: (String) -> Bool = { MacAppLocator.isInstalled(bundleID: $0) }
    /// Where app notifications come from; tests post to their own center.
    var center: NotificationCenter = NSWorkspace.shared.notificationCenter

    static let notifications: [(Notification.Name, MacAppEvent)] = [
        (NSWorkspace.didLaunchApplicationNotification, .launched),
        (NSWorkspace.didTerminateApplicationNotification, .quit),
        (NSWorkspace.didActivateApplicationNotification, .activated),
        (NSWorkspace.didDeactivateApplicationNotification, .deactivated),
    ]

    init(manager: EventManager) {
        self.manager = manager
    }

    var isObserving: Bool { !observers.isEmpty }

    func reconcile(_ events: [OsaurusEvent]) async {
        var needed = false
        for event in events {
            guard let config = event.source.macApp else { continue }
            let armed = event.isEnabled && !config.bundleID.isEmpty && !config.events.isEmpty
            needed = needed || armed
            let note: String? =
                armed && !appInstalled(config.bundleID)
                ? L("\(config.displayName) is not installed on this Mac, so this automation waits until it is.")
                : nil
            manager.setSourceStatus(event.id) { $0.note = note }
        }
        if needed { register() } else { unregister() }
    }

    func stop() { unregister() }

    func forget(_ eventId: UUID) {
        manager.setSourceStatus(eventId) { $0.note = nil }
    }

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    private func register() {
        guard observers.isEmpty else { return }
        for (name, what) in Self.notifications {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let bundleID = app?.bundleIdentifier
                    let name = app?.localizedName
                    let pid = app.map { Int($0.processIdentifier) }
                    // An app comes to the front just before it finishes launching.
                    let launching = app.map { !$0.isFinishedLaunching } ?? false
                    // Hop with a Task, not `assumeIsolated` (see FrontmostAppTracker).
                    Task { @MainActor in
                        self?.appDid(what, bundleID: bundleID, name: name, pid: pid, launching: launching)
                    }
                }
            )
        }
    }

    private func unregister() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    /// An app did `what`; fires every enabled automation watching for it.
    /// `launching` marks an app that has not finished launching: an
    /// automation that also watches `launched` waits for that event, so
    /// one opening fires once, as an opening.
    func appDid(_ what: MacAppEvent, bundleID: String?, name: String?, pid: Int?, launching: Bool = false) {
        guard let bundleID else { return }
        let now = Date()
        for event in manager.events where event.isEnabled {
            guard let config = event.source.macApp, config.fires(on: what, bundleID: bundleID) else { continue }
            if what == .activated, launching, config.events.contains(.launched) { continue }
            let payload = EventPayload.macApp(
                event: event,
                firedAt: now,
                what: what,
                name: name ?? config.displayName,
                bundleID: bundleID,
                pid: pid
            )
            manager.submit(
                EventOccurrence(
                    eventId: event.id,
                    firedAt: now,
                    payload: payload,
                    loadIntent: .background,
                    summary: Self.summary(payload)
                )
            )
        }
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        let now = Date()
        let payload =
            sample.flatMap { $0.value(atPath: "mac_app") != nil ? $0 : nil }
            ?? EventTriggerValues.samplePayload(for: event, now: now)
        return manager.submit(
            EventOccurrence(
                eventId: event.id,
                firedAt: now,
                payload: payload,
                trigger: .manual,
                loadIntent: .interactive,
                summary: Self.summary(payload)
            )
        )
    }

    nonisolated static func summary(_ payload: JSONValue) -> [String: String] {
        var summary: [String: String] = [:]
        if let what = payload.value(atPath: "mac_app.event")?.stringValue { summary["mac_app_event"] = what }
        if let id = payload.value(atPath: "mac_app.bundle_id")?.stringValue { summary["bundle_id"] = id }
        return summary
    }
}
