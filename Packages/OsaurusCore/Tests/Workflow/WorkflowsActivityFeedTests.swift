//
//  WorkflowsActivityFeedTests.swift
//  osaurusTests
//
//  Activity: what the feed merges and leaves out, its filters, pages and
//  day groups, which failures are unresolved, the plain-language failure
//  sentences, Home's Needs attention list, the sidebar's issue count, and
//  the routes that land on it.
//

import Foundation
import Testing

@testable import OsaurusCore

private let utc = AutomationSentence.Style(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

/// Wednesday, Nov 18 2026, 10:00 UTC.
private let wednesday: Date = {
    var components = DateComponents(year: 2026, month: 11, day: 18, hour: 10, minute: 0)
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components)!
}()

private let day: TimeInterval = 86_400

private func run(
    _ status: WorkflowRunStatus, workflowID: UUID, name: String = "Brief", kind: WorkflowCaller.Kind = .user,
    started: Date = wednesday, failure: NodeRunFailure? = nil, eventID: UUID? = nil
) -> WorkflowRun {
    var run = WorkflowRun(
        workflowID: workflowID, workflowName: name, templateID: UUID(), templateVersion: 1,
        caller: WorkflowCaller(kind: kind, eventID: eventID), input: .object([:]), nodeIDs: ["read", "sort"],
        startedAt: started)
    run.status = status
    if status.isTerminal { run.finishedAt = started.addingTimeInterval(42) }
    if status == .failed {
        run.nodes[0].status = .failed
        run.nodes[0].failure = failure
        run.error = WorkflowRunError(nodeID: "read", reason: "The sign-in for \"Mail\" has expired.", failure: failure)
    }
    return run
}

private func fire(_ status: EventRunStatus, eventID: UUID, at date: Date = wednesday, workflowRunID: UUID? = nil) -> EventRun {
    EventRun(
        eventId: eventID, eventName: "Brief schedule", sourceKind: .schedule, actionKind: .workflow, firedAt: date,
        status: status, workflowRunId: workflowRunID, error: status == .failed ? "The workflow is not installed." : nil)
}

private func failure(_ kind: String, tool: String? = nil) -> NodeRunFailure {
    NodeRunFailure(kind: kind, retryable: false, errorType: "Test", fixIn: .setup, tool: tool)
}

struct WorkflowActivityFeedTests {
    @Test func leavesOutTestsNestedStepsAndSkippedFires() {
        let id = UUID()
        let event = UUID()
        let runs = [
            run(.completed, workflowID: id),
            run(.completed, workflowID: id, kind: .test),
            run(.completed, workflowID: id, kind: .workflow),
        ]
        let fires = [
            fire(.failed, eventID: event),
            fire(.failed, eventID: event, workflowRunID: UUID()),
            fire(.filtered, eventID: event),
            fire(.duplicate, eventID: event),
            fire(.suppressed, eventID: event),
        ]
        let items = WorkflowActivityFeed.items(runs: runs, eventRuns: fires, eventWorkflows: [event: id], names: [id: "Brief"])
        #expect(items.count == 2)
        #expect(items.filter { $0.run != nil }.count == 1)
        let refused = items.first { $0.run == nil }
        #expect(refused?.workflowID == id)
        #expect(refused?.isFailed == true)
        #expect(refused?.ranOnItsOwn == true)
    }

    @Test func newestFirstAndFilters() {
        let brief = UUID()
        let triage = UUID()
        let items = WorkflowActivityFeed.items(
            runs: [
                run(.completed, workflowID: brief, started: wednesday - 2 * day),
                run(.failed, workflowID: triage, kind: .event, started: wednesday - day),
                run(.completed, workflowID: brief, kind: .event, started: wednesday),
            ],
            eventRuns: [], eventWorkflows: [:], names: [brief: "Brief", triage: "Triage"])
        #expect(items.map(\.date) == [wednesday, wednesday - day, wednesday - 2 * day])
        let unresolved = WorkflowActivityFeed.unresolved(items)
        #expect(WorkflowActivityFeed.filter(items, by: .ranOnTheirOwn, workflowID: nil, unresolved: unresolved).count == 2)
        #expect(WorkflowActivityFeed.filter(items, by: .runByMe, workflowID: nil, unresolved: unresolved).count == 1)
        #expect(WorkflowActivityFeed.filter(items, by: .needsAttention, workflowID: nil, unresolved: unresolved).count == 1)
        #expect(WorkflowActivityFeed.filter(items, by: nil, workflowID: brief, unresolved: unresolved).count == 2)
    }

    @Test func aLaterFinishedRunResolvesAFailure() {
        let id = UUID()
        let failed = run(.failed, workflowID: id, started: wednesday - day)
        let stopped = run(.cancelled, workflowID: id, started: wednesday - day / 2)
        let before = WorkflowActivityFeed.items(runs: [failed, stopped], eventRuns: [], eventWorkflows: [:], names: [id: "Brief"])
        #expect(WorkflowActivityFeed.unresolved(before) == [WorkflowActivityItem.id(run: failed.id)])
        let fixed = run(.completed, workflowID: id, started: wednesday)
        let after = WorkflowActivityFeed.items(runs: [failed, stopped, fixed], eventRuns: [], eventWorkflows: [:], names: [id: "Brief"])
        #expect(WorkflowActivityFeed.unresolved(after).isEmpty)
    }

    @Test func pagesOfFifty() {
        let id = UUID()
        let runs = (0..<120).map { run(.completed, workflowID: id, started: wednesday - Double($0) * 60) }
        let items = WorkflowActivityFeed.items(runs: runs, eventRuns: [], eventWorkflows: [:], names: [id: "Brief"])
        #expect(WorkflowActivityFeed.page(items, pages: 1).count == 50)
        #expect(WorkflowActivityFeed.page(items, pages: 2).count == 100)
        #expect(WorkflowActivityFeed.page(items, pages: 3).count == 120)
    }

    @Test func groupsByDay() {
        let id = UUID()
        let items = WorkflowActivityFeed.items(
            runs: [
                run(.completed, workflowID: id, started: wednesday),
                run(.completed, workflowID: id, started: wednesday - 60),
                run(.completed, workflowID: id, started: wednesday - day),
                run(.completed, workflowID: id, started: wednesday - 5 * day),
                run(.completed, workflowID: id, started: wednesday - 30 * day),
            ],
            eventRuns: [], eventWorkflows: [:], names: [id: "Brief"])
        let days = WorkflowActivityFeed.days(items, now: wednesday, style: utc)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Friday", "October 19"])
        #expect(days.first?.items.count == 2)
    }

    @Test func linesSayHowItStartedAndWent() {
        let id = UUID()
        let schedule = OsaurusEvent(
            name: "Brief", source: AutomationDefaults.schedule, action: .workflow(WorkflowEventAction(workflowID: id)))
        let automated = WorkflowActivityItem(
            source: .run(run(.completed, workflowID: id, kind: .event, eventID: schedule.id)), workflowID: id, workflowName: "Brief")
        #expect(WorkflowActivityFeed.line(automated, event: schedule) == "Ran on schedule. Took 42 sec.")
        let mine = WorkflowActivityItem(source: .run(run(.failed, workflowID: id)), workflowID: id, workflowName: "Brief")
        #expect(WorkflowActivityFeed.line(mine, event: nil) == "You ran it. Could not finish.")
        let refused = WorkflowActivityItem(source: .refused(fire(.failed, eventID: schedule.id)), workflowID: id, workflowName: "Brief")
        #expect(WorkflowActivityFeed.line(refused, event: schedule) == "Ran on schedule. Could not start.")
    }
}

struct WorkflowFailureSentenceTests {
    @Test func aSignInSaysSoAndOffersSignIn() {
        let failed = run(.failed, workflowID: UUID(), failure: failure("sign_in_needed"))
        let explanation = WorkflowFailureSentence.explain(failed, definition: nil)
        #expect(explanation.sentence == "Osaurus tried to run “read”, but a connected account asked you to sign in again.")
        #expect(explanation.failedStep == "read")
        #expect(explanation.shortReason == "sign-in expired")
        #expect(explanation.remedy == .signInAgain)
        #expect(explanation.remedy?.title == "Sign in again")
    }

    @Test func remediesComeFromTheFailureRemedy() {
        let model = WorkflowFailureSentence.explain(run(.failed, workflowID: UUID(), failure: failure("no_model")), definition: nil)
        #expect(model.remedy == .fix(.chooseModel))
        #expect(model.remedy?.title == "Choose a Model")
        let permission = WorkflowFailureSentence.explain(
            run(.failed, workflowID: UUID(), failure: failure("permission_denied", tool: "calendar")), definition: nil)
        #expect(permission.remedy == .fix(.systemSettings(tool: "calendar")))
        let timedOut = WorkflowFailureSentence.explain(run(.failed, workflowID: UUID(), failure: failure("timed_out")), definition: nil)
        #expect(timedOut.remedy == nil)
        #expect(timedOut.sentence == "“read” ran out of time before it finished.")
    }

    @Test func everyKnownKindHasACalmSentence() {
        let kinds = [
            "sign_in_needed", "provider_auth", "connection_missing", "http_401", "http_403", "permission_denied", "user_denied",
            "folder_denied", "replace_denied", "dialog_dismissed", "form_expired", "no_model", "model_unavailable",
            "missing_key", "timed_out", "network_error", "http_503", "model_busy", "insufficient_funds",
        ]
        for kind in kinds {
            let sentence = WorkflowFailureSentence.sentence(kind: kind, step: "Read mail", remedy: nil, message: "code 42")
            #expect(sentence.contains("Read mail"))
            #expect(!sentence.contains("code 42"))
            #expect(WorkflowFailureSentence.shortReason(kind) != nil)
        }
    }

    @Test func anUnknownKindSaysTheStepDidNotFinishAndWhy() {
        let sentence = WorkflowFailureSentence.sentence(kind: "error", step: "Sort", remedy: nil, message: "The file is locked.\nstack…")
        #expect(sentence == "“Sort” did not finish. The file is locked.")
    }

    @Test func anAutomationThatCouldNotStart() {
        let explanation = WorkflowFailureSentence.explain(refused: fire(.failed, eventID: UUID()), workflowName: "Brief")
        #expect(explanation.sentence == "Osaurus could not start Brief. The workflow is not installed.")
        #expect(explanation.remedy == nil)
    }

    @Test func aConnectionFailureIsClassifiedForSetUp() {
        let failure = WorkflowFailure.classify(WorkflowConnectionResolver.Failure.signInNeeded("Mail"))
        #expect(failure.kind == "sign_in_needed")
        #expect(failure.fixIn == .setup)
    }
}

@MainActor
struct WorkflowAttentionTests {
    private static func workflow(_ name: String) -> InstalledWorkflow {
        InstalledWorkflow(template: WF.template(WF.intake(), name: name), bindings: InstallBindings())
    }

    @Test func listsProblemWorkflowsNewestFirstWithTheirFailure() {
        let brief = Self.workflow("Brief")
        let triage = Self.workflow("Triage")
        let fine = Self.workflow("Fine")
        let briefEvent = OsaurusEvent(name: "B", source: AutomationDefaults.schedule, action: .workflow(WorkflowEventAction(workflowID: brief.id)))
        let triageEvent = OsaurusEvent(name: "T", source: AutomationDefaults.schedule, action: .workflow(WorkflowEventAction(workflowID: triage.id)))
        let failedRun = run(.failed, workflowID: triage.id, failure: failure("sign_in_needed"))
        let fires: [UUID: EventRun] = [
            briefEvent.id: fire(.failed, eventID: briefEvent.id, at: wednesday - day),
            triageEvent.id: fire(.failed, eventID: triageEvent.id, at: wednesday, workflowRunID: failedRun.id),
        ]
        let attention = WorkflowActivityFeed.attention(
            workflows: [brief, triage, fine],
            automations: [
                brief.id: [.init(event: briefEvent, latestSettled: .failed)],
                triage.id: [.init(event: triageEvent, latestSettled: .failed)],
            ],
            latestSettled: { fires[$0] }, run: { $0 == failedRun.id ? failedRun : nil }, targetProblem: { _ in nil })
        #expect(attention.map(\.workflowName) == ["Triage", "Brief"])
        #expect(attention.first?.explanation.remedy == .signInAgain)
        #expect(attention.first?.itemID == WorkflowActivityItem.id(run: failedRun.id))
        #expect(attention.last?.explanation.sentence.hasPrefix("Osaurus could not start Brief.") == true)
        #expect(WorkflowsSidebar.issueCount(
            workflows: [brief, triage, fine],
            automations: [brief.id: [.init(event: briefEvent, latestSettled: .failed)], triage.id: [.init(event: triageEvent, latestSettled: .failed)]]) == 2)
    }

    @Test func aLaterFinishedRunResolvesAnAutomationFailure() {
        let failed = fire(.failed, eventID: UUID(), at: wednesday)
        #expect(!WorkflowsOverviewModel.isResolved(failed, lastFinishedRun: nil))
        #expect(!WorkflowsOverviewModel.isResolved(failed, lastFinishedRun: wednesday - 60))
        #expect(WorkflowsOverviewModel.isResolved(failed, lastFinishedRun: wednesday + 60))
    }
}

@MainActor
struct WorkflowActivityRoutingTests {
    @Test func activityLinksLand() {
        #expect(ChatWindowState.WorkflowsDestination(subTab: "workflows.activity") == .activity)
        #expect(ChatWindowState.WorkflowsDestination(url: URL(string: "osaurus://workflows/activity")!) == .activity)
        #expect(ChatWindowState.WorkflowsDestination(subTab: "workflows.activity.extra") == nil)
        #expect(ChatWindowState.workflowsSidebarSelection([.activity]) == .activity)
        #expect(ChatWindowState.workflowsSidebarSelection([.activity, .run(workflowID: UUID(), runID: nil, agentId: UUID())]) != .activity)
    }
}

/// SwiftPM copies the string catalog without compiling it, so these read
/// the source catalog rather than `L(...)`.
struct WorkflowCountWordsTests {
    private static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Localizable.xcstrings")

    private static func englishPlural(_ key: String) throws -> [String: String] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any], "missing \(key)")
        let en = try #require((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])
        let plural = try #require((en["variations"] as? [String: Any])?["plural"] as? [String: Any])
        return plural.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    @Test func countsHaveASingular() throws {
        let expected: [String: String] = [
            "%lld issues": "%lld issue",
            "%lld needs your attention.": "%lld needs your attention.",
            "%lld workflows run on their own.": "%lld workflow runs on its own.",
            "%lld other automations run agents.": "%lld other automation runs an agent.",
            "On for %lld workflows": "On for %lld workflow",
            "runs every %lld minutes": "runs every minute",
        ]
        for (key, one) in expected {
            let forms = try Self.englishPlural(key)
            #expect(forms["one"] == one)
            #expect(forms["other"] != nil)
        }
        #expect(try Self.englishPlural("%lld needs your attention.")["other"] == "%lld need your attention.")
    }
}
