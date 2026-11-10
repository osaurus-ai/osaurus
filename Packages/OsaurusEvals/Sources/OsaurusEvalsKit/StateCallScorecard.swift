//
//  StateCallScorecard.swift
//  OsaurusEvalsKit
//

import Foundation

/// `state_call_rate` from `orchestrator` rows: turns with a `state` call
/// over turns that handled a message, per model, beside the rate of turns
/// whose state was written at all (a `state` call, or
/// `SessionStateExtraction` after a turn without one). An errored row did
/// not handle its message and is left out of every count. The verdict is
/// on the written rate; the call rate is what the model did by itself.
public struct StateCallScorecard: Sendable {
    public struct ModelScore: Sendable, Equatable {
        public let modelId: String
        public let withState: Int
        public let written: Int
        public let handled: Int

        public var rate: Double { handled == 0 ? 0 : Double(withState) / Double(handled) }
        public var writtenRate: Double { handled == 0 ? 0 : Double(written) / Double(handled) }
    }

    public static let threshold = 0.8
    static let stateToolName = "state"
    static let summaryPrefix = "summary: toolCalls=["
    static let sourcePrefix = "state_source: "

    public let models: [ModelScore]

    static func calledTools(in notes: [String]) -> [String]? {
        guard let note = notes.first(where: { $0.hasPrefix(summaryPrefix) }) else { return nil }
        let rest = note.dropFirst(summaryPrefix.count)
        guard let close = rest.firstIndex(of: "]") else { return nil }
        return rest[..<close].split(separator: ",").map { String($0) }
    }

    /// `model`, `extracted`, or `none`; nil for a report written before
    /// the source was recorded.
    static func stateSource(in notes: [String]) -> String? {
        notes.first(where: { $0.hasPrefix(sourcePrefix) }).map { String($0.dropFirst(sourcePrefix.count)) }
    }

    /// `nil` when no row is a handled Orchestrator turn.
    public init?(rows: [EvalCaseReport]) {
        var tallies: [String: (withState: Int, written: Int, handled: Int)] = [:]
        for row in rows where row.domain == "orchestrator" && row.outcome != .errored {
            guard let called = Self.calledTools(in: row.notes) else { continue }
            var tally = tallies[row.modelId, default: (0, 0, 0)]
            tally.handled += 1
            let calledState = called.contains(Self.stateToolName)
            if calledState { tally.withState += 1 }
            switch Self.stateSource(in: row.notes) {
            case "model"?, "extracted"?: tally.written += 1
            case nil where calledState: tally.written += 1
            default: break
            }
            tallies[row.modelId] = tally
        }
        guard !tallies.isEmpty else { return nil }
        models = tallies.keys.sorted().map {
            let tally = tallies[$0]!
            return ModelScore(modelId: $0, withState: tally.withState, written: tally.written, handled: tally.handled)
        }
    }

    public func formatLines() -> [String] {
        var lines = ["[state_call_rate] (orchestrator rows)"]
        for score in models {
            let verdict = score.writtenRate >= Self.threshold ? "ok" : "below \(Self.threshold)"
            lines.append(
                "  \(score.modelId)  calls \(score.withState)/\(score.handled) "
                    + String(format: "%.2f", score.rate) + "  written \(score.written)/\(score.handled) "
                    + String(format: "%.2f", score.writtenRate) + "  \(verdict)")
        }
        return lines
    }
}
