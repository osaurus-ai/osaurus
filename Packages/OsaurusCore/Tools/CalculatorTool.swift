//
//  CalculatorTool.swift
//  osaurus
//
//  `calculate(expression)` — deterministic math. Models (especially local
//  ones) get multi-digit arithmetic, percentages, and unit-free formulas
//  wrong when they do them "in their head"; this built-in evaluates one
//  plain-text expression with `CalculatorEngine` instead. One string
//  argument, no side effects, no I/O.
//

import Foundation

public final class CalculatorTool: OsaurusTool, @unchecked Sendable {
    public static let toolName = "calculate"
    public let name = CalculatorTool.toolName
    public let description =
        "Evaluate math exactly — use it for ANY arithmetic instead of computing in your head. "
        + "Pass one `expression` in ordinary math notation, e.g. \"(1250 * 1.08) / 12\", "
        + "\"sqrt(2) * 3^4\", \"15% of 80\", \"sin(30°)\", \"log(1000)\", \"10!\". "
        + "Separate steps with `;` to use variables (\"r = 3; pi * r^2\"); "
        + "an equation with one unknown is solved (\"2x + 3 = 11\")."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "expression": .object([
                "type": .string("string"),
                "description": .string(
                    "Math to evaluate. Operators + - * / ^ and parentheses; functions such as "
                        + "sqrt, abs, round(x, digits), ln, log (base 10), log(x, base), sin/cos/tan, "
                        + "min, max, sum, mean, median, gcd, lcm, nCr; constants pi and e."
                ),
            ]),
            "angle_unit": .object([
                "type": .string("string"),
                "enum": .array([.string("radians"), .string("degrees")]),
                "description": .string("Unit for trig functions. Default radians; `30°` is always degrees."),
            ]),
        ]),
        "required": .array([.string("expression")]),
    ])

    public init() {}

    /// Cancellation audit: pure, synchronous arithmetic on the caller's
    /// string — no I/O, no awaits, no spawned work — so an owning spawned run
    /// drains it trivially.
    var canExposeToSpawnedOperation: Bool { true }

    func spawnedOperationCancellationSupport(
        argumentsJSON _: String
    ) -> SpawnedOperationCancellationSupport {
        .cooperative
    }

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let exprReq = requireString(args, "expression", expected: "a math expression string", tool: name)
        guard case .value(let expression) = exprReq else { return exprReq.failureEnvelope ?? "" }

        let unitReq = optionalString(args, "angle_unit", expected: "\"radians\" or \"degrees\"", tool: name)
        guard case .value(let unitName) = unitReq else { return unitReq.failureEnvelope ?? "" }
        var engine = CalculatorEngine()
        if let unitName, !unitName.isEmpty {
            guard let unit = CalculatorAngleUnit(rawValue: unitName.lowercased()) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`angle_unit` must be \"radians\" or \"degrees\". Got `\(unitName)`.",
                    field: "angle_unit",
                    expected: "\"radians\" or \"degrees\"",
                    tool: name
                )
            }
            engine.angleUnit = unit
        }

        let outcome: CalculatorEngine.Outcome
        do {
            outcome = try engine.evaluate(expression)
        } catch let error as CalculatorError {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: error.message,
                field: "expression",
                expected: "a math expression such as \"(3 + 4) * 2\"",
                tool: name
            )
        }
        return ToolEnvelope.success(tool: name, result: Self.payload(expression: expression, outcome: outcome))
    }

    /// `result` is always the final answer as text (exact integers stay
    /// exact, binary noise like 0.30000000000000004 is rounded away).
    static func payload(expression: String, outcome: CalculatorEngine.Outcome) -> [String: Any] {
        var result: [String: Any] = ["expression": expression]
        if let solution = outcome.solution {
            let roots = solution.roots.map { CalculatorEngine.formatRoot($0) }
            result["result"] =
                roots.count == 1
                ? "\(solution.variable) = \(roots[0])"
                : roots.map { "\(solution.variable) = \($0)" }.joined(separator: ", ")
            result["solutions"] = roots
            result["variable"] = solution.variable
            if solution.truncated {
                result["note"] = "More solutions exist; the \(roots.count) nearest to 0 are listed."
            }
        } else if let last = outcome.steps.last {
            result["result"] = CalculatorEngine.format(last)
            if last.exact == nil, last.value.isFinite, abs(last.value) >= 9.007_199_254_740_992e15, last.value == last.value.rounded() {
                result["note"] = "Beyond 2^53, so the low digits are approximate."
            }
        }
        if outcome.steps.count > 1 {
            result["steps"] = outcome.steps.enumerated().map { index, step -> String in
                if index == outcome.steps.count - 1, outcome.solution != nil, let text = result["result"] as? String {
                    return "\(step.input) → \(text)"
                }
                let value = CalculatorEngine.format(step)
                return step.assigned.map { "\(step.input) → \($0) = \(value)" } ?? "\(step.input) → \(value)"
            }
        }
        return result
    }
}
