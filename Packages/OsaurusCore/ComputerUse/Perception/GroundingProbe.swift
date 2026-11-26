//
//  GroundingProbe.swift
//  OsaurusCore — Computer Use
//
//  Public entry for the `computer_use_grounding` eval lane: runs the same
//  synthetic-screen calibration a run would, against a live model (or
//  answers scripted in a given frame for the model-free lane), and reports
//  point-in-box accuracy per frame, the bundle's stated frame, and token/s.
//  It never writes the per-bundle calibration cache.
//

import Foundation

public enum ComputerUseGroundingProbe {

    public struct Screen: Sendable {
        public let width: Int
        public let height: Int
        public let label: String
        /// The model's `target.point`, or nil when it gave none.
        public let point: (x: Double, y: Double)?
        /// Frames whose reading of `point` lands on the target.
        public let hitFrames: [String]
        /// The `agent_action` arguments when they carried no point.
        public let answer: String?
    }

    public struct Report: Sendable {
        public let modelAcceptsImages: Bool
        public let frameBudget: FrameBudget
        /// The frame the bundle declares or states, if any, and where it came from.
        public let statedFrame: String?
        public let statedSource: String?
        /// Hits per frame (`pixels`, `normalized1000`, `normalizedUnit`).
        public let hits: [String: Int]
        public let trials: Int
        /// The frame calibration adopts, or nil (marks only).
        public let measuredFrame: String?
        public let screens: [Screen]
        public let decodeTokensPerSecond: [Double]
        public let errors: [String]
    }

    /// Measure `modelId`. With `scriptedFrame`, answers are synthesized at
    /// each target's center in that frame instead of calling a model.
    public static func measure(modelId: String, scriptedFrame: String? = nil) async -> Report {
        let vision = await MainActor.run { VisionContext.resolved(for: modelId) }
        let budget = vision.frameBudget
        let trials = GroundingCalibration.trials(budget: budget)
        var errors: [String] = []
        var points: [AgentPoint?] = []
        var answers: [String?] = []

        let step: ([ChatMessage]) async throws -> ComputerUseLoop.ModelStepResult
        if let scriptedFrame, let frame = GroundingProfile.CoordinateFrame(rawValue: scriptedFrame) {
            var index = 0
            step = { _ in
                defer { index += 1 }
                let trial = trials[index]
                let unit = GroundingProfile(frame: frame, source: .calibrated)
                    .pixelsPerUnit(width: Double(trial.image.width), height: Double(trial.image.height))
                let args =
                    #"{"verb":"click","target":{"point":{"x":\#(trial.box.midX / unit.x),"y":\#(trial.box.midY / unit.y)}}}"#
                return ComputerUseLoop.ModelStepResult(call: ModelActionCall(id: "scripted-\(index)", arguments: args))
            }
        } else {
            let engine = ChatEngine(
                source: ChatExecutionContext.currentSessionSource?.inferenceSource ?? .chatUI,
                activitySource: .agent,
                privacyReviewMode: .autoScrub
            )
            let sessionId = "cu-grounding-\(UUID().uuidString)"
            step = { messages in
                try await ComputerUseLoop.modelStep(
                    engine: engine,
                    modelId: modelId,
                    sessionId: sessionId,
                    messages: messages,
                    enableThinking: nil,
                    reasoningEffort: nil,
                    tool: GroundingCalibration.toolSpec
                )
            }
        }

        var speeds: [Double] = []
        for trial in trials {
            var point: AgentPoint?
            var answer: String?
            do {
                let result = try await step(GroundingCalibration.messages(for: trial))
                if let speed = result.tokensPerSecond { speeds.append(speed) }
                if let call = result.call {
                    switch AgentAction.decode(argumentsJSON: call.arguments) {
                    case .action(let action):
                        point = action.target?.point
                        if point == nil { errors.append("\(trial.label): no target.point") }
                    case .invalid(let reason):
                        errors.append("\(trial.label): \(reason)")
                    }
                    if point == nil { answer = String(call.arguments.prefix(240)) }
                } else {
                    errors.append("\(trial.label): no agent_action call")
                }
            } catch {
                errors.append("\(trial.label): \(error.localizedDescription)")
            }
            points.append(point)
            answers.append(answer)
        }

        let scored = GroundingCalibration.score(points: points, trials: trials)
        let screens = trials.indices.map { i in
            let trial = trials[i]
            return Screen(
                width: trial.image.width,
                height: trial.image.height,
                label: trial.label,
                point: points[i].map { ($0.x, $0.y) },
                hitFrames: points[i].map { p in
                    GroundingProfile.CoordinateFrame.allCases
                        .filter { GroundingCalibration.hit(p, frame: $0, trial: trial) }
                        .map(\.rawValue)
                } ?? [],
                answer: answers[i]
            )
        }
        let measured: String?
        if case .frame(let frame) = scored.outcome { measured = frame.rawValue } else { measured = nil }
        let stated = vision.grounding.flatMap { $0.source == .calibrated ? nil : $0 }
        return Report(
            modelAcceptsImages: vision.modelAcceptsImages,
            frameBudget: budget,
            statedFrame: stated?.frame.rawValue,
            statedSource: stated?.source.rawValue,
            hits: Dictionary(uniqueKeysWithValues: scored.hits.map { ($0.key.rawValue, $0.value) }),
            trials: scored.trials,
            measuredFrame: measured,
            screens: screens,
            decodeTokensPerSecond: speeds,
            errors: errors
        )
    }
}
