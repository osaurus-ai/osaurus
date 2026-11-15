//
//  WorkflowShareNudge.swift
//  osaurus
//
//  "This one is working well": a card under Recent runs that offers to
//  share a workflow the person made once it has proven itself. It shows
//  only for their own workflows (not installed from the Store, not a
//  starter, never published), after the last ten runs all finished over
//  at least five different days, until they close it. At most one
//  workflow shows it in a week.
//

import SwiftUI

enum ShareNudgeEligibility {
    static let runCount = 10
    static let distinctDays = 5

    /// Whether `workflow` has earned the card. `runs` are its runs, any order.
    static func isEligible(
        _ workflow: InstalledWorkflow, runs: [WorkflowRun], isBuiltIn: Bool, isPublished: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        guard workflow.source == nil, !isBuiltIn, !isPublished, !workflow.shareNudgeDismissed else { return false }
        let recent = runs.filter { !$0.isTest && !$0.isDerived && $0.status.isTerminal }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(runCount)
        guard recent.count == runCount, recent.allSatisfy({ $0.status == .completed }) else { return false }
        return Set(recent.map { calendar.startOfDay(for: $0.startedAt) }).count >= distinctDays
    }
}

/// The once-a-week limit: the workflow that last showed the card keeps it
/// for a week; no other workflow shows it until then.
struct ShareNudgeCap {
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    private static let workflowKey = "workflows.shareNudge.shownWorkflowID"
    private static let dateKey = "workflows.shareNudge.shownAt"

    var defaults: UserDefaults = .standard

    static func allows(_ workflowID: UUID, shown: (workflowID: UUID, at: Date)?, now: Date) -> Bool {
        guard let shown, now.timeIntervalSince(shown.at) < interval else { return true }
        return shown.workflowID == workflowID
    }

    var shown: (workflowID: UUID, at: Date)? {
        guard let raw = defaults.string(forKey: Self.workflowKey), let id = UUID(uuidString: raw),
            let at = defaults.object(forKey: Self.dateKey) as? Date
        else { return nil }
        return (id, at)
    }

    func allows(_ workflowID: UUID, now: Date = Date()) -> Bool {
        Self.allows(workflowID, shown: shown, now: now)
    }

    /// Starts this workflow's week, unless its week is already running.
    func recordShown(_ workflowID: UUID, now: Date = Date()) {
        if let shown, shown.workflowID == workflowID, now.timeIntervalSince(shown.at) < Self.interval { return }
        defaults.set(workflowID.uuidString, forKey: Self.workflowKey)
        defaults.set(now, forKey: Self.dateKey)
    }
}

struct WorkflowShareNudgeCard: View {
    @Environment(\.theme) private var theme
    let onShare: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                Image(systemName: "sparkles")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundStyle(theme.statusInk(.success))
                    .accessibilityHidden(true)
                Text("This one is working well", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundStyle(theme.text.primary)
                Spacer(minLength: theme.space.s8)
                SettingsIconButton("xmark", help: L("Don't suggest sharing this workflow"), size: .compact, action: onDismiss)
            }
            Text(
                "Others might want it too. Share the recipe to the Store. Your results and accounts stay on your Mac.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundStyle(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            WorkflowTextLink(title: L("Share to the Store"), action: onShare)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.card)
        .settingsLandingAnchor("workflows.shareNudge")
    }
}
