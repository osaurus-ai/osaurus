//
//  StateCallScorecard.swift
//  OsaurusEvalsKit
//

import Foundation

/// `state_call_rate` from `orchestrator` rows: turns where the model called
/// `state` by itself over turns that handled a message, per model, beside
/// the rate of turns whose state was written at all (the model's call, the
/// forced `state` step, or `SessionStateExtraction` after a turn without
/// either). A multi-turn row counts each of its turns. An errored row did
/// not handle its message and is left out of every count. The verdict is
/// on the written rate; the call rate is what the model did by itself.
public struct StateCallScorecard: Sendable {
    public struct ModelScore: Sendable, Equatable {
        public let modelId: String
        public let withState: Int
        public let written: Int
        public let handled: Int
        public var forced = 0
        public var extracted = 0

        public init(modelId: String, withState: Int, written: Int, handled: Int, forced: Int = 0, extracted: Int = 0) {
            self.modelId = modelId
            self.withState = withState
            self.written = written
            self.handled = handled
            self.forced = forced
            self.extracted = extracted
        }

        public var rate: Double { handled == 0 ? 0 : Double(withState) / Double(handled) }
        public var writtenRate: Double { handled == 0 ? 0 : Double(written) / Double(handled) }
        public var none: Int { handled - written }
    }

    public static let threshold = 0.8
    static let stateToolName = "state"
    static let summaryPrefix = "summary: toolCalls=["
    static let sourcePrefix = "state_source: "
    static let turnSourcesPrefix = "state_sources: "

    public let models: [ModelScore]

    static func calledTools(in notes: [String]) -> [String]? {
        guard let note = notes.first(where: { $0.hasPrefix(summaryPrefix) }) else { return nil }
        let rest = note.dropFirst(summaryPrefix.count)
        guard let close = rest.firstIndex(of: "]") else { return nil }
        return rest[..<close].split(separator: ",").map { String($0) }
    }

    /// `model`, `forced`, `extracted`, or `none`; nil for a report written
    /// before the source was recorded.
    static func stateSource(in notes: [String]) -> String? {
        notes.first(where: { $0.hasPrefix(sourcePrefix) }).map { String($0.dropFirst(sourcePrefix.count)) }
    }

    /// One source per turn of a multi-turn row; nil for a single-turn row.
    static func turnStateSources(in notes: [String]) -> [String]? {
        notes.first(where: { $0.hasPrefix(turnSourcesPrefix) })
            .map { $0.dropFirst(turnSourcesPrefix.count).split(separator: ",").map(String.init) }
    }

    /// `nil` when no row is a handled Orchestrator turn.
    public init?(rows: [EvalCaseReport]) {
        var tallies: [String: ModelScore] = [:]
        for row in rows where row.domain == "orchestrator" && row.outcome != .errored {
            guard let called = Self.calledTools(in: row.notes) else { continue }
            let turnSources = Self.turnStateSources(in: row.notes)
            let sources: [String?] = turnSources ?? [Self.stateSource(in: row.notes)]
            let previous = tallies[row.modelId] ?? ModelScore(modelId: row.modelId, withState: 0, written: 0, handled: 0)
            var withState = previous.withState
            var written = previous.written
            var forced = previous.forced
            var extracted = previous.extracted
            let calledState = called.contains(Self.stateToolName)
            for source in sources {
                // A multi-turn row's summary pools every turn's calls, so
                // its per-turn source alone says whether the model called.
                let calledByItself = turnSources == nil ? calledState && source != "forced" : source == "model"
                if calledByItself { withState += 1 }
                switch source {
                case "model"?: written += 1
                case "forced"?:
                    forced += 1
                    written += 1
                case "extracted"?:
                    extracted += 1
                    written += 1
                case nil where calledState: written += 1
                default: break
                }
            }
            tallies[row.modelId] = ModelScore(
                modelId: row.modelId, withState: withState, written: written,
                handled: previous.handled + sources.count, forced: forced, extracted: extracted)
        }
        guard !tallies.isEmpty else { return nil }
        models = tallies.keys.sorted().map { tallies[$0]! }
    }

    public func formatLines() -> [String] {
        var lines = ["[state_call_rate] (orchestrator rows)"]
        for score in models {
            let verdict = score.writtenRate >= Self.threshold ? "ok" : "below \(Self.threshold)"
            lines.append(
                "  \(score.modelId)  calls \(score.withState)/\(score.handled) "
                    + String(format: "%.2f", score.rate) + "  written \(score.written)/\(score.handled) "
                    + String(format: "%.2f", score.writtenRate) + "  \(verdict)"
                    + "  forced \(score.forced) extracted \(score.extracted) none \(score.none)")
        }
        return lines
    }
}
