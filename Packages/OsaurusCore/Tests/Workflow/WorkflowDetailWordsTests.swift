//
//  WorkflowDetailWordsTests.swift
//  osaurusTests
//
//  A workflow's page in words: the editable parts of a schedule sentence,
//  when it runs next, what a new automation starts as, the one-click
//  presets and the catalog of ways to run, the health strip, how each run
//  is described, and the line under the workflow's name.
//

import Foundation
import Testing

@testable import OsaurusCore

private let us = AutomationSentence.Style(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
private let gb = AutomationSentence.Style(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)

private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

/// Wednesday, Nov 18 2026, 10:00 UTC.
private let wednesday: Date = {
    var components = DateComponents(year: 2026, month: 11, day: 18, hour: 10, minute: 0)
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components)!
}()

private func event(_ source: EventSource, workflowID: UUID = UUID(), enabled: Bool = true) -> OsaurusEvent {
    OsaurusEvent(
        name: "Test", isEnabled: enabled, source: source,
        action: .workflow(WorkflowEventAction(workflowID: workflowID)))
}

private func run(
    _ status: WorkflowRunStatus, caller: WorkflowCaller = WorkflowCaller(kind: .user),
    started: Date = wednesday, seconds: TimeInterval = 42
) -> WorkflowRun {
    var run = WorkflowRun(
        workflowID: UUID(), workflowName: "Brief", templateID: UUID(), templateVersion: 1,
        caller: caller, input: .object([:]), nodeIDs: ["a"], startedAt: started)
    run.status = status
    if status.isTerminal { run.finishedAt = started.addingTimeInterval(seconds) }
    return run
}

private let requiredRecipient: JSONValue = .object([
    "type": .string("object"),
    "properties": .object(["recipient": .object(["type": .string("string")])]),
    "required": .array([.string("recipient")]),
])

private let defaultedRecipient: JSONValue = .object([
    "type": .string("object"),
    "properties": .object(["recipient": .object(["type": .string("string"), "default": .string("me")])]),
    "required": .array([.string("recipient")]),
])

struct AutomationSentencePartsTests {
    @Test func scheduleWordsRoundTrip() {
        let shapes: [(ScheduleFrequency, AutomationSentence.DayChoice)] = [
            (.daily(hour: 8, minute: 30), .everyDay),
            (ScheduleCronShape.weekdays(hour: 9, minute: 0).frequency, .weekdays),
            (.weekly(dayOfWeek: 2, hour: 7, minute: 15), .weekday(2)),
            (.monthly(dayOfMonth: 1, hour: 6, minute: 0), .firstOfMonth),
        ]
        for (frequency, day) in shapes {
            let parts = AutomationSentence.scheduleParts(frequency)
            #expect(parts.day == day)
            #expect(AutomationSentence.frequency(parts) == frequency)
        }
        #expect(AutomationSentence.scheduleParts(.hourly(minute: 0)).day == .everyHour)
        #expect(AutomationSentence.scheduleParts(.everyNMinutes(minutes: 30)).day == .every30Minutes)
    }

    @Test func schedulesTheMenuCantSayAreCustom() {
        for frequency: ScheduleFrequency in [
            .monthly(dayOfMonth: 15, hour: 9, minute: 0), .everyNMinutes(minutes: 5),
            .cron(expression: "0 9 * * 1,3"), .yearly(month: 1, day: 1, hour: 0, minute: 0),
        ] {
            let parts = AutomationSentence.scheduleParts(frequency)
            #expect(parts.day == .custom)
            #expect(AutomationSentence.frequency(parts) == nil)
        }
    }

    @Test func changingTheDayKeepsTheTime() {
        var parts = AutomationSentence.scheduleParts(.daily(hour: 18, minute: 45))
        parts.day = .weekday(6)
        #expect(AutomationSentence.frequency(parts) == .weekly(dayOfWeek: 6, hour: 18, minute: 45))
    }

    @Test func dayMenuFollowsTheLocalesFirstWeekday() {
        let menu = AutomationSentence.dayMenu(style: us)
        #expect(menu.prefix(3) == [.everyDay, .weekdays, .weekday(1)])
        #expect(AutomationSentence.dayMenu(style: gb)[2] == .weekday(2))
        #expect(menu.suffix(3) == [.everyHour, .every30Minutes, .firstOfMonth])
    }

    @Test func dayLabels() {
        #expect(AutomationSentence.dayLabel(.weekdays, style: us) == "Every weekday")
        #expect(AutomationSentence.dayLabel(.weekday(2), style: us) == "Every Monday")
        #expect(AutomationSentence.dayLabel(.firstOfMonth, style: us) == "On the 1st of the month")
    }

    @Test func partsByKind() {
        #expect(AutomationSentence.parts(event(.folder(FolderSourceConfig(path: "/Users/me/Downloads")))) == .folder("Downloads"))
        #expect(AutomationSentence.parts(event(.rss(RSSSourceConfig(url: "https://www.example.com/feed")))) == .feed("example.com"))
        #expect(AutomationSentence.parts(event(AutomationDefaults.appLaunch), style: us) == .fixed("Runs when Osaurus opens."))
    }

    @Test func nextRunWords() {
        let at = { (days: Int, hour: Int) in
            Calendar(identifier: .gregorian).date(byAdding: DateComponents(day: days, hour: hour - 10), to: wednesday)!
        }
        #expect(plain(AutomationSentence.nextRun(at(0, 17), now: wednesday, style: us)) == "today at 5:00 PM")
        #expect(plain(AutomationSentence.nextRun(at(1, 8), now: wednesday, style: us)) == "tomorrow at 8:00 AM")
        #expect(plain(AutomationSentence.nextRun(at(2, 8), now: wednesday, style: us)) == "Friday at 8:00 AM")
        #expect(plain(AutomationSentence.nextRun(at(9, 8), now: wednesday, style: us)) == "Nov 27 at 8:00 AM")
        #expect(AutomationSentence.nextRun(at(1, 8), now: wednesday, style: gb) == "tomorrow at 08:00")
    }
}

struct AutomationDefaultsTests {
    @Test func defaultScheduleIsWeekdaysAtNine() {
        #expect(ScheduleCronShape.recognize(AutomationDefaults.scheduleFrequency) == .weekdays(hour: 9, minute: 0))
    }

    @Test func newAutomationMatchesWhatSettingsWrites() {
        let workflowID = UUID()
        let made = AutomationDefaults.event(
            workflowID: workflowID, workflowName: "Morning Brief", inputSchema: .object([:]),
            source: AutomationDefaults.schedule)
        #expect(made.name == "Morning Brief schedule")
        #expect(made.isEnabled)
        #expect(made.action.workflow?.workflowID == workflowID)
        #expect(made.delivery == EventDeliveryPolicy.defaults(for: .schedule))
    }

    @Test func aRequiredInputWithNothingToFillItStartsOff() {
        let made = AutomationDefaults.event(
            workflowID: UUID(), workflowName: "Brief", inputSchema: requiredRecipient, source: AutomationDefaults.appLaunch)
        #expect(!made.isEnabled)
        let missing = AutomationDefaults.missingInputs(schema: requiredRecipient, mapping: [:]).map { $0.key }
        #expect(missing == ["recipient"])
        #expect(AutomationDefaults.missingInputs(schema: requiredRecipient, mapping: ["recipient": "me"]).isEmpty)
    }

    @Test func aNamedValueOfTheKindFillsARequiredInput() {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["files": .object(["type": .string("string")])]),
            "required": .array([.string("files")]),
        ])
        let made = AutomationDefaults.event(
            workflowID: UUID(), workflowName: "Tidy", inputSchema: schema,
            source: AutomationDefaults.folder(path: "/tmp", bookmark: nil))
        #expect(made.isEnabled)
        #expect(made.action.workflow?.inputMapping["files"] == "{{folder.changed_paths}}")
    }

    @Test func aDefaultFillsARequiredInput() {
        let made = AutomationDefaults.event(
            workflowID: UUID(), workflowName: "Brief", inputSchema: defaultedRecipient, source: AutomationDefaults.schedule)
        #expect(made.isEnabled)
    }

    @Test func names() {
        #expect(AutomationDefaults.name(workflowName: "Tidy", kind: .folder) == "Tidy folder")
        #expect(AutomationDefaults.name(workflowName: "Tidy", kind: .app) == "Tidy on launch")
        #expect(AutomationDefaults.name(workflowName: "Tidy", kind: .runFailed) == "Tidy automation")
    }
}

struct AutomationPresetsTests {
    @Test func suggestionRulesFirstMatchWins() {
        #expect(
            AutomationPresets.suggestion(name: "Morning Brief", summary: nil)
                == .schedule(ScheduleCronShape.weekdays(hour: 8, minute: 0).frequency))
        #expect(
            AutomationPresets.suggestion(name: "Daily wrap", summary: nil)
                == .schedule(ScheduleCronShape.weekdays(hour: 18, minute: 0).frequency))
        #expect(
            AutomationPresets.suggestion(name: "Team", summary: "A weekly digest")
                == .schedule(.weekly(dayOfWeek: 6, hour: 16, minute: 0)))
        #expect(AutomationPresets.suggestion(name: "Sort downloads", summary: nil) == .folder(suggestedPath: "~/Downloads"))
        #expect(AutomationPresets.suggestion(name: "Invoice checker", summary: "Reads invoices") == nil)
    }

    @Test func presetsWithASuggestion() {
        let presets = AutomationPresets.presets(name: "Morning Brief", summary: nil, style: us)
        #expect(presets.map { plain($0.title) } == ["Every weekday at 8:00 AM", "Every weekday at 9:00 AM", "Pick a day and time…"])
        let suggested = presets.map { $0.isSuggested }
        #expect(suggested == [true, false, false])
    }

    @Test func presetsWithoutASuggestion() {
        let presets = AutomationPresets.presets(name: "Invoices", summary: nil, style: us)
        #expect(presets.map { plain($0.title) } == ["Every weekday at 9:00 AM", "Every day at 9:00 AM", "Pick a day and time…"])
        let anySuggested = presets.contains { $0.isSuggested }
        #expect(!anySuggested)
    }

    @Test func aSuggestionEqualToADefaultIsNotShownTwice() {
        let rule = AutomationPresets.Kind.schedule(AutomationPresets.defaultSchedules[0])
        let titles = AutomationPresets.presets(name: "x", summary: nil, style: us).map { $0.kind }
        #expect(titles.filter { $0 == rule }.count == 1)
    }

    @Test func phraseForTheToast() {
        #expect(
            plain(AutomationPresets.schedulePhrase(ScheduleCronShape.weekdays(hour: 18, minute: 0).frequency, style: us))
                == "every weekday at 6:00 PM")
    }
}

struct AutomationCatalogTests {
    @Test func offersFriendlyWaysAndKeepsStreamsInAdvanced() {
        let entries = AutomationCatalog.items.map { $0.entry }
        #expect(entries.contains(.kind(.schedule)))
        #expect(entries.contains(.appNews))
        #expect(!entries.contains(.kind(.sse)))
        #expect(!entries.contains(.kind(.webhook)))
        #expect(!entries.contains(.kind(.email)))
        #expect(AutomationCatalog.items.first { $0.entry == .kind(.folder) }?.title == "When a file shows up")
    }

    @Test func countsOnlyWorkflowAutomationsThatAreOn() {
        let events = [
            event(AutomationDefaults.schedule),
            event(AutomationDefaults.schedule, enabled: false),
            event(.webhook(WebhookSourceConfig(provider: .github))),
            event(.webhook(WebhookSourceConfig())),
        ]
        #expect(AutomationCatalog.enabledCount(.kind(.schedule), in: events) == 1)
        #expect(AutomationCatalog.enabledCount(.appNews, in: events) == 1)
    }
}

struct WorkflowHealthTests {
    @Test func barsPadOnTheLeftOldestFirst() {
        #expect(WorkflowHealth.bars(newestFirst: [true, false], count: 4) == [.empty, .empty, .failed, .worked])
        #expect(WorkflowHealth.bars(newestFirst: Array(repeating: true, count: 20), count: 14).count == 14)
    }

    @Test func testsAndStoppedRunsDontCount() {
        let runs = [run(.completed), run(.cancelled), run(.failed), run(.running), run(.completed, caller: WorkflowCaller(kind: .test))]
        #expect(WorkflowHealth.outcomes(runs) == [true, false])
    }

    @Test func summaries() {
        #expect(WorkflowHealth.summary(WorkflowHealth.bars(newestFirst: [], count: 14)) == nil)
        #expect(WorkflowHealth.summary(WorkflowHealth.bars(newestFirst: [true], count: 14)) == "Everything is working. The last run finished.")
        #expect(WorkflowHealth.summary(WorkflowHealth.bars(newestFirst: [true, true, true], count: 14)) == "Everything is working. Last 3 runs all finished.")
        #expect(WorkflowHealth.summary(WorkflowHealth.bars(newestFirst: [false, true, false, true], count: 14)) == "2 of the last 4 runs failed.")
        #expect(WorkflowHealth.accessibilityLabel(WorkflowHealth.bars(newestFirst: [], count: 14)) == "No runs yet")
    }
}

struct WorkflowRunWordsTests {
    @Test func took() {
        #expect(WorkflowRunWords.took(0.2) == "took 1 sec")
        #expect(WorkflowRunWords.took(42) == "took 42 sec")
        #expect(WorkflowRunWords.took(185) == "took 3 min")
        #expect(WorkflowRunWords.took(3_900) == "took 1 hr 5 min")
    }

    @Test func when() {
        #expect(plain(WorkflowRunWords.when(wednesday, now: wednesday, style: us)) == "Today, 10:00 AM")
        let yesterday = wednesday.addingTimeInterval(-86_400)
        #expect(plain(WorkflowRunWords.when(yesterday, now: wednesday, style: us)) == "Yesterday, 10:00 AM")
        #expect(plain(WorkflowRunWords.lastRan(yesterday, now: wednesday, style: us)) == "yesterday at 10:00 AM")
        let monday = wednesday.addingTimeInterval(-2 * 86_400)
        #expect(plain(WorkflowRunWords.lastRan(monday, now: wednesday, style: us)) == "Monday at 10:00 AM")
    }

    @Test func howItStarted() {
        #expect(WorkflowRunWords.howItStarted(WorkflowCaller(kind: .user), event: nil) == "You ran it")
        #expect(WorkflowRunWords.howItStarted(WorkflowCaller(kind: .agent, agentName: "Scout"), event: nil) == "Scout ran it")
        #expect(WorkflowRunWords.howItStarted(WorkflowCaller(kind: .event), event: nil) == "Ran on its own")
        #expect(WorkflowRunWords.howItStarted(WorkflowCaller(kind: .event), event: event(AutomationDefaults.schedule)) == "On schedule")
        let folder = event(.folder(FolderSourceConfig(path: "/Users/me/Downloads")))
        #expect(WorkflowRunWords.howItStarted(WorkflowCaller(kind: .event), event: folder) == "A file was added to Downloads")
    }

    @Test func detail() {
        #expect(WorkflowRunWords.detail(run(.completed), event: nil) == "You ran it, took 42 sec")
        #expect(WorkflowRunWords.detail(run(.running), event: nil) == "You ran it")
    }
}

struct WorkflowDetailStatusLineTests {
    typealias Page = WorkflowStatusLine

    @Test func setupComesFirst() {
        let line = Page.line(needsSetup: true, automations: [event(AutomationDefaults.schedule)], lastRun: nil, now: wednesday, style: us)
        #expect(line.text == "Finish setup to run.")
        #expect(line.tone == .warning)
    }

    /// The schedule fires in the Mac's time zone, so the words use it too.
    @Test func onWithTheNextRun() {
        let local = AutomationSentence.Style(locale: Locale(identifier: "en_US"), timeZone: .current)
        let line = Page.line(
            needsSetup: false, automations: [event(AutomationDefaults.schedule)], lastRun: nil, now: wednesday, style: local)
        let text = plain(line.text)
        #expect(text == "On. Next run today at 9:00 AM." || text == "On. Next run tomorrow at 9:00 AM.")
        #expect(line.tone == .success)
    }

    @Test func onWithoutATime() {
        let line = Page.line(
            needsSetup: false, automations: [event(AutomationDefaults.appLaunch)], lastRun: nil, now: wednesday, style: us)
        #expect(line.text == "On. Runs when Osaurus opens.")
    }

    @Test func byHandOnly() {
        #expect(
            Page.line(needsSetup: false, automations: [], lastRun: nil, now: wednesday, style: us).text
                == "Only runs when you click Run. Not run yet.")
        let off = event(AutomationDefaults.schedule, enabled: false)
        let line = Page.line(needsSetup: false, automations: [off], lastRun: run(.completed), now: wednesday, style: us)
        #expect(plain(line.text) == "Only runs when you click Run. Last ran today at 10:00 AM.")
        #expect(line.tone == nil)
    }

    @Test func aFailedLastRunIsTheProblem() {
        let line = Page.line(
            needsSetup: false, automations: [event(AutomationDefaults.schedule)], lastRun: run(.failed), now: wednesday, style: us)
        #expect(line.text == "The last run failed.")
        #expect(line.tone == .error)
    }
}
