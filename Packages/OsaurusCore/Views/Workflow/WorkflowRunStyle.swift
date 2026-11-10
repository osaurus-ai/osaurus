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
        case .running: return theme.statusInk.info
        case .awaitingUser, .needsSetup: return theme.statusInk.warning
        case .completed: return theme.statusInk.success
        case .failed: return theme.statusInk.error
        case .cancelled: return theme.text.tertiary
        }
    }
}

/// Status colours for glyphs, text, and progress drawn straight on the
/// canvas or a card. A theme's status foreground is the colour for text on
/// its status fill; where that fill is the solid shade and the foreground a
/// pale tint, the tint vanishes on a plain surface. Each tone takes the
/// shade of its set that stands out most from the canvas.
struct WorkflowStatusInk {
    let success: Color
    let warning: Color
    let error: Color
    let info: Color

    init(_ theme: ThemeProtocol) {
        let canvas = Self.luminance(theme.surface.canvas)
        func ink(_ set: ThemeStatusSet<Color>) -> Color {
            [set.foreground, set.border, set.background].max { a, b in
                Self.contrast(Self.luminance(a), canvas) < Self.contrast(Self.luminance(b), canvas)
            } ?? set.foreground
        }
        success = ink(theme.status.success)
        warning = ink(theme.status.warning)
        error = ink(theme.status.error)
        info = ink(theme.status.info)
    }

    static func luminance(_ color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension ThemeProtocol {
    @MainActor
    var statusInk: WorkflowStatusInk {
        if let cached = WorkflowStatusInk.cache, cached.fingerprint == renderFingerprint { return cached.ink }
        let ink = WorkflowStatusInk(self)
        WorkflowStatusInk.cache = (renderFingerprint, ink)
        return ink
    }
}

extension WorkflowStatusInk {
    @MainActor static var cache: (fingerprint: Int, ink: WorkflowStatusInk)?
}

/// A step's status glyph, a spinner while it works.
struct WorkflowStepStatusIcon: View {
    let status: NodeRunStatus?

    @Environment(\.theme) private var theme

    var body: some View {
        switch status {
        case .running?:
            ProgressView().controlSize(.mini)
        case .done?, .pinned?:
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.statusInk.success)
        case .failed?:
            Image(systemName: "xmark.circle.fill").foregroundColor(theme.statusInk.error)
        case .awaitingUser?:
            Image(systemName: "person.crop.circle.badge.questionmark").foregroundColor(theme.statusInk.warning)
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
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: WorkflowRunStyle.icon(status))
                .glyphSize(size, weight: .semibold)
                .foregroundColor(WorkflowRunStyle.color(status, theme: theme))
        }
    }
}
