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
    case assistant
    case writer
    case researcher
    case coder
    case productivity

    var id: String { rawValue }

    /// Curated, ordered archetype list shown in the onboarding "Meet your
    /// dino" step. Excludes `.blank` (a from-scratch option that only makes
    /// sense in the in-app editor) and leads with the general-purpose
    /// `.assistant` so a brand-new user can pick one and move on.
    static let onboardingArchetypes: [AgentStarterTemplate] =
        [.assistant, .writer, .researcher, .coder, .productivity]

    var label: String {
        switch self {
        case .blank: return L("Blank")
        case .assistant: return L("Assistant")
        case .writer: return L("Writer")
        case .researcher: return L("Researcher")
        case .coder: return L("Coder")
        case .productivity: return L("Productivity")
        }
    }

    var icon: String {
        switch self {
        case .blank: return "doc"
        case .assistant: return "sparkles"
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
        case .assistant: return L("Assistant")
        case .writer: return L("Writer")
        case .researcher: return L("Researcher")
        case .coder: return L("Coder")
        case .productivity: return L("Productivity")
        }
    }

    /// Short, friendly one-liner shown as a preview under the dino avatar in
    /// the onboarding step. Distinct from `systemPrompt` (which is the full
    /// behavior spec) — this is human-facing marketing copy.
    var tagline: String {
        switch self {
        case .blank:
            return ""
        case .assistant:
            return L("A friendly all-rounder for everyday questions and tasks.")
        case .writer:
            return L("A thoughtful partner for drafting, editing, and polishing prose.")
        case .researcher:
            return L("A careful guide for digging into topics and weighing sources.")
        case .coder:
            return L("A pragmatic pair-programmer for reading and writing code.")
        case .productivity:
            return L("A focused helper for planning, todos, and staying on track.")
        }
    }

    var systemPrompt: String {
        switch self {
        case .blank:
            return ""
        case .assistant:
            return """
                You are a friendly, capable everyday assistant. Help the user with \
                whatever they're working on — answering questions, thinking through \
                problems, drafting, and getting things done. Be clear and concise, \
                ask a quick clarifying question when intent is ambiguous, and adapt \
                your depth to what they need.
                """
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
