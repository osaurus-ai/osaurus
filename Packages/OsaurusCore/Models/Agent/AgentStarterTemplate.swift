//
//  AgentStarterTemplate.swift
//  osaurus
//
//  Lightweight presets used by the create-agent flows (both the in-app
//  AgentEditorSheet and the onboarding "Create your agent" step). Picking
//  one prefills the system prompt and (only when the user hasn't typed yet)
//  a default name. Description, generation overrides, and visual theme are
//  intentionally NOT part of the create flow — they're all editable
//  post-creation in Configure.
//

import Foundation

enum AgentStarterTemplate: String, CaseIterable, Identifiable {
    case blank
    case writer
    case researcher
    case coder
    case productivity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: return "Blank"
        case .writer: return "Writer"
        case .researcher: return "Researcher"
        case .coder: return "Coder"
        case .productivity: return "Productivity"
        }
    }

    var icon: String {
        switch self {
        case .blank: return "doc"
        case .writer: return "pencil.line"
        case .researcher: return "magnifyingglass"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .productivity: return "checkmark.circle"
        }
    }

    /// Default name suggestion — only applied when the form's name field is
    /// still empty, so a user who started typing isn't clobbered.
    var defaultName: String {
        switch self {
        case .blank: return ""
        case .writer: return "Writer"
        case .researcher: return "Researcher"
        case .coder: return "Coder"
        case .productivity: return "Productivity"
        }
    }

    var systemPrompt: String {
        switch self {
        case .blank:
            return ""
        case .writer:
            return """
                You are a thoughtful writing partner. Help the user draft, edit, and \
                polish prose. Match their voice, suggest sharper word choices, and \
                keep edits surgical unless they ask for a rewrite. When they share a \
                draft, lead with what's working before what to change.
                """
        case .researcher:
            return """
                You are a careful research assistant. Break questions down, surface \
                what's known versus what's contested, and cite sources where you can. \
                Distinguish facts from opinions, prefer primary sources, and never \
                invent citations. When uncertain, say so plainly.
                """
        case .coder:
            return """
                You are a pragmatic coding partner. Read the user's code carefully, \
                ask clarifying questions when intent is ambiguous, and prefer minimal \
                diffs that match the surrounding style. Explain trade-offs briefly. \
                When you write code, make sure it actually compiles and runs.
                """
        case .productivity:
            return """
                You are a focused productivity assistant. Help the user plan their \
                day, capture todos, and triage what's important from what's noisy. \
                Be concise, action-oriented, and respect their time — short answers \
                beat long ones unless they ask for more.
                """
        }
    }
}
