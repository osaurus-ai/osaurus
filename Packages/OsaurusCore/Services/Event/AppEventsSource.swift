//
//  AppEventsSource.swift
//  osaurus
//
//  The "App event" automation (n8n's Activation / n8n / Workflow
//  triggers): fires when Osaurus finishes starting, when the automation
//  is turned on (or created on), and when it is saved with changes while
//  on. Saves that change nothing but the edit time fire nothing, so a
//  config apply that re-writes an automation as it was is quiet.
//

import Foundation

@MainActor
final class AppEventsSource: EventSourceAdapter {
    let kind: EventSourceKind = .app
    private unowned let manager: EventManager
    private var launched = false

    init(manager: EventManager) {
        self.manager = manager
    }

    /// Once per launch, after events load.
    func start() async {
        guard !launched else { return }
        launched = true
        for event in manager.events where event.isEnabled && event.source.app?.fires(on: .appLaunched) == true {
            fire(event, reason: .appLaunched, trigger: .source)
        }
    }

    func stop() {}
    func reconcile(_ events: [OsaurusEvent]) async {}

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    func eventDidChange(_ event: OsaurusEvent, previous: OsaurusEvent?) {
        guard event.isEnabled, let config = event.source.app else { return }
        guard let previous, previous.isEnabled else {
            if config.fires(on: .automationEnabled) { fire(event, reason: .automationEnabled, trigger: .source) }
            return
        }
        guard config.fires(on: .automationUpdated), Self.isEdit(from: previous, to: event) else { return }
        fire(event, reason: .automationUpdated, trigger: .source)
    }

    /// The person changed something other than run bookkeeping.
    static func isEdit(from previous: OsaurusEvent, to event: OsaurusEvent) -> Bool {
        var before = previous
        before.updatedAt = event.updatedAt
        before.lastFiredAt = event.lastFiredAt
        before.lastRunAt = event.lastRunAt
        before.lastStatus = event.lastStatus
        before.lastSessionId = event.lastSessionId
        before.lastWorkflowRunId = event.lastWorkflowRunId
        return before != event
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        if let sample, sample.value(atPath: "app") != nil {
            return manager.submit(
                EventOccurrence(eventId: event.id, payload: sample, trigger: .manual, loadIntent: .interactive))
        }
        let reason = event.source.app?.reasons.first ?? .appLaunched
        return fire(event, reason: reason, trigger: .manual)
    }

    @discardableResult
    private func fire(_ event: OsaurusEvent, reason: AppEventReason, trigger: EventOccurrence.Trigger) -> EventFireResult {
        let now = Date()
        return manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: now,
                payload: EventPayload.app(event: event, firedAt: now, reason: reason, appVersion: EventPayload.appVersion),
                trigger: trigger, loadIntent: trigger == .manual ? .interactive : .background,
                summary: ["reason": reason.rawValue]))
    }
}
