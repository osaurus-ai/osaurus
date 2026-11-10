//
//  WaitNodeExecutor.swift
//  osaurus
//
//  Wait steps: pause the run for a number of seconds or until a moment,
//  both of which may be bindings. The sleep is cancellation-aware, so
//  cancelling the run ends it at once. A wait picked up after a relaunch
//  waits only what it had left. Test runs do not wait: the Architect
//  sees the step's output right away and the log says the wait was
//  skipped, so a test of a workflow with an hour-long pause finishes.
//

import Foundation

enum WaitNodeExecutor {

    /// How long the step waits, given its spec and the run's bindings.
    /// `until` in the past means no wait.
    static func duration(spec: WaitSpec, context: WorkflowNodeContext, now: Date = Date()) throws -> TimeInterval {
        if let raw = spec.seconds {
            let value = BindingRenderer.renderValue(raw, in: context.bindings)
            guard let seconds = value.numberValue ?? value.stringValue.flatMap(Double.init), !seconds.isNaN else {
                throw WorkflowNodeError.unsupported(L("`seconds` must be a number; got \(value.compactJSONString)."))
            }
            guard seconds >= 0 else { throw WorkflowNodeError.unsupported(L("`seconds` cannot be negative.")) }
            guard seconds <= WaitSpec.maximumSeconds else {
                throw WorkflowNodeError.unsupported(
                    L("`seconds` is \(seconds.clampedInt()); a wait step pauses at most \(Int(WaitSpec.maximumSeconds)) seconds."))
            }
            return seconds
        }
        if let raw = spec.until {
            let text = BindingRenderer.renderText(raw, in: context.bindings)
            guard let date = WorkflowCondition.date(.string(text)) else {
                throw WorkflowNodeError.unsupported(L("`until` must be an ISO 8601 date-time; got \"\(text)\"."))
            }
            let seconds = date.timeIntervalSince(now)
            guard seconds <= WaitSpec.maximumSeconds else {
                throw WorkflowNodeError.unsupported(
                    L("`until` is more than \(Int(WaitSpec.maximumSeconds / 86_400)) days away."))
            }
            return max(0, seconds)
        }
        throw WorkflowNodeError.unsupported(L("A wait step needs `seconds` or `until`."))
    }

    static func run(spec: WaitSpec, context: WorkflowNodeContext) async throws -> WorkflowNodeOutcome {
        let total = try duration(spec: spec, context: context)
        var logs: [String] = []
        let remaining: TimeInterval
        if context.isTest {
            remaining = 0
            if total > 0 { logs.append(L("Test run: skipped the wait of \(Self.describe(total)).")) }
        } else {
            remaining = max(0, total - context.elapsedBeforeResume)
            if context.elapsedBeforeResume > 0, remaining < total {
                logs.append(L("Picked up after a relaunch; waiting the remaining \(Self.describe(remaining))."))
            }
        }
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        let waited = context.isTest ? 0 : total
        return WorkflowNodeOutcome(
            output: .object([
                "waited_seconds": .number(waited.rounded()),
                "resumed_at": .string(ISO8601DateFormatter().string(from: Date())),
            ]),
            logs: logs)
    }

    static func describe(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return L("\(s)s") }
        if s < 5400 { return L("\(s / 60)m") }
        if s < 172_800 { return L("\(s / 3600)h") }
        return L("\(s / 86_400)d")
    }
}
