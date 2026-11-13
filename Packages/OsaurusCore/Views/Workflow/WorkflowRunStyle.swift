//
//  WorkflowRunStyle.swift
//  osaurus
//
//  How a run's status looks wherever runs are listed: the workflow's
//  details, the Architect's tests, and the History lens's Runs tab.
//

import SwiftUI

enum WorkflowRunStyle {
    static func icon(_ status: WorkflowRunStatus) -> String {
        switch status {
        case .running: return "circle.dotted"
        case .awaitingUser: return "person.crop.circle.badge.questionmark"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .needsSetup: return "exclamationmark.triangle.fill"
        }
    }

    /// Who started a run, in words: the agent's or event's name, else the
    /// kind of caller.
    static func caller(_ caller: WorkflowCaller) -> String {
        if let teammate = caller.onBehalfOf {
            let who = ParticipantFormatter.short(teammate)
            guard let agent = caller.agentName, !agent.isEmpty else { return who }
            return L("\(who) via \(agent)")
        }
        if caller.kind == .event, let name = caller.eventName, !name.isEmpty { return L("Automation · \(name)") }
        if let name = caller.agentName, !name.isEmpty { return name }
        switch caller.kind {
        case .user: return L("You")
        case .orchestrator: return L("Osaurus")
        case .agent: return L("An agent")
        case .test: return L("A test in the Architect")
        case .workflow: return L("Another workflow")
        case .event: return L("An automation")
        }
    }

    @MainActor
    static func color(_ status: WorkflowRunStatus, theme: ThemeProtocol) -> Color {
        switch status {
        case .running: return theme.statusInk(.info)
        case .awaitingUser, .needsSetup: return theme.statusInk(.warning)
        case .completed: return theme.statusInk(.success)
        case .failed: return theme.statusInk(.error)
        case .cancelled: return theme.text.tertiary
        }
    }
}

/// A step's status glyph, a spinner while it works.
struct WorkflowStepStatusIcon: View {
    let status: NodeRunStatus?

    @Environment(\.theme) private var theme

    var body: some View {
        switch status {
        case .running?:
            SettingsSpinner(size: .mini)
        case .done?, .pinned?:
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.statusInk(.success))
        case .failed?:
            Image(systemName: "xmark.circle.fill").foregroundColor(theme.statusInk(.error))
        case .awaitingUser?:
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundColor(theme.statusInk(.warning))
        case .skipped?:
            Image(systemName: "minus.circle").foregroundColor(theme.text.tertiary)
        case nil, .pending?:
            Image(systemName: "circle").foregroundColor(theme.text.tertiary)
        }
    }
}

/// The status glyph, a spinner while the run is going.
struct WorkflowRunStatusIcon: View {
    let status: WorkflowRunStatus
    var size: CGFloat = 12

    @Environment(\.theme) private var theme

    var body: some View {
        if status == .running {
            SettingsSpinner(size: .mini)
        } else {
            Image(systemName: WorkflowRunStyle.icon(status))
                .glyphSize(points: size, weight: .semibold)
                .foregroundColor(WorkflowRunStyle.color(status, theme: theme))
        }
    }
}
