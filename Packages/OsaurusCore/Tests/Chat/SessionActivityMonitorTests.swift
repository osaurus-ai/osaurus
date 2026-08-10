//
//  SessionActivityMonitorTests.swift
//  osaurusTests
//
//  Pins down the History sidebar's live-activity contract:
//  `SessionActivityOrdering` floats active rows above pinned rows above the
//  rest while preserving recency within each tier, and
//  `SessionActivityMonitor` merges per-session reports (streaming / awaiting
//  input) with the registry-level queued flag into one published map.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct SessionActivityMonitorTests {

    private func session(_ title: String, pinned: Bool = false) -> ChatSessionData {
        ChatSessionData(title: title, pinned: pinned)
    }

    // MARK: - Ordering

    @Test
    func ordering_floatsActiveAbovePinnedAboveRest() {
        let active = session("active")
        let pinned = session("pinned", pinned: true)
        let recent = session("recent")
        let older = session("older")
        // Incoming order is recency-descending, as produced by the store.
        let list = [recent, pinned, older, active]

        let ordered = SessionActivityOrdering.ordered(list, activeIds: [active.id])

        #expect(ordered.map(\.title) == ["active", "pinned", "recent", "older"])
    }

    @Test
    func ordering_preservesRecencyWithinEachTier() {
        let activeNewer = session("activeNewer")
        let activeOlder = session("activeOlder")
        let pinnedNewer = session("pinnedNewer", pinned: true)
        let pinnedOlder = session("pinnedOlder", pinned: true)
        let rest = session("rest")
        let list = [activeNewer, pinnedNewer, rest, activeOlder, pinnedOlder]

        let ordered = SessionActivityOrdering.ordered(
            list, activeIds: [activeNewer.id, activeOlder.id]
        )

        #expect(
            ordered.map(\.title) == [
                "activeNewer", "activeOlder", "pinnedNewer", "pinnedOlder", "rest",
            ]
        )
    }

    @Test
    func ordering_activePinnedRowCountsAsActiveNotDuplicated() {
        let activePinned = session("activePinned", pinned: true)
        let rest = session("rest")
        let list = [rest, activePinned]

        let ordered = SessionActivityOrdering.ordered(list, activeIds: [activePinned.id])

        #expect(ordered.map(\.title) == ["activePinned", "rest"])
        #expect(ordered.count == 2)
    }

    @Test
    func ordering_noActiveNoPinnedIsIdentity() {
        let list = [session("a"), session("b"), session("c")]

        let ordered = SessionActivityOrdering.ordered(list, activeIds: [])

        #expect(ordered.map(\.title) == ["a", "b", "c"])
    }

    // MARK: - Monitor merge

    @Test
    func monitor_sessionReportSetsAndClearsStatus() {
        let monitor = SessionActivityMonitor()
        let id = UUID()

        monitor.reportSession(id, status: .working)
        #expect(monitor.status(for: id) == .working)

        monitor.reportSession(id, status: .waitingForInput)
        #expect(monitor.status(for: id) == .waitingForInput)

        monitor.reportSession(id, status: nil)
        #expect(monitor.status(for: id) == nil)
        #expect(monitor.statuses.isEmpty)
    }

    @Test
    func monitor_queuedShowsAsWorkingUntilSessionReports() {
        let monitor = SessionActivityMonitor()
        let id = UUID()

        // A queued registry task's session isn't streaming yet — the queued
        // flag alone must surface the row as working.
        monitor.reportQueued(id, isQueued: true)
        #expect(monitor.status(for: id) == .working)

        // Once promoted, the session's own report takes over…
        monitor.reportQueued(id, isQueued: false)
        monitor.reportSession(id, status: .working)
        #expect(monitor.status(for: id) == .working)

        // …and clearing it empties the map.
        monitor.reportSession(id, status: nil)
        #expect(monitor.statuses.isEmpty)
    }

    @Test
    func monitor_sessionReportOutranksQueuedFlag() {
        let monitor = SessionActivityMonitor()
        let id = UUID()

        monitor.reportQueued(id, isQueued: true)
        monitor.reportSession(id, status: .waitingForInput)
        #expect(monitor.status(for: id) == .waitingForInput)

        // Dropping the session report falls back to the queued contribution
        // instead of clearing the row.
        monitor.reportSession(id, status: nil)
        #expect(monitor.status(for: id) == .working)

        monitor.reportQueued(id, isQueued: false)
        #expect(monitor.statuses.isEmpty)
    }
}
