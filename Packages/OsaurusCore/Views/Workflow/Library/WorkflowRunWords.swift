//
//  WorkflowRunWords.swift
//  osaurus
//
//  One run in plain words, for the workflow's page and Activity: when it
//  ran ("Today, 8:00 AM"), how it started ("On schedule", "You ran it",
//  "Scout ran it", "A file was added to Downloads") and how long it took.
//

import Foundation

/// The line under a workflow's name on its page, and the dot beside it
/// (nil tone: neutral). A run going now says where it is.
enum WorkflowStatusLine {
    static func line(
        needsSetup: Bool, liveRun: WorkflowLiveRuns.Summary? = nil, liveStepName: String? = nil,
        automations: [OsaurusEvent], lastRun: WorkflowRun?, now: Date = Date(),
        style: AutomationSentence.Style = .current
    ) -> (text: String, tone: ThemeStatusKind?) {
        if needsSetup { return (L("Finish setup to run."), .warning) }
        if let liveRun {
            let progress = liveRun.progress(stepName: liveStepName)
            return liveRun.isWaitingOnYou ? (progress, .warning) : (L("Running now · \(progress)"), .info)
        }
        if let lastRun, lastRun.status == .failed { return (L("The last run failed."), .error) }
        let on = automations.filter(\.isEnabled)
        if !on.isEmpty {
            if let next = on.compactMap({ $0.nextFireDate(asOf: now) }).min() {
                return (L("On. Next run \(AutomationSentence.nextRun(next, now: now, style: style))."), .success)
            }
            return (L("On. \(AutomationSentence.sentence(on[0], style: style))"), .success)
        }
        guard let lastRun else { return (L("Runs when you start it. Not run yet."), nil) }
        let when = WorkflowRunWords.lastRan(lastRun.startedAt, now: now, style: style)
        return (L("Runs when you start it. Last ran \(when)."), nil)
    }
}

/// The line under one automation, on a workflow's page and on Home: when
/// it runs next, or how it last went.
enum WorkflowAutomationState {
    static func line(
        _ event: OsaurusEvent, latestSettled: EventRun? = nil, needsSetup: Bool = false, inputsMissing: Bool = false,
        hasTargetProblem: Bool = false, now: Date = Date(), style: AutomationSentence.Style = .current
    ) -> (text: String, tone: ThemeStatusKind?) {
        if inputsMissing { return (L("Off until you fill in what it uses."), .warning) }
        guard event.isEnabled else {
            if case .schedule(let schedule) = event.source, case .once = schedule.frequency, let fired = event.lastFiredAt {
                return (L("Ran once on \(style.date(fired, template: "MMMd"))"), nil)
            }
            return (L("Off"), nil)
        }
        if needsSetup { return (L("Finish setup to run"), .warning) }
        if hasTargetProblem { return (L("Can't start its workflow. Open it to see why."), .error) }
        if let latestSettled, latestSettled.status == .failed {
            return (L("Last run failed \(WorkflowRunWords.day(latestSettled.firedAt, now: now, style: style))"), .error)
        }
        if let next = event.nextFireDate(asOf: now) {
            return (L("Next: \(AutomationSentence.nextRun(next, now: now, style: style))"), nil)
        }
        let lastRan = latestSettled.map { L("Last ran \(WorkflowRunWords.day($0.firedAt, now: now, style: style))") }
        switch event.sourceKind {
        case .folder, .rss: return (lastRan.map { L("Watching. \($0)") } ?? L("Watching."), nil)
        default: return (lastRan.map { L("On. \($0)") } ?? L("On"), nil)
        }
    }
}

enum WorkflowRunWords {
    /// "today", "yesterday", "Friday", "Nov 2": a past day inside a sentence.
    static func day(_ date: Date, now: Date = Date(), style: AutomationSentence.Style = .current) -> String {
        let calendar = style.calendar
        if calendar.isDate(date, inSameDayAs: now) { return L("today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L("yesterday")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        return days > 0 && days < 7 ? style.date(date, template: "EEEE") : style.date(date, template: "MMMd")
    }

    /// "Today, 8:00 AM", "Yesterday, 8:00 AM", "Friday, 8:00 AM", "Nov 3, 8:00 AM".
    static func when(_ date: Date, now: Date = Date(), style: AutomationSentence.Style = .current) -> String {
        let calendar = style.calendar
        let time = style.time(date)
        if calendar.isDate(date, inSameDayAs: now) { return L("Today, \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L("Yesterday, \(time)")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 { return L("\(style.date(date, template: "EEEE")), \(time)") }
        return L("\(style.date(date, template: "MMMd")), \(time)")
    }

    /// "today at 8:00 AM", "yesterday at 8:00 AM", "Monday at 8:00 AM",
    /// "Nov 2 at 8:00 AM": what follows "Last ran" in a sentence.
    static func lastRan(_ date: Date, now: Date = Date(), style: AutomationSentence.Style = .current) -> String {
        let calendar = style.calendar
        let time = style.time(date)
        if calendar.isDate(date, inSameDayAs: now) { return L("today at \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L("yesterday at \(time)")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 { return L("\(style.date(date, template: "EEEE")) at \(time)") }
        return L("\(style.date(date, template: "MMMd")) at \(time)")
    }

    /// How a run started. `event` is the automation that fired it, when it
    /// still exists; `agentName` resolves an agent's current name.
    static func howItStarted(
        _ caller: WorkflowCaller, event: OsaurusEvent?, agentName: (UUID) -> String? = { _ in nil }
    ) -> String {
        switch caller.kind {
        case .user:
            if let person = caller.onBehalfOf?.displayName { return L("\(person) ran it") }
            return L("You ran it")
        case .agent, .orchestrator:
            let name = caller.agentID.flatMap(agentName) ?? caller.agentName
            if let name, !name.isEmpty { return L("\(name) ran it") }
            return caller.kind == .orchestrator ? L("Osaurus ran it") : L("An agent ran it")
        case .event:
            guard let event else { return L("Ran on its own") }
            return automationPhrase(event)
        case .workflow: return L("Another workflow ran it")
        case .test: return L("A test run")
        }
    }

    /// What the automation saw, as the reason a run started.
    static func automationPhrase(_ event: OsaurusEvent) -> String {
        switch event.source {
        case .schedule: return L("On schedule")
        case .folder(let folder): return L("A file was added to \(AutomationSentence.folderName(folder))")
        case .rss(let rss): return L("\(AutomationSentence.siteName(rss)) posted something new")
        case .runFailed: return L("Another workflow failed")
        case .app: return L("Osaurus opened")
        case .webhook(let webhook):
            guard let provider = AutomationSentence.providerName(webhook.provider) else { return L("Ran on its own") }
            return L("\(provider) had news")
        case .sse: return L("Ran on its own")
        case .email: return L("New mail arrived")
        case .channelMessage: return L("A message arrived")
        }
    }

    /// "took 42 sec", "took 3 min", "took 1 hr 5 min".
    static func took(_ seconds: TimeInterval) -> String {
        L("took \(duration(seconds))")
    }

    /// A run still going, as a stopwatch: "0:42", "12:05", "1:02:05".
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let whole = Duration.seconds(max(0, Int(seconds)))
        return whole.formatted(.time(pattern: seconds < 3600 ? .minuteSecond : .hourMinuteSecond))
    }

    /// "42 sec", "3 min", "1 hr 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return L("\(max(1, whole)) sec") }
        let minutes = whole / 60
        if minutes < 60 { return L("\(minutes) min") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? L("\(hours) hr") : L("\(hours) hr \(rest) min")
    }

    /// The run page's one sentence about where a run stands, and its tone.
    static func status(_ run: WorkflowRun, definition: WorkflowDefinition?) -> (text: String, tone: ThemeStatusKind?) {
        let summary = WorkflowLiveRuns.Summary(run)
        switch run.status {
        case .awaitingUser:
            return (summary.progress(stepName: summary.stepName(in: definition)), .warning)
        case .running:
            return (L("Running now · \(summary.progress(stepName: summary.stepName(in: definition)))"), .info)
        case .completed:
            return (L("It worked."), .success)
        case .failed:
            let step = run.nodes.first { $0.status == .failed }.flatMap { definition?.node($0.nodeID)?.name }
            return (step.map { L("It stopped at \($0).") } ?? L("It didn't finish."), .error)
        case .needsSetup:
            return (L("It couldn't start: setup isn't finished."), .warning)
        case .cancelled:
            return (L("It was stopped."), nil)
        }
    }

    /// "On schedule, took 42 sec"; a run still going says only how it started.
    static func detail(
        _ run: WorkflowRun, event: OsaurusEvent?, agentName: (UUID) -> String? = { _ in nil }
    ) -> String {
        let started = howItStarted(run.caller, event: event, agentName: agentName)
        guard run.status.isTerminal, let finished = run.finishedAt else { return started }
        return L("\(started), \(took(finished.timeIntervalSince(run.startedAt)))")
    }
}
