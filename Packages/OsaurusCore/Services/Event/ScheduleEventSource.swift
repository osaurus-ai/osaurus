//
//  ScheduleEventSource.swift
//  osaurus
//
//  Calendar source: one timer armed for the soonest due schedule event,
//  plus a launch pass for slots missed while the app was closed. A slot is
//  consumed when it comes due, whether or not the event was free to run,
//  so a busy event skips that slot instead of re-firing in a loop.
//

import Foundation

@MainActor
final class ScheduleEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .schedule
    private unowned let manager: EventManager
    private var timerTask: Task<Void, Never>?
    private var timezoneObserver: NSObjectProtocol?
    private var stopped = false

    init(manager: EventManager) {
        self.manager = manager
        timezoneObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconcile(self.manager.events)
            }
        }
    }

    /// Launch: fire (or skip) the slots missed while the app was closed.
    func start() async {
        fireMissed()
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        let now = Date()
        return manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: now,
                payload: EventPayload.schedule(event: event, firedAt: now, scheduledFor: nil),
                trigger: .manual, loadIntent: .interactive))
    }

    func status(_ eventId: UUID) -> EventSourceStatus {
        var status = manager.sourceStatus[eventId] ?? EventSourceStatus()
        status.nextTickAt = manager.event(for: eventId)?.nextFireDate()
        return status
    }

    func stop() {
        stopped = true
        timerTask?.cancel()
        timerTask = nil
        if let timezoneObserver {
            NotificationCenter.default.removeObserver(timezoneObserver)
            self.timezoneObserver = nil
        }
    }

    /// Re-arms the timer for the soonest next slot.
    func reconcile(_ events: [OsaurusEvent]) {
        timerTask?.cancel()
        timerTask = nil
        guard !stopped, manager.isStarted else { return }
        let now = Date()
        let soonest = events.compactMap { event -> Date? in
            guard event.isEnabled, event.sourceKind == .schedule else { return nil }
            return event.nextFireDate(asOf: now)
        }.min()
        guard let soonest else { return }
        let delay = max(0, soonest.timeIntervalSince(now))
        timerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        let now = Date()
        for event in manager.events where event.sourceKind == .schedule && event.isEnabled {
            guard let timing = event.scheduleTiming, timing.shouldRunNow(asOf: now) else { continue }
            fire(event, slot: timing.scheduledFireTime(asOf: now), now: now)
        }
        reconcile(manager.events)
    }

    /// Fires (or, per the event's policy, skips) the latest slot each event
    /// missed while the app was closed.
    func fireMissed() {
        let now = Date()
        for event in manager.events where event.sourceKind == .schedule && event.isEnabled {
            guard let timing = event.scheduleTiming else { continue }
            let slot: Date?
            if case .once(let date) = timing.frequency {
                slot = (date <= now && timing.executionAnchor == nil) ? date : nil
            } else if timing.executionAnchor != nil {
                slot = timing.latestDueSlot(asOf: now)
            } else {
                slot = nil
            }
            guard let slot else { continue }
            switch event.delivery.missedFirePolicy {
            case .skip where !SelfScheduleAutomations.isWithinMissGrace(event, slot: slot, now: now):
                manager.updateState(event.id) { $0.lastFiredAt = slot }
                manager.record(
                    EventRun(
                        eventId: event.id, eventName: event.name, sourceKind: .schedule,
                        actionKind: event.action.kind, firedAt: now, status: .suppressed, reason: "missed_skipped",
                        dedupeKey: EventPayload.iso8601(slot), finishedAt: now))
            case .runCatchup:
                for missed in Self.missedSlots(timing, through: slot) {
                    fire(event, slot: missed, now: now)
                }
            default:
                fire(event, slot: slot, now: now)
            }
        }
        reconcile(manager.events)
    }

    /// Every slot after the consumed anchor up to `latest`, oldest first,
    /// capped at the newest `catchUpLimit`.
    static func missedSlots(_ timing: ScheduleTiming, through latest: Date) -> [Date] {
        if case .once = timing.frequency { return [latest] }
        guard let anchor = timing.consumedExecutionAnchor else { return [latest] }
        var slots: [Date] = []
        var cursor = anchor
        for _ in 0..<100_000 {
            guard let next = timing.frequency.nextRunDate(after: cursor), next <= latest else { break }
            slots.append(next)
            if slots.count > EventMissedFirePolicy.catchUpLimit { slots.removeFirst() }
            cursor = next
        }
        return slots.isEmpty ? [latest] : slots
    }

    private func fire(_ event: OsaurusEvent, slot: Date?, now: Date) {
        let slot = slot ?? now
        // A paused agent's self-scheduled wake waits for the pause to end
        // instead of being consumed.
        if let resumeAt = SelfScheduleAutomations.pausedUntil(event, now: now) {
            SelfScheduleAutomations.deferSlot(event, to: resumeAt, manager: manager)
            return
        }
        defer {
            // After submit: admission refuses a disabled event, and a
            // one-shot turns itself off once its slot is consumed.
            manager.updateState(event.id) { updated in
                updated.lastFiredAt = slot
                if case .once = event.source.schedule?.frequency { updated.isEnabled = false }
            }
        }
        manager.submit(
            EventOccurrence(
                eventId: event.id,
                firedAt: now,
                payload: EventPayload.schedule(event: event, firedAt: now, scheduledFor: slot),
                dedupeKey: EventPayload.iso8601(slot),
                // Nobody is waiting on a timer fire: it must not evict the
                // model the user is chatting with.
                loadIntent: .background,
                summary: ["scheduled_for": EventPayload.iso8601(slot)]
            ))
    }
}
