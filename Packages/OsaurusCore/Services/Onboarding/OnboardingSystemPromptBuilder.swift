//
//  OnboardingSystemPromptBuilder.swift
//  osaurus
//
//  The Onboarding agent's whole context: its instructions and reply rules,
//  the plan, the current step, and the last two exchanges. Nothing else
//  from the transcript reaches it, and the total stays under 3,000 tokens
//  however long the walkthrough runs. Adding a step adds a definition; the
//  instructions do not change.
//

import Foundation

enum OnboardingSystemPromptBuilder {
    static let tokenBudget = 3000
    static let exchanges = 2
    static let historyCharacters = 600
    static let messageCharacters = 2000

    static let replyRules = [
        "One step per message, and at most one question per message.",
        "Never ask for anything the setup window collected: the brain choice and the usage-data choice.",
        "Never state that a step is done; read status from the plan.",
        "Never answer a question about Osaurus or its settings from your own knowledge.",
        "Never attempt task work.",
        "Never name a tool or an agent role in a reply.",
        "Say where the chat runs only as the plan states it. Never ask the person to go offline or to change "
            + "a system setting.",
        "Keep a step message under 60 words.",
    ]

    struct Context {
        var plan: OnboardingPlan
        var location: ChatRunLocation?
        var team: [OnboardingOpening.Member]
        /// The transcript before this message, oldest first.
        var history: [ChatTurn]
        var message: String
    }

    static func build(_ context: Context) -> (system: String, prompt: String) {
        let system = systemPrompt(context)
        let message = String(context.message.prefix(messageCharacters))
        var lines = recentLines(context.history)
        func prompt() -> String {
            var text = ""
            if !lines.isEmpty { text += "Recent messages:\n" + lines.joined(separator: "\n") + "\n\n" }
            return text + "Person: \(message)\n\nReply as Osaurus."
        }
        while !lines.isEmpty, tokens(system) + tokens(prompt()) > tokenBudget {
            lines.removeFirst()
        }
        return (system, prompt())
    }

    static func tokens(_ text: String) -> Int { TokenEstimator.estimate(text) }

    private static func systemPrompt(_ context: Context) -> String {
        var parts = [
            "You are Osaurus, greeting someone on their first run. You guide a short setup and nothing else. "
                + "Speak plainly and warmly, in short sentences."
        ]
        parts.append(
            "Reply rules:\n" + replyRules.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        )
        let plan = context.plan
        let steps = plan.steps.map { "- \($0.id): \($0.status.rawValue)" }.joined(separator: "\n")
        parts.append("Plan:\n" + steps)
        var facts: [String] = []
        if let location = context.location {
            facts.append("Where this chat runs: \(location.label(tokensPerSecond: nil)).")
        }
        if let teamLine = OnboardingOpening.teamLine(context.team) { facts.append(teamLine) }
        if let path = plan.path {
            let name = path.teammate.flatMap { t in context.team.first { $0.teammate == t }?.name }
            facts.append(
                name.map { "They chose \($0): \(path.job.lowercased())." }
                    ?? (path.teammate == nil
                        ? "They chose to start with you, Osaurus, rather than a teammate."
                        : "They skipped choosing a teammate.")
            )
            if plan.requestOutcome == .denied { facts.append("macOS access for that teammate was not allowed.") }
        }
        if !facts.isEmpty { parts.append(facts.joined(separator: "\n")) }
        if let current = plan.current, let definition = OnboardingSteps.definition(id: current.id) {
            parts.append("Current step: \(current.id). \(definition.card)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The last two exchanges, as short labelled lines.
    private static func recentLines(_ history: [ChatTurn]) -> [String] {
        let spoken = history.filter { ($0.role == .user || $0.role == .assistant) && !$0.contentIsBlank }
        var lines: [String] = []
        var users = 0
        for turn in spoken.reversed() {
            let speaker = turn.role == .user ? "Person" : "Osaurus"
            let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.insert("\(speaker): \(text.prefix(historyCharacters))", at: 0)
            if turn.role == .user {
                users += 1
                if users == exchanges { break }
            }
        }
        return lines
    }
}
