//
//  SessionStateExtraction.swift
//  osaurus
//
//  The last resort for an Orchestrator turn that ended without a `state`
//  call, after the forced step: one tool-free generation on the chat's own
//  model, given the previous object and the turn, that answers with the
//  object. It never runs after Stop, a final `clarify`, or a parked
//  `awaiting_user` (the turn has nothing settled to record), and an answer
//  that is not a non-empty state object leaves the previous object marked
//  stale.
//

import Foundation

enum SessionStateExtraction {

    /// One line of the turn as the extraction sees it.
    struct Line: Sendable, Equatable {
        let speaker: String
        let text: String
    }

    static let maxTokens = 1_024
    static let timeout: TimeInterval = 90
    static let maxLines = 24
    static let maxLineCharacters = 500

    /// Same endings the forced step accepts: an answer, or the step cap.
    static func applies(interrupted: Bool, lastStepEndedOn ending: StateStepEnding?, stateWritten: Bool) -> Bool {
        guard !interrupted, !stateWritten, let ending else { return false }
        return ending == .finalText || ending == .iterationCap
    }

    static let systemPrompt = """
        You keep the session state of a chat between a user and an assistant. Reply with only \
        a JSON object with these keys: "goal" (string: what the user is trying to get done, in \
        one line), "decisions" (array of strings: choices the user made that still hold), \
        "facts" (array of strings: facts later turns need, such as names, values, and results), \
        "open_items" (array of strings: what is still to do or still unanswered). Write the \
        whole object: keep what still holds from the previous state, drop what no longer does, \
        and add what this turn changed. No other text.
        """

    static func prompt(previous: SessionState, turn: [Line]) -> String {
        let writable: [String: Any] = [
            "goal": previous.goal ?? "", "decisions": previous.decisions, "facts": previous.facts,
            "open_items": previous.openItems,
        ]
        let previousJSON =
            (try? JSONSerialization.data(withJSONObject: writable, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let lines = clipped(turn).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        return "Previous state:\n\(previousJSON)\n\nThis turn:\n\(lines)\n\nState:"
    }

    /// The first user line and the most recent lines, each clipped.
    static func clipped(_ turn: [Line]) -> [Line] {
        let lines = turn.map { line in
            Line(
                speaker: line.speaker,
                text: String(line.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLineCharacters)))
        }.filter { !$0.text.isEmpty }
        guard lines.count > maxLines, let first = lines.first else { return lines }
        return [first] + lines.suffix(maxLines - 1)
    }

    /// The object in the answer, decoded and bounded like a `state` call.
    /// Nil when the answer holds no JSON object or the object is empty.
    static func parse(_ answer: String) -> SessionState? {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
            let state = SessionState.fromModelArguments(String(text[open...close])), !state.isEmpty
        else { return nil }
        return state
    }

    /// Generate on `model`, which just served the turn, so nothing loads or
    /// is evicted. Nil on any failure.
    static func extract(previous: SessionState, turn: [Line], model: String) async -> SessionState? {
        var options: [String: ModelOptionValue] = [:]
        if let stored = ModelProfileRegistry.thinkingStoredOption(for: model, enabled: false) {
            options[stored.id] = stored.value
        }
        do {
            let answer = try await CoreModelService.shared.generate(
                prompt: prompt(previous: previous, turn: turn),
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                timeout: timeout,
                fallbackModel: model,
                intent: .background,
                modelOverride: model,
                modelOptions: options,
                purpose: "session_state")
            let state = parse(answer)
            if state == nil { print("[Osaurus][State] extraction answered without a state object") }
            return state
        } catch {
            print("[Osaurus][State] extraction failed: \(error.localizedDescription)")
            return nil
        }
    }
}