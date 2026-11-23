//
//  WorkflowsSidebarTests.swift
//  osaurusTests
//
//  The Workflows sidebar's words and lists: automation sentences in both
//  clock styles, the weekday cron shape, pinning, and the list model.
//

import Foundation
import Testing

@testable import OsaurusCore

private let us = AutomationSentence.Style(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
private let gb = AutomationSentence.Style(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)

/// ICU puts a narrow no-break space before AM/PM.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

private func event(_ source: EventSource, workflowID: UUID = UUID(), enabled: Bool = true) -> OsaurusEvent {
    OsaurusEvent(
        name: "Test", isEnabled: enabled, source: source,
        action: .workflow(WorkflowEventAction(workflowID: workflowID)))
}

private func schedule(_ frequency: ScheduleFrequency) -> EventSource {
    .schedule(ScheduleSourceConfig(frequency: frequency))
}

@Suite("Schedule cron shape")
struct ScheduleCronShapeTests {
    @Test
    func recognizesOnlyTheWeekdayShape() {
        #expect(ScheduleCronShape.recognize("0 8 * * 1-5") == .weekdays(hour: 8, minute: 0))
        #expect(ScheduleCronShape.recognize("30 18 * * 1-5") == .weekdays(hour: 18, minute: 30))
        #expect(ScheduleCronShape.recognize("  0  8 * *  1-5 ") == .weekdays(hour: 8, minute: 0))
        #expect(ScheduleCronShape.recognize("0 8 * * 1-6") == nil)
        #expect(ScheduleCronShape.recognize("0 8 * * MON-FRI") == nil)
        #expect(ScheduleCronShape.recognize("*/5 8 * * 1-5") == nil)
        #expect(ScheduleCronShape.recognize("0 24 * * 1-5") == nil)
        #expect(ScheduleCronShape.recognize("60 8 * * 1-5") == nil)
        #expect(ScheduleCronShape.recognize("0 8 1 * 1-5") == nil)
        #expect(ScheduleCronShape.recognize("0 8 * * 1-5 2026") == nil)
        #expect(ScheduleCronShape.recognize(.daily(hour: 8, minute: 0)) == nil)
    }

    @Test
    func writesWhatItReads() {
        let shape = ScheduleCronShape.weekdays(hour: 9, minute: 5)
        #expect(shape.expression == "5 9 * * 1-5")
        #expect(ScheduleCronShape.recognize(shape.frequency) == shape)
    }
}

@Suite("Automation sentences")
struct AutomationSentenceTests {
    @Test
    func schedules_shortAndLong_12HourClock() {
        let rows: [(ScheduleFrequency, String, String)] = [
            (.daily(hour: 8, minute: 0), "Daily at 8:00 AM", "runs every day at 8:00 AM"),
            (ScheduleCronShape.weekdays(hour: 8, minute: 0).frequency, "Weekdays at 8:00 AM", "runs every weekday at 8:00 AM"),
            (.weekly(dayOfWeek: 6, hour: 16, minute: 0), "Fridays at 4:00 PM", "runs every Friday at 4:00 PM"),
            (.hourly(minute: 0), "Every hour", "runs every hour"),
            (.everyNMinutes(minutes: 30), "Every 30 min", "runs every 30 minutes"),
            (.monthly(dayOfMonth: 1, hour: 9, minute: 0), "Monthly on the 1st", "runs on the 1st of every month at 9:00 AM"),
            (.yearly(month: 3, day: 3, hour: 9, minute: 0), "Yearly on Mar 3", "runs every year on March 3 at 9:00 AM"),
            (.cron(expression: "15 0,7 * * 1-5"), "Custom schedule", "runs on a custom schedule"),
        ]
        for (frequency, short, long) in rows {
            let e = event(schedule(frequency))
            #expect(plain(AutomationSentence.short(e, style: us)) == short)
            #expect(plain(AutomationSentence.long(e, style: us)) == long)
        }
        let once = DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 0)
        let date = us.calendar.date(from: once)!
        #expect(plain(AutomationSentence.short(event(schedule(.once(date: date))), style: us)) == "Once, Nov 20")
        #expect(
            plain(AutomationSentence.long(event(schedule(.once(date: date))), style: us))
                == "runs once on November 20 at 9:00 AM")
    }

    @Test
    func schedules_24HourClock() {
        let e = event(schedule(ScheduleCronShape.weekdays(hour: 18, minute: 0).frequency))
        #expect(plain(AutomationSentence.short(e, style: gb)) == "Weekdays at 18:00")
        #expect(plain(AutomationSentence.long(e, style: gb)) == "runs every weekday at 18:00")
        let daily = event(schedule(.daily(hour: 8, minute: 5)))
        #expect(plain(AutomationSentence.short(daily, style: gb)) == "Daily at 08:05")
    }

    @Test
    func otherKinds() {
        let folder = event(.folder(FolderSourceConfig(path: "/Users/me/Downloads")))
        #expect(AutomationSentence.short(folder, style: us) == "When Downloads changes")
        #expect(AutomationSentence.long(folder, style: us) == "runs when a file is added to Downloads")

        let rss = event(.rss(RSSSourceConfig(url: "https://www.example.com/feed.xml")))
        #expect(AutomationSentence.short(rss, style: us) == "When example.com posts")
        #expect(AutomationSentence.long(rss, style: us) == "runs when example.com posts something new")

        let failed = event(.runFailed(RunFailedSourceConfig()))
        #expect(AutomationSentence.short(failed, style: us) == "When a run fails")
        #expect(AutomationSentence.long(failed, style: us) == "runs when another workflow fails")

        let app = event(.app(AppEventsSourceConfig()))
        #expect(AutomationSentence.short(app, style: us) == "When Osaurus opens")
        #expect(AutomationSentence.long(app, style: us) == "runs when Osaurus opens")

        var github = WebhookSourceConfig()
        github.provider = .github
        #expect(AutomationSentence.short(event(.webhook(github)), style: us) == "When GitHub has news")
        #expect(AutomationSentence.long(event(.webhook(github)), style: us) == "runs when GitHub has news")

        let generic = event(.webhook(WebhookSourceConfig()))
        #expect(AutomationSentence.short(generic, style: us) == "Custom trigger")
        #expect(AutomationSentence.long(generic, style: us) == "runs from a custom trigger")
        let sse = event(.sse(SSESourceConfig()))
        #expect(AutomationSentence.short(sse, style: us) == "Custom trigger")
    }

    @Test
    func neverSaysTheTechnicalWords() {
        let sources: [EventSource] = [
            schedule(.cron(expression: "1 2 3 4 5")), .webhook(WebhookSourceConfig()), .sse(SSESourceConfig()),
            .app(AppEventsSourceConfig(reasons: [.automationEnabled])),
        ]
        for source in sources {
            for text in [AutomationSentence.short(event(source), style: us), AutomationSentence.long(event(source), style: us)] {
                for word in ["event", "trigger ", "webhook", "cron", "payload"] {
                    #expect(!text.lowercased().contains(word), "\(text) says \(word)")
                }
            }
        }
    }
}

@Suite("Workflows sidebar model")
struct WorkflowsSidebarModelTests {
    private static func workflow(_ name: String, pinnedAt: Date? = nil, tags: [String] = []) -> InstalledWorkflow {
        var w = InstalledWorkflow(template: WF.template(WF.intake(), name: name), bindings: InstallBindings(), tags: tags)
        if let pinnedAt {
            w.isPinned = true
            w.pinnedAt = pinnedAt
        }
        return w
    }

    private static func facts(
        _ workflow: InstalledWorkflow, _ frequency: ScheduleFrequency, enabled: Bool = true,
        latest: EventRunStatus? = nil, problem: Bool = false
    ) -> WorkflowsSidebarModel.AutomationFacts {
        WorkflowsSidebarModel.AutomationFacts(
            event: event(schedule(frequency), workflowID: workflow.id, enabled: enabled), latestSettled: latest,
            hasTargetProblem: problem)
    }

    @Test
    func sections_pinnedOldestFirst_restByName() {
        let now = Date()
        let brief = Self.workflow("Morning Brief", pinnedAt: now)
        let triage = Self.workflow("Mail Triage", pinnedAt: now.addingTimeInterval(60))
        let digest = Self.workflow("Repo Digest")
        let end = Self.workflow("end of Day")
        let model = WorkflowsSidebarModel.make(workflows: [digest, triage, end, brief], style: us)
        #expect(model.pinned.map(\.name) == ["Morning Brief", "Mail Triage"])
        #expect(model.all.map(\.name) == ["end of Day", "Repo Digest"])
        #expect(model.pinned.allSatisfy { $0.isPinned })
        #expect(model.drafts.isEmpty && model.workspaces.isEmpty)
    }

    @Test
    func status_andSecondLine() {
        let manual = Self.workflow("Manual")
        let on = Self.workflow("On")
        let off = Self.workflow("Off")
        let broken = Self.workflow("Broken")
        let missing = Self.workflow("Missing")
        let many = Self.workflow("Many")
        var setup = Self.workflow("Setup")
        setup.needsSetup = true
        let weekdays = ScheduleCronShape.weekdays(hour: 8, minute: 0).frequency
        let automations: [UUID: [WorkflowsSidebarModel.AutomationFacts]] = [
            on.id: [Self.facts(on, weekdays, latest: .succeeded)],
            off.id: [Self.facts(off, weekdays, enabled: false, latest: .failed)],
            broken.id: [Self.facts(broken, weekdays, latest: .failed)],
            missing.id: [Self.facts(missing, weekdays, problem: true)],
            many.id: [
                Self.facts(many, .daily(hour: 9, minute: 0)), Self.facts(many, .hourly(minute: 0)),
                Self.facts(many, .hourly(minute: 0), enabled: false),
            ],
        ]
        let now = Date()
        let model = WorkflowsSidebarModel.make(
            workflows: [manual, on, off, broken, missing, many, setup], automations: automations,
            lastRunAt: [off.id: now], now: now, style: us)
        func row(_ name: String) -> WorkflowsSidebarModel.Row { model.all.first { $0.name == name }! }
        #expect(row("Manual").status == .manual && row("Manual").subtitle == "Not run yet")
        #expect(row("On").status == .automated && plain(row("On").subtitle) == "Weekdays at 8:00 AM")
        #expect(row("Off").status == .manual, "one turned off by the person counts for nothing")
        #expect(row("Off").subtitle == "Last run today")
        #expect(row("Broken").status == .problem && row("Broken").subtitle == "Needs attention")
        #expect(row("Missing").status == .problem)
        #expect(row("Many").status == .automated && plain(row("Many").subtitle) == "Daily at 9:00 AM +1 more")
        #expect(row("Setup").status == .needsSetup)
    }

    @Test
    func hostedLinksListWithTheirOwner_andCannotBeAutomated() throws {
        let data = """
            {"id":"\(UUID().uuidString)","workspace_id":"w1","agent_address":"0xabc","agent_name":"Bot",
             "owner_name":"Kris","remote_workflow_id":"\(UUID().uuidString)","template_id":"\(UUID().uuidString)",
             "name":"Team Report","inputs":{},"orchestrator_visible":true,"added_at":0}
            """.data(using: .utf8)!
        let link = try JSONDecoder().decode(HostedWorkflowLink.self, from: data)
        let model = WorkflowsSidebarModel.make(
            workflows: [Self.workflow("Alpha")], hostedLinks: [link], style: us)
        let row = try #require(model.all.first { $0.name == "Team Report" })
        #expect(row.subtitle == link.hostLabel)
        #expect(!row.canAutomate)
        #expect(model.all.first { $0.name == "Alpha" }?.canAutomate == true)

        var pinnedLink = link
        pinnedLink.pinnedAt = Date(timeIntervalSince1970: 100)
        let older = Self.workflow("Zed", pinnedAt: Date(timeIntervalSince1970: 50))
        let pinned = WorkflowsSidebarModel.make(workflows: [older], hostedLinks: [pinnedLink], style: us)
        #expect(pinned.pinned.map(\.name) == ["Zed", "Team Report"], "a teammate's workflow pins too, by pin date")
        #expect(pinned.all.isEmpty)
    }

    @Test
    func search_filtersEverySectionByNameAndTag() {
        let a = Self.workflow("Invoice Sweep", pinnedAt: Date(), tags: ["finance"])
        let b = Self.workflow("Release Notes")
        let workspaces = [WorkflowsSidebarModel.WorkspaceRow(id: "w", name: "Finance Team")]
        let model = WorkflowsSidebarModel.make(workflows: [a, b], workspaces: workspaces, query: "finance", style: us)
        #expect(model.pinned.map(\.name) == ["Invoice Sweep"])
        #expect(model.all.isEmpty)
        #expect(model.workspaces.map(\.name) == ["Finance Team"])
        let none = WorkflowsSidebarModel.make(workflows: [a, b], query: "zzz", style: us)
        #expect(none.isEmpty)
    }

    @Test
    func sortOrders_newestFirst_neverAfter_myOrderThenTheRestByName() {
        let a = Self.workflow("Alpha")
        let b = Self.workflow("Bravo")
        let c = Self.workflow("Charlie")
        let rows = WorkflowsSidebarModel.make(workflows: [c, a, b], style: us).all
        let key = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.sortKey) })
        func names(_ sort: WorkflowsSidebarSort, added: [String: Date] = [:], lastRunAt: [UUID: Date] = [:], manual: [String] = [])
            -> [String]
        {
            WorkflowsSidebarModel.order(rows, by: sort, added: added, lastRunAt: lastRunAt, manualOrder: manual).map(\.name)
        }
        #expect(names(.name) == ["Alpha", "Bravo", "Charlie"])
        let lastRun = [b.id: Date(timeIntervalSince1970: 10), c.id: Date(timeIntervalSince1970: 20)]
        #expect(names(.lastRun, lastRunAt: lastRun) == ["Charlie", "Bravo", "Alpha"], "never ran goes last")
        let added = [key["Alpha"]!: Date(timeIntervalSince1970: 30), key["Charlie"]!: Date(timeIntervalSince1970: 5)]
        #expect(names(.dateAdded, added: added) == ["Alpha", "Charlie", "Bravo"])
        #expect(names(.manual, manual: [key["Charlie"]!, key["Alpha"]!]) == ["Charlie", "Alpha", "Bravo"], "new ones go last")
        #expect(names(.manual) == ["Alpha", "Bravo", "Charlie"])
    }

    @Test
    func cardGrid_leavesNoCardAlone() {
        #expect(WorkflowCardGridColumns.count(4, fit: 3) == 2)
        #expect(WorkflowCardGridColumns.count(6, fit: 3) == 3)
        #expect(WorkflowCardGridColumns.count(3, fit: 3) == 3)
        #expect(WorkflowCardGridColumns.count(3, fit: 2) == 1)
        #expect(WorkflowCardGridColumns.count(2, fit: 3) == 2)
        #expect(WorkflowCardGridColumns.count(5, fit: 3) == 3, "3 and 2, the 2 centered")
        #expect(WorkflowCardGridColumns.count(7, fit: 2) == 2)
        #expect(WorkflowCardGridColumns.count(4, fit: 1) == 1)
        #expect(WorkflowCardGridColumns.count(0, fit: 3) == 1)
    }

    @Test
    func published_isMarked() {
        let a = Self.workflow("Shared")
        let model = WorkflowsSidebarModel.make(workflows: [a], publishedTemplateIDs: [a.templateID], style: us)
        #expect(model.all.first?.isPublished == true)
    }

    @MainActor
    @Test
    func pin_persistsAndStaysOutOfTheTemplate() throws {
        let template = try TemplateStore.shared.save(
            WF.template(WF.intake(), name: "Pinned \(UUID().uuidString.prefix(6))"))
        let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        #expect(!installed.isPinned && installed.pinnedAt == nil)

        try InstalledWorkflowStore.shared.setPinned(true, id: installed.id)
        let saved = try #require(InstalledWorkflowStore.shared.workflow(id: installed.id))
        #expect(saved.isPinned && saved.pinnedAt != nil)

        let data = try JSONEncoder().encode(saved)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["is_pinned"] as? Bool == true)
        let template_ = json["template"] as? [String: Any]
        #expect(template_?["is_pinned"] == nil && template_?["pinned_at"] == nil, "pins are not part of the template")
        #expect(try JSONDecoder().decode(InstalledWorkflow.self, from: data).isPinned)

        var legacy = json
        legacy["is_pinned"] = nil
        legacy["pinned_at"] = nil
        let old = try JSONDecoder().decode(InstalledWorkflow.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!old.isPinned && old.pinnedAt == nil)

        var v2 = template
        v2.version += 1
        #expect(try InstalledWorkflowStore.shared.install(v2, bindings: InstallBindings()).isPinned, "an update keeps the pin")

        try InstalledWorkflowStore.shared.setPinned(false, id: installed.id)
        let unpinned = try #require(InstalledWorkflowStore.shared.workflow(id: installed.id))
        #expect(!unpinned.isPinned && unpinned.pinnedAt == nil)
        let exported = String(decoding: try TemplateFileExport.exportData(saved.template), as: UTF8.self)
        #expect(!exported.contains("pinned"))
    }
}
