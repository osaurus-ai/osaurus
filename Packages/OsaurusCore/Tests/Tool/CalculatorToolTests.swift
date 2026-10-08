//
//  CalculatorToolTests.swift
//  osaurusTests
//
//  `calculate`: the expression forms models actually emit, equations, error
//  envelopes, and the registry/composer wiring every built-in carries.
//

import Foundation
import Testing

@testable import OsaurusCore

struct CalculatorEngineTests {
    private func value(_ expression: String, angle: CalculatorAngleUnit = .radians) throws -> String {
        var engine = CalculatorEngine()
        engine.angleUnit = angle
        let outcome = try engine.evaluate(expression)
        if let solution = outcome.solution {
            return solution.roots.map { CalculatorEngine.formatRoot($0) }.joined(separator: ",")
        }
        return CalculatorEngine.format(outcome.steps.last!)
    }

    @Test(arguments: [
        ("2 + 3 * 4", "14"),
        ("(2 + 3) * 4", "20"),
        ("10 / 4", "2.5"),
        ("2^10", "1024"),
        ("2**10", "1024"),
        ("2^3^2", "512"),
        ("-2^2", "-4"),
        ("(-2)^2", "4"),
        ("2^-1", "0.5"),
        ("0.1 + 0.2", "0.3"),
        ("1/3", "0.333333333333333"),
        ("7 mod 3", "1"),
        ("-7 mod 3", "2"),
        ("17 % 5", "2"),
        ("123456789 * 987654321", "121932631112635269"),
        ("20!", "2432902008176640000"),
        ("2^62 + 1", "4611686018427387905"),
        ("9007199254740993 - 1", "9007199254740992"),
        ("6 / 3 * 7", "14"),
        ("1,250,000 * 3", "3750000"),
        ("1_000 + 1", "1001"),
        ("6.02e23 / 2", "3.01e23"),
        ("0xff + 0b101", "260"),
        ("12 × 3 ÷ 4 − 1", "8"),
        ("3 · 4", "12"),
        ("$1,200 * 0.15", "180"),
    ])
    func arithmetic(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    @Test(arguments: [
        ("15% of 80", "12"),
        ("200 + 15%", "230"),
        ("200 - 10%", "180"),
        ("50%", "0.5"),
        ("2pi", "6.28318530717959"),
        ("3(4 + 5)", "27"),
        ("(1 + 2)(3 + 4)", "21"),
        ("2 sqrt(9)", "6"),
        ("√16", "4"),
        ("sqrt 16 + 1", "5"),
        ("5²", "25"),
        ("10!", "3628800"),
        ("3!^2", "36"),
        ("π", "3.14159265358979"),
        ("e^1", "2.71828182845905"),
    ])
    func modelFriendlyNotation(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    @Test(arguments: [
        ("sqrt(2) * sqrt(2)", "2"),
        ("cbrt(-27)", "-3"),
        ("(-8)^(1/3)", "-2"),
        ("root(32, 5)", "2"),
        ("abs(-4.5)", "4.5"),
        ("ln(e^3)", "3"),
        ("log(1000)", "3"),
        ("log(8, 2)", "3"),
        ("log2(1024)", "10"),
        ("exp(0)", "1"),
        ("round(2.675, 2)", "2.68"),
        ("round(-2.5)", "-3"),
        ("floor(-1.5) + ceil(1.2)", "0"),
        ("min(4, 2, 8) + max(4, 2, 8)", "10"),
        ("sum(1, 2, 3, 4)", "10"),
        ("mean(2, 4, 9)", "5"),
        ("median(5, 1, 3, 2)", "2.5"),
        ("gcd(48, 18) + lcm(4, 6)", "18"),
        ("nCr(5, 2)", "10"),
        ("choose(52, 5)", "2598960"),
        ("nPr(5, 2)", "20"),
        ("hypot(3, 4)", "5"),
        ("stdev(2, 4, 4, 4, 5, 5, 7, 9)", "2.1380899352994"),
        ("factorial(5)", "120"),
        ("sin(pi)", "0"),
        ("cos(0)", "1"),
        ("sin(30°)", "0.5"),
        ("tan(45°)", "1"),
        ("deg(pi)", "180"),
        ("atan2(1, 1)", "0.785398163397448"),
    ])
    func functions(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    @Test func degreeMode() throws {
        #expect(try value("sin(30)", angle: .degrees) == "0.5")
        #expect(try value("asin(1)", angle: .degrees) == "90")
        #expect(try value("cos(60°)", angle: .degrees) == "0.5")
    }

    @Test(arguments: [
        ("r = 3; pi * r^2", "28.2743338823081"),
        ("price = 1250\ntax = 8%\nprice + price * tax", "1350"),
        ("n = 25; n! / (n - 2)!", "600"),
        ("a = 3; b = 4; sqrt(a^2 + b^2)", "5"),
        ("principal = 10000; rate = 0.05; principal * (1 + rate/12)^(12*10)", "16470.0949769028"),
    ])
    func statementsAndVariables(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    @Test(arguments: [
        ("2x + 3 = 11", "4"),
        ("x^2 = 16", "-4,4"),
        ("x^2 - 5x + 6 = 0", "2,3"),
        ("(x - 3)^2 = 0", "3"),
        ("3^x = 81", "4"),
        ("1.05^n = 2", "14.2066990829"),
        ("y = 2; y*x = 10", "5"),
        ("x/4 + x/6 = 10", "24"),
        ("x^3 = -8", "-2"),
        ("1000 * (1 + r)^5 = 1500", "0.0844717711977"),
    ])
    func equations(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    @Test func periodicEquationIsTruncatedNearZero() throws {
        let outcome = try CalculatorEngine().evaluate("sin(x) = 0")
        let solution = try #require(outcome.solution)
        #expect(solution.truncated)
        #expect(solution.roots.count == 10)
        #expect(solution.roots.contains(0))
    }

    @Test(arguments: [
        ("1 / 0", "Division by zero"),
        ("sqrt(-1)", "not real"),
        ("log(0)", "undefined"),
        ("2 +", "ends early"),
        ("(2 + 3", "Missing `)`"),
        ("2 + 3)", "Unmatched `)`"),
        ("foo + 1", "Unknown name `foo`"),
        ("x^2 = -1", "Unable to verify"),
        ("1/x = 0", "Unable to verify"),
        ("x + y = 3", "2 unknowns"),
        ("2 + 2 = 4", "no unknown"),
        ("pi = 3", "cannot be assigned"),
        ("2 # 3", "Unexpected character"),
        ("max()", "at least 1"),
        ("", "empty"),
    ])
    func errorsExplainThemselves(_ input: String, _ fragment: String) {
        do {
            _ = try CalculatorEngine().evaluate(input)
            Issue.record("expected an error for \(input)")
        } catch let error as CalculatorError {
            #expect(error.message.contains(fragment), "\(input): \(error.message)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: [
        ("(-1)^65", "-1"),
        ("(-1)^66", "1"),
        ("(-1)^9223372036854775807", "-1"),
        ("0^65", "0"),
        ("1^9223372036854775807", "1"),
        ("(-9223372036854775807-1) mod -1", "0"),
    ])
    func exactIntegerBoundaryResults(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    @Test func minimumIntegerDivisionFallsBackWithoutTrapping() throws {
        let result = try CalculatorEngine().evaluate("(-9223372036854775807-1)/-1")
        let step = try #require(result.steps.last)
        #expect(step.exact == nil)
        #expect(step.value == 9_223_372_036_854_775_808.0)
    }

    @Test func minimumIntegerLargePowerDoesNotTakeOverflowingAbsoluteValue() throws {
        let result = try CalculatorEngine().evaluate("(-9223372036854775807-1)^65")
        let step = try #require(result.steps.last)
        #expect(step.exact == nil)
        #expect(step.value == -.infinity)
    }

    @Test(arguments: ["(-2)^1e-20", "(-2)^1e-320", "pow(-2, -1e-20)"])
    func reciprocalOutsideIntegerRangeDoesNotTrap(_ input: String) throws {
        let result = try CalculatorEngine().evaluate(input)
        #expect(try #require(result.steps.last).value.isNaN)
    }

    @Test(arguments: [
        "x^2 + 1e-12 = 0",
        "x^2 + 1e-20 = 0",
        "1e-12 * (x-3)^2 + 1e-20 = 0",
        "1e12 * (x-3)^2 + 1e-12 = 0",
    ])
    func positiveMinimumIsNotReportedAsRoot(_ expression: String) {
        do {
            _ = try CalculatorEngine().evaluate(expression)
            Issue.record("Positive minimum must not be returned as a real root")
        } catch let error as CalculatorError {
            #expect(error.message.contains("Unable to verify"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [
        ("(x-3)^2 = 0", "3"),
        ("1e-12 * (x-3)^2 = 0", "3"),
        ("(x+0.5)^2 = 0", "-0.5"),
    ])
    func representableTangentRootsRemainVerified(_ expression: String, _ expected: String) throws {
        #expect(try value(expression) == expected)
    }

    @Test func signChangeRootRetainsBisectionContract() throws {
        let outcome = try CalculatorEngine().evaluate("x^3 = 2")
        let root = try #require(outcome.solution?.roots.first)
        #expect(abs(root * root * root - 2) <= 2e-9)
    }

    @Test(arguments: [
        ("x^2 - 0.2*x + 0.01 = 0", 0.1),
        ("x^2 - 2*x*pi + pi^2 = 0", Double.pi),
        ("(x-sqrt(2))^2 = 0", 2.0.squareRoot()),
        ("(x-1/3)^2 = 0", 1.0 / 3),
    ])
    func repeatedQuadraticRootsDoNotBecomeCancellationPlateaus(_ expression: String, _ expected: Double) throws {
        let roots = try #require(CalculatorEngine().evaluate(expression).solution).roots
        #expect(roots.count == 1)
        #expect(abs(roots[0] - expected) <= expected.ulp)
    }

    @Test(arguments: [
        ("(x-0.1)*(x-0.10000001)=0", 0.1, 0.10000001),
        ("(x-1)*(x-1.0000000001)=0", 1.0, 1.0000000001),
        ("(x-1)*(x-1.0000000000001)=0", 1.0, 1.0000000000001),
        ("x^2 - 1e-30 = 0", -1e-15, 1e-15),
        ("x^2 - 1e8*x + 1 = 0", 1e-8, 1e8),
    ])
    func nearbyDistinctQuadraticRootsAreNotMerged(_ expression: String, _ first: Double, _ second: Double) throws {
        let roots = try #require(CalculatorEngine().evaluate(expression).solution).roots
        #expect(roots.count == 2)
        #expect(abs(roots[0] - first) <= abs(first).ulp * 4)
        #expect(abs(roots[1] - second) <= abs(second).ulp * 4)
        #expect(Set(CalculatorEngine.formatRoots(roots)).count == 2)
    }

    @Test(arguments: [
        ("x^2 - x^2 + 2*x = 4", "2"),
        ("x^2 = 0", "0"),
        ("x^2-x=0", "0,1"),
        ("x/4+x/6=10", "24"),
        ("1/(x-x+1)=x", "1"),
        ("(x-x+2)/(x-x+1)=x", "2"),
        ("x + 15% = 115", "100"),
        ("(1.000000000000000001 - 1)*x=1e-18", "1"),
        ("(x-1)^2*(x+2)=0", "-2,1"),
        ("(x-2)^3=0", "2"),
    ])
    func polynomialReductionPreservesEquationSemantics(_ expression: String, _ expected: String) throws {
        #expect(try value(expression) == expected)
    }

    @Test(arguments: [
        "x^2-x^2=1", "x^2-x^2=0", "0*(1/x)=1", "1/x=0",
        "(x-1)^2+1e-30=0", "x^2+1e-30=0",
    ])
    func polynomialPathDoesNotInventSolutions(_ expression: String) {
        #expect(throws: CalculatorError.self) { try CalculatorEngine().evaluate(expression) }
    }

    @Test func nonPolynomialTrigonometricSearchIsUnchanged() throws {
        let solution = try #require(CalculatorEngine().evaluate("sin(x)=0.5").solution)
        #expect(solution.truncated)
        #expect(solution.roots.count == 10)
        #expect(solution.roots.allSatisfy { abs(sin($0) - 0.5) < 1e-9 })
    }

    @Test func deepNestingFailsCleanly() {
        let input = String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)
        #expect(throws: CalculatorError.self) { try CalculatorEngine().evaluate(input) }
    }
}

struct CalculatorToolTests {
    private func run(_ args: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: args)
        let raw = try await CalculatorTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    @Test func successEnvelope() async throws {
        let dict = try await run(["expression": "(1250 * 1.08) / 12"])
        #expect(dict["tool"] as? String == "calculate")
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["result"] as? String == "112.5")
    }

    @Test func equationEnvelopeNamesTheVariable() async throws {
        let dict = try await run(["expression": "x^2 - 5x + 6 = 0"])
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["result"] as? String == "x = 2, x = 3")
        #expect(result["solutions"] as? [String] == ["2", "3"])
    }

    @Test func stepsListed() async throws {
        let dict = try await run(["expression": "r = 3; pi * r^2"])
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["steps"] as? [String] == ["r = 3 → r = 3", "pi * r^2 → 28.2743338823081"])
    }

    @Test(arguments: [
        ("2*x=4; x+1", "3"),
        ("2*x=4; y=7", "7"),
    ])
    func laterStatementReplacesSolvedEquation(_ expression: String, _ expected: String) async throws {
        let envelope = try await run(["expression": expression])
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["result"] as? String == expected)
        #expect(result["solutions"] == nil)
        #expect(result["variable"] == nil)
    }

    @Test func lastEquationStillReportsItsSolution() async throws {
        let envelope = try await run(["expression": "2*x=4; x+1; 3*z=9"])
        let result = try #require(envelope["result"] as? [String: Any])
        #expect(result["result"] as? String == "z = 3")
        #expect(result["solutions"] as? [String] == ["3"])
        #expect(result["variable"] as? String == "z")
    }

    @Test func angleUnitArgument() async throws {
        let dict = try await run(["expression": "sin(30)", "angle_unit": "degrees"])
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["result"] as? String == "0.5")
        let bad = try await run(["expression": "sin(30)", "angle_unit": "gradians"])
        #expect(bad["ok"] as? Bool == false)
    }

    @Test func failuresAreInvalidArgsOnExpression() async throws {
        let missing = try await run([:])
        #expect(missing["ok"] as? Bool == false)
        #expect(missing["kind"] as? String == "invalid_args")
        let bad = try await run(["expression": "1 / 0"])
        #expect(bad["kind"] as? String == "invalid_args")
        #expect(bad["field"] as? String == "expression")
        #expect((bad["message"] as? String)?.contains("Division by zero") == true)
    }

    @Test func schemaIsStableAndSpawnable() {
        let tool = CalculatorTool()
        #expect(tool.canExposeToSpawnedOperation)
        // A byte-stable schema keeps the tool block of the prompt prefix-cacheable.
        #expect(tool.parameters == CalculatorTool().parameters)
        #expect(tool.name == "calculate")
    }

    @MainActor
    @Test func registeredAsBuiltInAndInEveryBaseline() {
        #expect(ToolRegistry.shared.builtInToolNames.contains("calculate"))
        #expect(ToolRegistry.spawnedWorkerBaselineToolNames.contains("calculate"))
        #expect(ToolRegistry.orchestratorAllowedToolNames.contains("calculate"))
        #expect(!ToolRegistry.orchestratorExcludedToolNames.contains("calculate"))
    }
}
