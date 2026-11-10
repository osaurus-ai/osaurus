//
//  OnboardingTurnRouter.swift
//  osaurus
//
//  Decides what a typed message in the walkthrough is. First match wins,
//  and only the last needs a generation: step words move the plan, talk
//  about the walkthrough is the Onboarding agent's, and everything else
//  graduates to the Orchestrator. A missed handover traps a task inside
//  setup, so anything that is not plainly talk about the walkthrough
//  graduates.
//

import Foundation

enum OnboardingTurnRoute: Equatable, Sendable {
    /// Moves the plan; no generation.
    case step(OnboardingAction)
    /// Setup ends and the Orchestrator receives the message verbatim.
    case task
    /// The Onboarding agent answers within the current step.
    case reply
}

enum OnboardingTurnRouter {
    static let skipWords: Set<String> = [
        "skip", "skip it", "skip this", "skip setup", "skip for now", "later", "maybe later", "not now",
        "no thanks", "no thank you",
    ]
    static let backWords: Set<String> = ["back", "go back", "previous"]

    /// Talk about the walkthrough itself: greetings, thanks, and questions
    /// about the cards. Matched on the whole message or its opening words.
    static let talkPhrases: Set<String> = [
        "hi", "hello", "hey", "thanks", "thank you", "cool", "great", "nice", "ok", "okay", "yes", "sure", "got it",
        "i see", "no", "maybe", "hmm", "help",
        "who are you", "what are you", "what can you do", "what is this", "what is this for", "which one",
        "which one should i pick", "who should i pick", "who should i start with", "tell me more",
        "what do they do", "what does each one do", "i don t know", "not sure", "why",
    ]
    static let talkOpenings = [
        "what does ", "what do ", "who is ", "what is ", "which ", "why do ", "why does ", "can ", "does ",
    ]

    /// Words that move the plan for the step it is on.
    static func stepAction(_ text: String, plan: OnboardingPlan, team: [OnboardingOpening.Member]) -> OnboardingAction?
    {
        let phrase = normalized(text)
        guard plan.current != nil else { return nil }
        if skipWords.contains(phrase) { return .dismissSetup }
        switch plan.current?.id {
        case OnboardingSteps.choice:
            return cardId(phrase, team: team).map(OnboardingAction.selectPath)
        case OnboardingSteps.firstTask:
            return backWords.contains(phrase) ? .back : nil
        default:
            return nil
        }
    }

    /// The route for a message no step word matched.
    static func route(_ text: String, team: [OnboardingOpening.Member]) -> OnboardingTurnRoute {
        isWalkthroughTalk(text, team: team) ? .reply : .task
    }

    /// A typed personal ask's label, held like the asks while the bridge
    /// answers.
    static func readsPersonalData(_ text: String) -> Bool {
        let phrase = normalized(text)
        return OnboardingPaths.all.flatMap(\.asks).contains { $0.readsPersonalData && normalized($0.label) == phrase }
    }

    static func isWalkthroughTalk(_ text: String, team: [OnboardingOpening.Member]) -> Bool {
        let phrase = normalized(text)
        guard !phrase.isEmpty else { return false }
        if talkPhrases.contains(phrase) { return true }
        let words = phrase.split(separator: " ")
        guard words.count <= 10 else { return false }
        let names = team.map { normalized($0.name) } + Teammate.allCases.map { normalized($0.rawValue) }
        let namesATeammate = names.contains { !$0.isEmpty && " \(phrase) ".contains(" \($0) ") }
        let opensAQuestion = talkOpenings.contains { phrase.hasPrefix($0) }
        return opensAQuestion && (namesATeammate || words.count <= 5)
    }

    /// Openings a typed job may start with, longest first.
    static let jobOpenings = [
        "i need help with ", "i want help with ", "can you help with ", "help me with ", "help with ",
        "start with ", "something for ", "i want ", "i need ",
    ]
    static let jobDeterminers = ["my ", "the ", "our "]

    /// A typed card: the teammate's name, its job, or another word for the
    /// job ("help with my mail").
    static func cardId(_ phrase: String, team: [OnboardingOpening.Member]) -> String? {
        let names = Dictionary(team.map { ($0.teammate, normalized($0.name)) }, uniquingKeysWith: { first, _ in first })
        let job = jobPhrase(phrase)
        return OnboardingPaths.available(teammates: Set(names.keys)).first { path in
            let ownNames = path.teammate.map { [names[$0], normalized($0.rawValue)].compactMap { $0 } } ?? []
            let candidates = ownNames + [normalized(path.job)]
            if candidates.contains(phrase) || candidates.contains(job) { return true }
            return path.aliases.split(separator: ",").map { normalized(String($0)) }.contains(job)
        }?.id
    }

    /// The phrase without an opening ("help me with") and a determiner ("my").
    static func jobPhrase(_ phrase: String) -> String {
        var job = phrase
        if let opening = jobOpenings.first(where: { job.hasPrefix($0) }) { job.removeFirst(opening.count) }
        if let determiner = jobDeterminers.first(where: { job.hasPrefix($0) }) { job.removeFirst(determiner.count) }
        return job
    }

    /// Lowercased words without punctuation.
    static func normalized(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}
