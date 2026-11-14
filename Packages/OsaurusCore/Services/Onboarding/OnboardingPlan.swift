//
//  OnboardingPlan.swift
//  osaurus
//
//  The runtime's record of the first run, kept outside the transcript. A
//  step is complete when the runtime observes it in app state; no reply can
//  declare one done. A relaunch resumes from the stored plan.
//

import Foundation

struct OnboardingPlan: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case pending, active, done, skipped }
    struct Step: Codable, Sendable, Equatable {
        let id: String
        var status: Status
    }

    enum RequestOutcome: String, Codable, Sendable { case granted, denied }

    enum FinishReason: String, Codable, Sendable {
        /// The person sent a task, typed or an ask.
        case firstTask = "first_task"
        case dismissed
    }

    var steps: [Step]
    /// "planner", "courier", "keeper", "scout", "builder".
    var pathId: String?
    /// The chat that owns the walkthrough.
    var sessionId: UUID?
    var finishReason: FinishReason?
    /// What came of the chosen path's request.
    var requestOutcome: RequestOutcome?
    /// The ask the first task ran, when it was one.
    var firstAskId: String?
    /// Nil until the first task's run settles.
    var firstTaskSucceeded: Bool?

    /// After the first task, the team the person went back to: the card
    /// tapped and what came of its request. Kept apart from `pathId` and the
    /// first task's record, which stay as setup left them.
    struct Browse: Codable, Sendable, Equatable {
        var pathId: String?
        var requestOutcome: RequestOutcome?
        var path: OnboardingPath? { OnboardingPaths.path(id: pathId) }
    }

    var browse: Browse?
    /// A walkthrough task was sent; its run's end places the offer.
    var offerPending: Bool?
    /// The reply the offer to meet another teammate sits under.
    var offerTurnId: UUID?
    /// Done exploring: Done, Skip setup, or a message of their own.
    var doneExploring: Bool?

    init(sessionId: UUID?) {
        steps = OnboardingSteps.all.map { Step(id: $0.id, status: .pending) }
        self.sessionId = sessionId
    }

    /// Drops steps an older build stored that this one no longer has, so a
    /// resumed plan can still settle.
    mutating func dropRetiredSteps() {
        steps.removeAll { OnboardingSteps.definition(id: $0.id) == nil }
    }

    var path: OnboardingPath? { OnboardingPaths.path(id: pathId) }

    /// The step the chat is on; nil once every step is settled.
    var current: Step? { steps.first { $0.status == .active } }

    /// The walkthrough is over: a task was sent or setup dismissed.
    var isFinished: Bool { finishReason != nil }

    /// Every step is settled.
    var isComplete: Bool { steps.allSatisfy { $0.status == .done || $0.status == .skipped } }

    /// After a task, the team stays open to try until the person is done.
    var canExplore: Bool { finishReason == .firstTask && doneExploring != true }

    /// The walkthrough has let go of the window: dismissed, or done exploring.
    var isClosed: Bool { finishReason == .dismissed || doneExploring == true }

    func status(of id: String) -> Status? { steps.first { $0.id == id }?.status }

    /// Settles every step the snapshot decides, in order, and makes the
    /// first undecided one that applies active.
    mutating func advance(_ app: OnboardingAppSnapshot) {
        var activated = false
        for index in steps.indices {
            let status = steps[index].status
            guard status == .pending || status == .active,
                let definition = OnboardingSteps.definition(id: steps[index].id)
            else { continue }
            if activated {
                steps[index].status = .pending
                continue
            }
            if definition.isSatisfied(app) {
                steps[index].status = .done
            } else if definition.applies(app) {
                steps[index].status = .active
                activated = true
            } else if definition.isDecided(app) {
                steps[index].status = .skipped
            } else {
                steps[index].status = .pending
                activated = true
            }
        }
    }

    // MARK: - Moves (each is followed by `advance`)

    mutating func select(pathId: String) {
        self.pathId = pathId
        requestOutcome = nil
    }

    /// Back to the cards from a path's asks.
    mutating func back() {
        guard finishReason == nil, pathId != nil else { return }
        pathId = nil
        requestOutcome = nil
        for index in steps.indices where [OnboardingSteps.choice, OnboardingSteps.firstTask].contains(steps[index].id) {
            steps[index].status = .pending
        }
    }

    /// Skip setup: ends the walkthrough from any step.
    mutating func dismiss() {
        guard current != nil else { return }
        finish(.dismissed)
    }

    mutating func finish(_ reason: FinishReason, askId: String? = nil) {
        guard finishReason == nil else { return }
        finishReason = reason
        firstAskId = askId
        if reason == .dismissed { firstTaskSucceeded = false }
        if reason == .firstTask { offerPending = true }
    }

    // MARK: - Exploring after the first task

    /// Meet Another Teammate: the cards again.
    mutating func exploreTeam() {
        guard canExplore else { return }
        browse = Browse()
        offerTurnId = nil
    }

    mutating func browseSelect(pathId: String) {
        guard browse != nil else { return }
        browse = Browse(pathId: pathId)
    }

    /// Back to the cards from a browsed teammate's asks.
    mutating func browseBack() {
        guard browse?.pathId != nil else { return }
        browse = Browse()
    }

    /// A browsed teammate's ask was sent: its reply gets the offer again.
    mutating func browseSent() {
        browse = nil
        offerPending = true
    }

    mutating func endExploring() {
        guard canExplore else { return }
        doneExploring = true
        browse = nil
        offerPending = nil
        offerTurnId = nil
    }
}

/// What the plan's steps observe.
struct OnboardingAppSnapshot: Sendable, Equatable {
    var brain: OnboardingBrainState
    var pathId: String?
    var finishReason: OnboardingPlan.FinishReason?
    var firstTaskSucceeded: Bool?
    var requestOutcome: OnboardingPlan.RequestOutcome?

    init(plan: OnboardingPlan, brain: OnboardingBrainState) {
        self.brain = brain
        pathId = plan.pathId
        finishReason = plan.finishReason
        firstTaskSucceeded = plan.firstTaskSucceeded
        requestOutcome = plan.requestOutcome
    }

    var path: OnboardingPath? { OnboardingPaths.path(id: pathId) }
}

protocol OnboardingStepDefinition: Sendable {
    var id: String { get }
    /// Shown when true.
    func applies(_ app: OnboardingAppSnapshot) -> Bool
    /// Observed, never model-declared.
    func isSatisfied(_ app: OnboardingAppSnapshot) -> Bool
    /// `applies` can no longer become true, so the step is skipped.
    func isDecided(_ app: OnboardingAppSnapshot) -> Bool
    /// For the Onboarding agent: what to ask, and what counts as done.
    var card: String { get }
    /// Authored, used when no model can answer.
    var fallbackLine: String { get }
}

extension OnboardingStepDefinition {
    func isDecided(_ app: OnboardingAppSnapshot) -> Bool { true }
}

enum OnboardingSteps {
    static let brain = "brain"
    static let choice = "choice"
    static let firstTask = "first_task"

    static let all: [any OnboardingStepDefinition] = [BrainStep(), ChoiceStep(), FirstTaskStep()]

    static func definition(id: String) -> (any OnboardingStepDefinition)? {
        all.first { $0.id == id }
    }

    /// No brain was committed in the window: pick one first.
    struct BrainStep: OnboardingStepDefinition {
        var id: String { OnboardingSteps.brain }
        func applies(_ app: OnboardingAppSnapshot) -> Bool { app.finishReason == nil }
        func isSatisfied(_ app: OnboardingAppSnapshot) -> Bool { app.brain != .none && app.brain != .cloudConnecting }
        var card: String {
            "No model can answer in this chat yet. Point to the Choose a Model button. Done when a model can answer."
        }
        var fallbackLine: String { L("First, choose where I run: a model on this Mac, or Osaurus Cloud.") }
    }

    struct ChoiceStep: OnboardingStepDefinition {
        var id: String { OnboardingSteps.choice }
        func applies(_ app: OnboardingAppSnapshot) -> Bool { app.finishReason == nil }
        func isSatisfied(_ app: OnboardingAppSnapshot) -> Bool { app.pathId != nil }
        var card: String {
            "Ask who they want to start with. The teammate cards are under the message, and Skip setup "
                + "ends setup. Done when a card is tapped."
        }
        var fallbackLine: String { L("Who do you want to start with?") }
    }

    struct FirstTaskStep: OnboardingStepDefinition {
        var id: String { OnboardingSteps.firstTask }
        func applies(_ app: OnboardingAppSnapshot) -> Bool { app.finishReason == nil }
        func isSatisfied(_ app: OnboardingAppSnapshot) -> Bool { app.finishReason == .firstTask }
        var card: String {
            "Invite them to tap one of the asks under the message, or to type what they want done. "
                + "Done when they send a task."
        }
        var fallbackLine: String { L("Pick one of these, or ask me anything.") }
    }
}

/// The plan for this install, one JSON file beside the app's config.
@MainActor
final class OnboardingPlanStore {
    static let shared = OnboardingPlanStore()

    var fileURL: URL

    init(fileURL: URL = OsaurusPaths.config().appendingPathComponent("onboarding-plan.json")) {
        self.fileURL = fileURL
    }

    func load() -> OnboardingPlan? {
        guard let data = try? Data(contentsOf: fileURL),
            var plan = try? JSONDecoder().decode(OnboardingPlan.self, from: data)
        else { return nil }
        plan.dropRetiredSteps()
        return plan
    }

    func save(_ plan: OnboardingPlan) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
