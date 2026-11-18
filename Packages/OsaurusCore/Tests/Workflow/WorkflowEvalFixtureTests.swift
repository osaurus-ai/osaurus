//
//  WorkflowEvalFixtureTests.swift
//  OsaurusCoreTests
//
//  The fixture side of `WorkflowEvalHarness`: date tokens on this Mac's
//  calendar, their offsets, and fixture results that stay "today" on every
//  run.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workflow eval fixtures")
struct WorkflowEvalFixtureTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()
    /// Wednesday, Nov 4 2026, 10:30 in Los Angeles.
    static let now = ISO8601DateFormatter().date(from: "2026-11-04T18:30:00Z")!

    func token(_ name: String) -> String? {
        WorkflowEvalHarness.dateToken(name, now: Self.now, calendar: Self.calendar)
            .map { ISO8601DateFormatter().string(from: $0) }
    }

    @Test
    func dateTokens_followThisMacsCalendar() {
        #expect(token("today_start") == "2026-11-04T08:00:00Z")
        #expect(token("today_end") == "2026-11-05T07:59:59Z")
        #expect(token("yesterday_start") == "2026-11-03T08:00:00Z")
        #expect(token("tomorrow_end") == "2026-11-06T07:59:59Z")
        #expect(token("week_end") == "2026-11-09T07:59:59Z", "the coming Sunday")
        #expect(token("days_ago:3") == "2026-11-01T18:30:00Z")
        #expect(token("bogus") == nil)
    }

    @Test
    func dateTokens_takeAnOffset() {
        #expect(token("today_start+960m") == "2026-11-05T00:00:00Z")
        #expect(token("tomorrow_start+15h") == "2026-11-05T23:00:00Z")
        #expect(token("today_start-2d") == "2026-11-02T08:00:00Z")
        #expect(token("now+2h") == "2026-11-04T20:30:00Z")
        #expect(token("days_ago:-7") == "2026-11-11T18:30:00Z", "a negative day count is not an offset")
        #expect(token("bogus+2h") == nil)
    }

    @Test
    func fixtureResults_resolveTheirDateTokens() {
        let fixture: JSONValue = .object([
            "events": .array([
                .object(["title": .string("Standup"), "start": .string("{{date:today_start+960m}}")])
            ]),
            "count": .number(1),
            "note": .string("not {{date:today_start}} a token"),
        ])
        let resolved = WorkflowEvalHarness.resolvingDateTokens(fixture, now: Self.now, calendar: Self.calendar)
        #expect(
            resolved.value(atPath: "events.0.start")?.stringValue == "2026-11-04T16:00:00-08:00",
            "local time, as the Apple tools write it, so 4 pm today does not read as tomorrow in UTC")
        #expect(resolved.value(atPath: "events.0.title")?.stringValue == "Standup")
        #expect(resolved.value(atPath: "count") == .number(1))
        #expect(resolved.value(atPath: "note")?.stringValue == "not {{date:today_start}} a token")
    }

    @Test
    func argumentMatches_allowsAMinuteOfDrift() {
        let match = { (got: String, want: String) in
            WorkflowEvalHarness.argumentMatches(.string(got), .string(want), now: Self.now, calendar: Self.calendar)
        }
        #expect(match("2026-11-04T08:00:30.000Z", "{{date:today_start}}"))
        #expect(!match("2026-11-04T08:02:00.000Z", "{{date:today_start}}"))
        #expect(!match("not a date", "{{date:today_start}}"))
        #expect(WorkflowEvalHarness.argumentMatches(.number(40), .number(40), now: Self.now, calendar: Self.calendar))
    }
}

@Suite("Worker summaries")
struct WorkerSummaryTests {
    @Test
    func filesWorker_namesItsLane_onlyBesideKeeper() {
        let keeper = Agent(name: "Keeper", description: "Files in Downloads and the Notes app.", systemPrompt: "")
        var withKeeper = keeper
        withKeeper.sourceTemplateID = Teammate.keeper.templateID
        var config = SubagentConfiguration()
        config.spawnableAgentIDs = [withKeeper.id]
        let besideKeeper = AgentWrapperCatalog.wrappers(agents: [withKeeper], config: config)
        let alone = AgentWrapperCatalog.wrappers(agents: [], config: SubagentConfiguration())
        let lane = "not for reading Downloads or Notes"
        #expect(besideKeeper.first { $0.name == "Files" }?.summary.contains(lane) == true)
        #expect(alone.first { $0.name == "Files" }?.summary.contains(lane) == false)
    }
}
