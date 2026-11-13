//
//  OnboardingOpening.swift
//  osaurus
//
//  The first chat's first message, authored, not generated: it is on
//  screen before any model has loaded, and on one path no model exists.
//

import Foundation

enum OnboardingOpening {
    /// One teammate as the opening names it.
    struct Member: Sendable, Equatable {
        let teammate: Teammate
        let name: String
        /// The agent's avatar, as the sidebar shows it.
        var avatar: String? = nil
    }

    /// Who Osaurus is, where it runs, and what it does, then the step's
    /// question: two short paragraphs, the way a person would say it.
    static func text(profile: MacProfile, brain: OnboardingBrainState) -> String {
        let hello = [L("Hi, I am Osaurus, your personal AI agent."), whereLine(brain)].joined(separator: " ")
        var next = [introLine]
        switch brain {
        case .none: next.append(OnboardingSteps.BrainStep().fallbackLine)
        case .cloudConnecting: next.append(L("You can wait a moment, or choose another model."))
        default: next.append(OnboardingSteps.ChoiceStep().fallbackLine)
        }
        return hello + "\n\n" + next.joined(separator: " ")
    }

    /// What Osaurus does, in words anyone can follow.
    static var introLine: String {
        L("Ask me a question or give me a job. I can change Osaurus settings when you ask, and when a job needs your calendar, email, or files, I pass it to a teammate who knows that one thing well.")
    }

    static func whereLine(_ brain: OnboardingBrainState) -> String {
        switch brain {
        case .local:
            return L("I am running right here, on this Mac.")
        case .bridged:
            return L("I am answering from Osaurus Cloud until your private model finishes downloading.")
        case .downloadingLocked:
            return L("Your private model is downloading. I can answer once it is ready, and you can pick a teammate now.")
        case .provider(let name):
            return String(format: L("I am running on %@."), name)
        case .cloudConnecting:
            return L("Osaurus Cloud is still connecting. I can answer as soon as it is ready.")
        case .none:
            return L("I do not have a model to run on yet.")
        }
    }

    static func teamLine(_ team: [Member]) -> String? {
        let phrases = team.map { String(format: jobFormat($0.teammate), $0.name) }
        guard !phrases.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: phrases)
        return String(format: L("Your team is ready: %@."), list)
    }

    private static func jobFormat(_ teammate: Teammate) -> String {
        switch teammate {
        case .planner: return L("%@ for your day")
        case .courier: return L("%@ for your mail")
        case .keeper: return L("%@ for your files and notes")
        case .scout: return L("%@ for finding things out")
        case .builder: return L("%@ for your code")
        }
    }
}
