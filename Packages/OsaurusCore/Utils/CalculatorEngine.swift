//
//  CalculatorEngine.swift
//  osaurus
//
//  Pure expression evaluator behind the `calculate` tool. Local models are
//  unreliable at multi-digit arithmetic, so the tool takes ONE plain-text
//  expression and does the math deterministically. The syntax is deliberately
//  forgiving because the caller is a model: `^` and `**`, `×` `÷` `−` `·`,
//  implicit multiplication (`2pi`, `3(4+5)`), postfix `%`, `!` and `°`,
//  `15% of 80`, top-level thousands separators (`1,250,000`), several
//  statements (`r = 3; pi r^2`), and an equation with one unknown is solved
//  numerically (`2x + 3 = 11`).
//

import Foundation

struct CalculatorError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum CalculatorAngleUnit: String, Sendable {
    case radians
    case degrees
}

struct CalculatorEngine {

    struct Step: Equatable {
        let input: String
        let value: Double
        /// Exact integer value when the statement was pure integer arithmetic.
        var exact: Int64? = nil
        /// Set when the statement was an assignment (`r = 3`).
        let assigned: String?
    }

    struct Solution: Equatable {
        let variable: String
        let roots: [Double]
        /// More roots exist in the scanned range than were returned.
        let truncated: Bool
    }

    struct Outcome: Equatable {
        var steps: [Step] = []
        var variables: [String: Double] = [:]
        var exactVariables: [String: Int64] = [:]
        var solution: Solution?
    }

    var angleUnit: CalculatorAngleUnit = .radians

    // MARK: - Public entry

    func evaluate(_ source: String) throws -> Outcome {
        let statements = Self.splitStatements(source)
        guard !statements.isEmpty else { throw CalculatorError("Expression is empty.") }
        var outcome = Outcome()
        for statement in statements {
            let tokens = try Tokenizer.tokenize(statement)
            var parser = Parser(tokens: tokens)
            let parsed = try parser.parseStatement()
            switch parsed {
            case .expression(let node):
                let unknowns = node.freeVariables.subtracting(outcome.variables.keys)
                if let name = unknowns.sorted().first {
                    throw CalculatorError(
                        "Unknown name `\(name)` in `\(statement)`. Assign it first (`\(name) = 5; …`), "
                            + "or write an equation with `=` to solve for it.")
                }
                let value = try node.evaluate(variables: outcome.variables, angle: angleUnit)
                outcome.steps.append(
                    Step(input: statement, value: value, exact: node.exactInteger(outcome.exactVariables), assigned: nil))
            case .equation(let lhs, let rhs):
                let lhsName: String? = { if case .variable(let n) = lhs { return n } else { return nil } }()
                let rhsUnknowns = rhs.freeVariables.subtracting(outcome.variables.keys)
                if let name = lhsName, rhsUnknowns.isEmpty, !rhs.freeVariables.contains(name) {
                    guard !Self.isReserved(name) else {
                        throw CalculatorError("`\(name)` is a built-in constant or function and cannot be assigned.")
                    }
                    let value = try rhs.evaluate(variables: outcome.variables, angle: angleUnit)
                    let exact = rhs.exactInteger(outcome.exactVariables)
                    outcome.variables[name] = value
                    outcome.exactVariables[name] = exact
                    outcome.steps.append(Step(input: statement, value: value, exact: exact, assigned: name))
                    continue
                }
                let unknowns = lhs.freeVariables.union(rhs.freeVariables).subtracting(outcome.variables.keys)
                guard unknowns.count == 1, let variable = unknowns.first else {
                    if unknowns.isEmpty {
                        let l = try lhs.evaluate(variables: outcome.variables, angle: angleUnit)
                        let r = try rhs.evaluate(variables: outcome.variables, angle: angleUnit)
                        throw CalculatorError(
                            "`\(statement)` has no unknown to solve for (left = \(Self.format(l)), "
                                + "right = \(Self.format(r))). Use `=` only to assign or to solve.")
                    }
                    throw CalculatorError(
                        "`\(statement)` has \(unknowns.count) unknowns (\(unknowns.sorted().joined(separator: ", "))). "
                            + "Give values for all but one, e.g. `y = 2; \(statement)`.")
                }
                let solution = try Solver.solve(
                    lhs: lhs, rhs: rhs, variable: variable, bound: outcome.variables, angle: angleUnit)
                outcome.solution = solution
                if solution.roots.count == 1 {
                    outcome.variables[variable] = solution.roots[0]
                    outcome.exactVariables[variable] = nil
                }
                outcome.steps.append(Step(input: statement, value: solution.roots.first ?? .nan, assigned: variable))
            }
        }
        return outcome
    }

    // MARK: - Formatting

    /// Rounds away binary noise (`0.1 + 0.2` → `0.3`) at 15 significant digits.
    static func clean(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return value }
        return Double(String(format: "%.15g", value)) ?? value
    }

    static func format(_ step: Step) -> String {
        step.exact.map { String($0) } ?? format(step.value)
    }

    /// A numerically solved root is only as precise as the equation's own
    /// rounding, so it is shown at 12 significant digits, not 15.
    static func formatRoot(_ value: Double) -> String {
        guard value.isFinite, value != 0 else { return format(value) }
        return format(Double(String(format: "%.12g", value)) ?? value)
    }

    static func format(_ value: Double, decimals: Int? = nil) -> String {
        if value.isNaN { return "undefined" }
        if value.isInfinite { return value > 0 ? "infinity" : "-infinity" }
        var v = clean(value)
        if let decimals {
            let scale = pow(10.0, Double(decimals))
            if (v * scale).isFinite { v = (v * scale).rounded() / scale }
        }
        if v == v.rounded(), abs(v) < 1e15 {
            return String(Int64(v))
        }
        if let decimals, abs(v) < 1e15, abs(v) >= 1e-4 {
            return String(format: "%.\(decimals)f", v)
        }
        var text = String(format: "%.15g", v)
        if text.contains("e") {
            // 1.2345e+20 → 1.2345e20 (plainer for a model to restate).
            text = text.replacingOccurrences(of: "e+", with: "e")
        }
        return text
    }

    // MARK: - Statements

    /// Splits on `;` and newlines. Kept separate from tokenizing so an error
    /// can name the statement it came from.
    static func splitStatements(_ source: String) -> [String] {
        source.split(whereSeparator: { $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static let constants: [String: Double] = [
        "pi": .pi, "π": .pi, "tau": 2 * .pi, "τ": 2 * .pi, "e": M_E,
        "phi": (1 + 5.0.squareRoot()) / 2, "φ": (1 + 5.0.squareRoot()) / 2,
        "inf": .infinity, "infinity": .infinity, "∞": .infinity,
    ]

    static func isReserved(_ name: String) -> Bool {
        constants[name.lowercased()] != nil || Functions.table[name.lowercased()] != nil
            || ["of", "mod"].contains(name.lowercased())
    }
}

// MARK: - Tokens

enum CalculatorToken: Equatable {
    case number(Double)
    /// Integer literal kept exact (Double loses digits past 2^53).
    case integer(Int64)
    case identifier(String)
    case op(String)
    case leftParen
    case rightParen
    case comma
}

private enum Tokenizer {
    static func tokenize(_ text: String) throws -> [CalculatorToken] {
        var tokens: [CalculatorToken] = []
        let chars = Array(text)
        var i = 0
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber && c.isASCII || (c == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                let (value, exact, next) = try number(chars, from: i, topLevel: depth == 0)
                tokens.append(exact.map { .integer($0) } ?? .number(value))
                i = next
                continue
            }
            let greek: Set<Character> = ["π", "τ", "φ", "∞"]
            if greek.contains(c) {
                // Greek constants are single-character names: `2π`, `πr`.
                tokens.append(.identifier(String(c)))
                i += 1
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                var name = ""
                while j < chars.count, !greek.contains(chars[j]),
                    chars[j].isLetter || chars[j] == "_" || (chars[j].isASCII && chars[j].isNumber)
                {
                    name.append(chars[j])
                    j += 1
                }
                tokens.append(.identifier(name))
                i = j
                continue
            }
            switch c {
            case "(", "[", "{": tokens.append(.leftParen); depth += 1
            case ")", "]", "}": tokens.append(.rightParen); depth -= 1
            case ",": tokens.append(.comma)
            case "+": tokens.append(.op("+"))
            case "-", "−", "–": tokens.append(.op("-"))
            case "*", "×", "·", "⋅":
                if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                    tokens.append(.op("^"))
                    i += 1
                } else {
                    tokens.append(.op("*"))
                }
            case "/", "÷", "∕": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "%": tokens.append(.op("%"))
            case "!": tokens.append(.op("!"))
            case "°": tokens.append(.op("°"))
            case "=":
                tokens.append(.op("="))
                if i + 1 < chars.count, chars[i + 1] == "=" { i += 1 }
            case "√": tokens.append(.identifier("sqrt"))
            case "∛": tokens.append(.identifier("cbrt"))
            case "²": tokens.append(.op("^")); tokens.append(.number(2))
            case "³": tokens.append(.op("^")); tokens.append(.number(3))
            case "$", "€", "£", "¥": break  // currency marks carry no math
            default:
                throw CalculatorError("Unexpected character `\(c)`. Use + - * / ^ ( ) and function names like sqrt(…).")
            }
            i += 1
        }
        guard depth == 0 else {
            throw CalculatorError(depth > 0 ? "Missing `)`." : "Unmatched `)`.")
        }
        return tokens
    }

    /// Decimal, scientific (`6.02e23`), hex/binary/octal (`0xff`), digit
    /// separators (`1_000`), and — outside any parentheses, where a comma
    /// cannot be an argument separator — thousands groups (`1,250,000`).
    static func number(_ chars: [Character], from start: Int, topLevel: Bool) throws -> (Double, Int64?, Int) {
        var i = start
        if chars[i] == "0", i + 1 < chars.count, let radix = ["x": 16, "X": 16, "b": 2, "B": 2, "o": 8, "O": 8][chars[i + 1]] {
            var j = i + 2
            var digits = ""
            while j < chars.count, chars[j].isHexDigit || chars[j] == "_" {
                if chars[j] != "_" { digits.append(chars[j]) }
                j += 1
            }
            guard !digits.isEmpty, let value = UInt64(digits, radix: radix) else {
                throw CalculatorError("Invalid base-\(radix) number starting at `\(String(chars[start..<min(j, chars.count)]))`.")
            }
            return (Double(value), Int64(exactly: value), j)
        }
        var text = ""
        var sawDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isASCII && c.isNumber {
                text.append(c)
            } else if c == "_" {
                // digit separator
            } else if c == ".", !sawDot {
                sawDot = true
                text.append(c)
            } else if c == ",", topLevel, !sawDot,
                (1...3).allSatisfy({ i + $0 < chars.count && chars[i + $0].isASCII && chars[i + $0].isNumber }),
                i + 4 >= chars.count || !(chars[i + 4].isASCII && chars[i + 4].isNumber)
            {
                // thousands group: exactly three digits follow
            } else {
                break
            }
            i += 1
        }
        // Exponent: `e`/`E` followed by digits (optionally signed). `2e` alone is 2·e.
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                text.append("e")
                text.append(contentsOf: String(chars[(i + 1)..<j]))
                while j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    text.append(chars[j])
                    j += 1
                }
                i = j
            }
        }
        guard let value = Double(text) else { throw CalculatorError("Invalid number `\(text)`.") }
        return (value, text.allSatisfy(\.isNumber) ? Int64(text) : nil, i)
    }
}

// MARK: - AST

indirect enum CalculatorNode: Equatable {
    case number(Double)
    case integer(Int64)
    case variable(String)
    case negate(CalculatorNode)
    case binary(String, CalculatorNode, CalculatorNode)
    case percent(CalculatorNode)
    case factorial(CalculatorNode)
    case degrees(CalculatorNode)
    case call(String, [CalculatorNode])

    var freeVariables: Set<String> {
        switch self {
        case .number, .integer: return []
        case .variable(let name):
            return CalculatorEngine.constants[name.lowercased()] == nil ? [name] : []
        case .negate(let n), .percent(let n), .factorial(let n), .degrees(let n): return n.freeVariables
        case .binary(_, let l, let r): return l.freeVariables.union(r.freeVariables)
        case .call(_, let args): return args.reduce(into: Set<String>()) { $0.formUnion($1.freeVariables) }
        }
    }

    /// Exact 64-bit integer value when the subtree is integer arithmetic that
    /// neither overflows nor divides unevenly; nil means "use the Double".
    /// Keeps `123456789 * 987654321` and `20!` exact to the last digit.
    func exactInteger(_ variables: [String: Int64]) -> Int64? {
        switch self {
        case .integer(let v):
            return v
        case .number(let v):
            return v == v.rounded() && Swift.abs(v) <= 9_007_199_254_740_992 ? Int64(v) : nil
        case .variable(let name):
            return variables[name]
        case .negate(let n):
            guard let a = n.exactInteger(variables) else { return nil }
            let (r, o) = a.multipliedReportingOverflow(by: -1)
            return o ? nil : r
        case .factorial(let n):
            guard let a = n.exactInteger(variables), (0...20).contains(a) else { return nil }
            return a < 2 ? 1 : (2...a).reduce(1, *)
        case .binary(let op, let lhs, let rhs):
            if case .percent = rhs { return nil }
            guard let a = lhs.exactInteger(variables), let b = rhs.exactInteger(variables) else { return nil }
            switch op {
            case "+": let (r, o) = a.addingReportingOverflow(b); return o ? nil : r
            case "-": let (r, o) = a.subtractingReportingOverflow(b); return o ? nil : r
            case "*": let (r, o) = a.multipliedReportingOverflow(by: b); return o ? nil : r
            case "/": return b != 0 && a % b == 0 ? a / b : nil
            case "mod":
                guard b != 0 else { return nil }
                let r = a % b
                return r != 0 && (r < 0) != (b < 0) ? r + b : r
            case "^":
                guard b >= 0, b <= 64 || Swift.abs(a) <= 1 else { return nil }
                var result: Int64 = 1
                for _ in 0..<Swift.min(b, 64) {
                    let (r, o) = result.multipliedReportingOverflow(by: a)
                    if o { return nil }
                    result = r
                }
                return result
            default: return nil
            }
        case .call(let name, let argNodes):
            guard ["abs", "min", "max", "sum", "product"].contains(name) else { return nil }
            var args: [Int64] = []
            for node in argNodes {
                guard let v = node.exactInteger(variables) else { return nil }
                args.append(v)
            }
            switch name {
            case "abs": return args[0] == .min ? nil : Swift.abs(args[0])
            case "min": return args.min()
            case "max": return args.max()
            case "sum":
                var acc: Int64 = 0
                for v in args { let (r, o) = acc.addingReportingOverflow(v); if o { return nil }; acc = r }
                return acc
            default:
                var acc: Int64 = 1
                for v in args { let (r, o) = acc.multipliedReportingOverflow(by: v); if o { return nil }; acc = r }
                return acc
            }
        case .percent, .degrees:
            return nil
        }
    }

    func evaluate(variables: [String: Double], angle: CalculatorAngleUnit) throws -> Double {
        switch self {
        case .number(let v):
            return v
        case .integer(let v):
            return Double(v)
        case .variable(let name):
            if let v = variables[name] { return v }
            if let c = CalculatorEngine.constants[name.lowercased()] { return c }
            throw CalculatorError("Unknown name `\(name)`.")
        case .negate(let n):
            return -(try n.evaluate(variables: variables, angle: angle))
        case .percent(let n):
            return try n.evaluate(variables: variables, angle: angle) / 100
        case .degrees(let n):
            // `30°` is always degrees, whatever `angle_unit` says.
            let v = try n.evaluate(variables: variables, angle: angle)
            return angle == .degrees ? v : v * .pi / 180
        case .factorial(let n):
            return try Functions.factorial(n.evaluate(variables: variables, angle: angle))
        case .binary(let op, let lhs, let rhs):
            let a = try lhs.evaluate(variables: variables, angle: angle)
            // `200 + 15%` means 200 · 1.15, as on every desk calculator.
            if op == "+" || op == "-", case .percent = rhs {
                let p = try rhs.evaluate(variables: variables, angle: angle)
                return op == "+" ? a * (1 + p) : a * (1 - p)
            }
            let b = try rhs.evaluate(variables: variables, angle: angle)
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/":
                guard b != 0 else { throw CalculatorError("Division by zero.") }
                return a / b
            case "mod":
                guard b != 0 else { throw CalculatorError("Modulo by zero.") }
                let r = a.truncatingRemainder(dividingBy: b)
                return r != 0 && (r < 0) != (b < 0) ? r + b : r
            case "^":
                return Functions.power(a, b)
            default:
                throw CalculatorError("Unknown operator `\(op)`.")
            }
        case .call(let name, let argNodes):
            let args = try argNodes.map { try $0.evaluate(variables: variables, angle: angle) }
            return try Functions.call(name, args, angle: angle)
        }
    }
}

// MARK: - Parser

private struct Parser {
    enum Statement {
        case expression(CalculatorNode)
        case equation(CalculatorNode, CalculatorNode)
    }

    let tokens: [CalculatorToken]
    var index = 0
    var depth = 0

    init(tokens: [CalculatorToken]) { self.tokens = tokens }

    var current: CalculatorToken? { index < tokens.count ? tokens[index] : nil }
    func peek(_ offset: Int) -> CalculatorToken? { index + offset < tokens.count ? tokens[index + offset] : nil }

    mutating func parseStatement() throws -> Statement {
        let lhs = try parseExpression()
        if current == .op("=") {
            index += 1
            let rhs = try parseExpression()
            try expectEnd()
            return .equation(lhs, rhs)
        }
        try expectEnd()
        return .expression(lhs)
    }

    func expectEnd() throws {
        guard let token = current else { return }
        throw CalculatorError("Unexpected \(Self.describe(token)) — check for a missing operator or a stray symbol.")
    }

    static func describe(_ token: CalculatorToken) -> String {
        switch token {
        case .number(let v): return "number `\(CalculatorEngine.format(v))`"
        case .integer(let v): return "number `\(v)`"
        case .identifier(let s): return "name `\(s)`"
        case .op(let s): return "`\(s)`"
        case .leftParen: return "`(`"
        case .rightParen: return "`)`"
        case .comma: return "`,`"
        }
    }

    // expression := term (('+' | '-') term)*
    mutating func parseExpression() throws -> CalculatorNode {
        try enter()
        defer { depth -= 1 }
        var node = try parseTerm()
        while let token = current, token == .op("+") || token == .op("-") {
            index += 1
            guard case .op(let op) = token else { break }
            node = .binary(op, node, try parseTerm())
        }
        return node
    }

    // term := unary (('*' | '/' | 'mod' | '%' | 'of' | implicit) unary)*
    mutating func parseTerm() throws -> CalculatorNode {
        var node = try parseUnary()
        while let token = current {
            switch token {
            case .op("*"), .op("/"):
                index += 1
                guard case .op(let op) = token else { break }
                node = .binary(op, node, try parseUnary())
            case .op("%"):
                // Reached only when `%` was NOT consumed as a postfix percent,
                // i.e. an operand follows: binary modulo.
                index += 1
                node = .binary("mod", node, try parseUnary())
            case .identifier(let word) where word.lowercased() == "mod":
                index += 1
                node = .binary("mod", node, try parseUnary())
            case .identifier(let word) where word.lowercased() == "of":
                index += 1
                node = .binary("*", node, try parseUnary())
            case .number, .integer, .identifier, .leftParen:
                // Implicit multiplication: `2pi`, `3(4+5)`, `(1+2)(3+4)`, `2 sqrt(9)`.
                node = .binary("*", node, try parsePower())
            default:
                return node
            }
        }
        return node
    }

    // unary := ('-' | '+') unary | power      (so -2^2 = -4)
    /// Recursion bound for parentheses and sign chains, so a pathological
    /// input is an error instead of a stack overflow.
    mutating func enter() throws {
        depth += 1
        guard depth <= 128 else { throw CalculatorError("Expression is nested too deeply.") }
    }

    mutating func parseUnary() throws -> CalculatorNode {
        try enter()
        defer { depth -= 1 }
        if current == .op("-") {
            index += 1
            return .negate(try parseUnary())
        }
        if current == .op("+") {
            index += 1
            return try parseUnary()
        }
        return try parsePower()
    }

    // power := postfix ('^' unary)?           (right-associative; 2^-1 works)
    mutating func parsePower() throws -> CalculatorNode {
        let base = try parsePostfix()
        if current == .op("^") {
            index += 1
            return .binary("^", base, try parseUnary())
        }
        return base
    }

    // postfix := primary ('!' | '%' | '°')*
    mutating func parsePostfix() throws -> CalculatorNode {
        var node = try parsePrimary()
        while let token = current {
            if token == .op("!") {
                index += 1
                node = .factorial(node)
            } else if token == .op("°") {
                index += 1
                node = .degrees(node)
            } else if token == .op("%"), !startsOperand(peek(1)) {
                index += 1
                node = .percent(node)
            } else {
                break
            }
        }
        return node
    }

    func startsOperand(_ token: CalculatorToken?) -> Bool {
        switch token {
        case .number, .integer, .leftParen: return true
        case .identifier(let word): return word.lowercased() != "of" && word.lowercased() != "mod"
        default: return false
        }
    }

    mutating func parsePrimary() throws -> CalculatorNode {
        guard let token = current else { throw CalculatorError("Expression ends early — an operand is missing.") }
        switch token {
        case .number(let v):
            index += 1
            return .number(v)
        case .integer(let v):
            index += 1
            return .integer(v)
        case .leftParen:
            index += 1
            let inner = try parseExpression()
            guard current == .rightParen else { throw CalculatorError("Missing `)`.") }
            index += 1
            return inner
        case .identifier(let name):
            index += 1
            let lower = name.lowercased()
            guard Functions.table[lower] != nil else { return .variable(name) }
            if current == .leftParen {
                index += 1
                var args: [CalculatorNode] = []
                if current != .rightParen {
                    args.append(try parseExpression())
                    while current == .comma {
                        index += 1
                        args.append(try parseExpression())
                    }
                }
                guard current == .rightParen else { throw CalculatorError("Missing `)` after arguments to \(name).") }
                index += 1
                return .call(lower, args)
            }
            // `sqrt 16`, `sin 30°`, `ln x`
            return .call(lower, [try parsePower()])
        default:
            throw CalculatorError("Unexpected \(Self.describe(token)).")
        }
    }
}

// MARK: - Functions

enum Functions {
    /// name → allowed argument counts (nil upper bound = variadic).
    static let table: [String: (min: Int, max: Int?)] = {
        var t: [String: (Int, Int?)] = [:]
        for name in [
            "sqrt", "cbrt", "abs", "exp", "ln", "log2", "log10", "sin", "cos", "tan", "sec", "csc", "cot",
            "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
            "floor", "ceil", "trunc", "sign", "sgn", "factorial", "fact", "gamma", "deg", "rad", "todeg", "torad",
        ] {
            t[name] = (1, 1)
        }
        t["log"] = (1, 2)
        t["round"] = (1, 2)
        t["root"] = (2, 2)
        t["pow"] = (2, 2)
        t["atan2"] = (2, 2)
        t["mod"] = (2, 2)
        for name in ["ncr", "choose", "comb", "binomial", "npr", "perm"] { t[name] = (2, 2) }
        for name in ["min", "max", "sum", "mean", "avg", "average", "median", "gcd", "lcm", "hypot", "product", "stdev", "std", "variance", "var"] {
            t[name] = (1, nil)
        }
        return t
    }()

    static func call(_ name: String, _ args: [Double], angle: CalculatorAngleUnit) throws -> Double {
        guard let arity = table[name] else { throw CalculatorError("Unknown function `\(name)`.") }
        guard args.count >= arity.min, arity.max.map({ args.count <= $0 }) ?? true else {
            let expected = arity.max == nil ? "at least \(arity.min)" : (arity.min == arity.max ? "\(arity.min)" : "\(arity.min)–\(arity.max!)")
            throw CalculatorError("\(name) takes \(expected) argument(s), got \(args.count).")
        }
        let x = args.first ?? .nan
        let toRad: (Double) -> Double = { angle == .degrees ? $0 * .pi / 180 : $0 }
        let fromRad: (Double) -> Double = { angle == .degrees ? $0 * 180 / .pi : $0 }
        switch name {
        case "sqrt":
            guard x >= 0 else { throw CalculatorError("sqrt of a negative number (\(CalculatorEngine.format(x))) is not real.") }
            return x.squareRoot()
        case "cbrt": return Foundation.cbrt(x)
        case "abs": return Swift.abs(x)
        case "exp": return Foundation.exp(x)
        case "ln": return try logarithm(x, base: M_E)
        case "log10": return try logarithm(x, base: 10)
        case "log2": return try logarithm(x, base: 2)
        case "log": return try logarithm(x, base: args.count == 2 ? args[1] : 10)
        case "sin": return snap(Foundation.sin(toRad(x)))
        case "cos": return snap(Foundation.cos(toRad(x)))
        case "tan":
            let c = snap(Foundation.cos(toRad(x)))
            guard c != 0 else { throw CalculatorError("tan is undefined at \(CalculatorEngine.format(x)).") }
            return snap(Foundation.sin(toRad(x))) / c
        case "sec":
            let c = snap(Foundation.cos(toRad(x)))
            guard c != 0 else { throw CalculatorError("sec is undefined at \(CalculatorEngine.format(x)).") }
            return 1 / c
        case "csc":
            let s = snap(Foundation.sin(toRad(x)))
            guard s != 0 else { throw CalculatorError("csc is undefined at \(CalculatorEngine.format(x)).") }
            return 1 / s
        case "cot":
            let s = snap(Foundation.sin(toRad(x)))
            guard s != 0 else { throw CalculatorError("cot is undefined at \(CalculatorEngine.format(x)).") }
            return snap(Foundation.cos(toRad(x))) / s
        case "asin", "arcsin":
            guard (-1...1).contains(x) else { throw CalculatorError("asin needs a value in [-1, 1].") }
            return fromRad(Foundation.asin(x))
        case "acos", "arccos":
            guard (-1...1).contains(x) else { throw CalculatorError("acos needs a value in [-1, 1].") }
            return fromRad(Foundation.acos(x))
        case "atan", "arctan": return fromRad(Foundation.atan(x))
        case "atan2": return fromRad(Foundation.atan2(args[0], args[1]))
        case "sinh": return Foundation.sinh(x)
        case "cosh": return Foundation.cosh(x)
        case "tanh": return Foundation.tanh(x)
        case "asinh": return Foundation.asinh(x)
        case "acosh": return Foundation.acosh(x)
        case "atanh": return Foundation.atanh(x)
        case "floor": return Foundation.floor(x)
        case "ceil": return Foundation.ceil(x)
        case "trunc": return Foundation.trunc(x)
        case "round":
            guard args.count == 2 else { return x.rounded(.toNearestOrAwayFromZero) }
            let scale = Foundation.pow(10, args[1].rounded())
            return (CalculatorEngine.clean(x) * scale).rounded(.toNearestOrAwayFromZero) / scale
        case "sign", "sgn": return x > 0 ? 1 : (x < 0 ? -1 : 0)
        case "factorial", "fact": return try factorial(x)
        case "gamma": return Foundation.tgamma(x)
        case "deg", "todeg": return x * 180 / .pi
        case "rad", "torad": return x * .pi / 180
        case "root":
            let n = args[1]
            guard n != 0 else { throw CalculatorError("root degree cannot be 0.") }
            if x < 0, n.truncatingRemainder(dividingBy: 2) == 1 || n.truncatingRemainder(dividingBy: 2) == -1 {
                return -Foundation.pow(-x, 1 / n)
            }
            guard x >= 0 else { throw CalculatorError("Even root of a negative number is not real.") }
            return Foundation.pow(x, 1 / n)
        case "pow": return power(args[0], args[1])
        case "mod":
            guard args[1] != 0 else { throw CalculatorError("Modulo by zero.") }
            let r = args[0].truncatingRemainder(dividingBy: args[1])
            return r != 0 && (r < 0) != (args[1] < 0) ? r + args[1] : r
        case "ncr", "choose", "comb", "binomial":
            let (n, k) = try nonNegativeIntegers(name, args[0], args[1])
            guard k <= n else { return 0 }
            let k2 = min(k, n - k)
            var result = 1.0
            if k2 > 0 {
                for i in 1...k2 { result = result * Double(n - k2 + i) / Double(i) }
            }
            return result.rounded()
        case "npr", "perm":
            let (n, k) = try nonNegativeIntegers(name, args[0], args[1])
            guard k <= n else { return 0 }
            var result = 1.0
            if k > 0 {
                for i in 0..<k { result *= Double(n - i) }
            }
            return result
        case "min": return args.min()!
        case "max": return args.max()!
        case "sum": return args.reduce(0, +)
        case "product": return args.reduce(1, *)
        case "mean", "avg", "average": return args.reduce(0, +) / Double(args.count)
        case "median":
            let s = args.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        case "variance", "var", "stdev", "std":
            // Sample statistics (n − 1), matching spreadsheets' STDEV/VAR.
            guard args.count >= 2 else { throw CalculatorError("\(name) needs at least 2 values.") }
            let mean = args.reduce(0, +) / Double(args.count)
            let v = args.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(args.count - 1)
            return name.hasPrefix("var") ? v : v.squareRoot()
        case "hypot": return args.reduce(0) { $0 + $1 * $1 }.squareRoot()
        case "gcd", "lcm":
            var acc = try integer(name, args[0])
            for a in args.dropFirst() {
                let b = try integer(name, a)
                if name == "gcd" {
                    acc = gcd(acc, b)
                } else {
                    let g = gcd(acc, b)
                    guard g != 0 else { acc = 0; continue }
                    let (product, overflow) = (Swift.abs(acc) / g).multipliedReportingOverflow(by: Swift.abs(b))
                    guard !overflow else { throw CalculatorError("lcm overflows 64-bit integers.") }
                    acc = product
                }
            }
            return Double(Swift.abs(acc))
        default:
            throw CalculatorError("Unknown function `\(name)`.")
        }
    }

    /// sin(π) is 1.2e-16 in binary; report it as the 0 a person expects.
    static func snap(_ v: Double) -> Double { Swift.abs(v) < 1e-14 ? 0 : v }

    static func power(_ a: Double, _ b: Double) -> Double {
        // Real odd roots of negatives: (-8)^(1/3) = -2.
        if a < 0, b != b.rounded() {
            let inverse = 1 / b
            if inverse == inverse.rounded(), Int64(inverse) % 2 != 0 {
                return -Foundation.pow(-a, b)
            }
        }
        return Foundation.pow(a, b)
    }

    static func logarithm(_ x: Double, base: Double) throws -> Double {
        guard x > 0 else { throw CalculatorError("log of a non-positive number (\(CalculatorEngine.format(x))) is undefined.") }
        guard base > 0, base != 1 else { throw CalculatorError("log base must be positive and not 1.") }
        if base == 10 { return Foundation.log10(x) }
        if base == 2 { return Foundation.log2(x) }
        return Foundation.log(x) / Foundation.log(base)
    }

    static func factorial(_ x: Double) throws -> Double {
        guard x >= 0 else { throw CalculatorError("factorial of a negative number is undefined.") }
        guard x == x.rounded() else { return Foundation.tgamma(x + 1) }
        guard x <= 170 else { return .infinity }
        var result = 1.0
        var i = 2.0
        while i <= x { result *= i; i += 1 }
        return result
    }

    static func integer(_ name: String, _ x: Double) throws -> Int64 {
        guard x == x.rounded(), Swift.abs(x) < 9.2e18 else { throw CalculatorError("\(name) needs whole numbers.") }
        return Int64(x)
    }

    static func nonNegativeIntegers(_ name: String, _ a: Double, _ b: Double) throws -> (Int, Int) {
        let n = try integer(name, a)
        let k = try integer(name, b)
        guard n >= 0, k >= 0, n < 1_000_000 else { throw CalculatorError("\(name) needs non-negative whole numbers.") }
        return (Int(n), Int(k))
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (x, y) = (Swift.abs(a), Swift.abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

// MARK: - Solver

/// Real roots of `lhs = rhs` in one unknown: sign changes on a dense grid
/// (linear around 0, logarithmic out to 1e12) refined by bisection, plus
/// tangent roots (`(x-3)^2 = 0`) found as near-zero local minima of |f|. Every
/// root is checked by substitution, which rejects poles (`1/x = 0` changes
/// sign at 0 but is not a root).
private enum Solver {
    static func solve(
        lhs: CalculatorNode, rhs: CalculatorNode, variable: String, bound: [String: Double], angle: CalculatorAngleUnit
    ) throws -> CalculatorEngine.Solution {
        var vars = bound
        func f(_ x: Double) -> Double? {
            vars[variable] = x
            guard let l = try? lhs.evaluate(variables: vars, angle: angle),
                let r = try? rhs.evaluate(variables: vars, angle: angle)
            else { return nil }
            let d = l - r
            return d.isFinite ? d : nil
        }
        func scale(_ x: Double) -> Double {
            vars[variable] = x
            let l = (try? lhs.evaluate(variables: vars, angle: angle)) ?? 0
            let r = (try? rhs.evaluate(variables: vars, angle: angle)) ?? 0
            return max(1, Swift.abs(l), Swift.abs(r))
        }
        func isRoot(_ x: Double) -> Bool {
            guard let y = f(x) else { return false }
            return Swift.abs(y) <= 1e-9 * scale(x)
        }

        var grid: [Double] = stride(from: -100.0, through: 100.0, by: 0.05).map { ($0 * 100).rounded() / 100 }
        var magnitude = 1e-6
        while magnitude <= 1e12 {
            for m in [1.0, 1.5, 2.0, 3.0, 5.0, 7.0] {
                grid.append(m * magnitude)
                grid.append(-m * magnitude)
            }
            magnitude *= 10
        }
        grid = Array(Set(grid)).sorted()
        let values = grid.map { f($0) }

        var roots: [Double] = []
        func add(_ x: Double) {
            let polished = CalculatorEngine.clean(x)
            let candidate = isRoot(polished) ? polished : x
            guard isRoot(candidate) else { return }
            if !roots.contains(where: { Swift.abs($0 - candidate) <= 1e-9 * max(1, Swift.abs(candidate)) }) {
                roots.append(candidate)
            }
        }

        for i in grid.indices {
            guard let y = values[i] else { continue }
            if y == 0 { add(grid[i]); continue }
            if i + 1 < grid.count, let y2 = values[i + 1], y2 != 0, (y < 0) != (y2 < 0) {
                add(bisect(f, grid[i], grid[i + 1], y))
            }
            if i > 0, i + 1 < grid.count, let prev = values[i - 1], let next = values[i + 1],
                Swift.abs(y) < Swift.abs(prev), Swift.abs(y) <= Swift.abs(next), (prev < 0) == (y < 0), (next < 0) == (y < 0)
            {
                add(minimizeAbs(f, grid[i - 1], grid[i + 1]))
            }
        }

        guard !roots.isEmpty else {
            throw CalculatorError(
                "No real solution for \(variable) found (searched -1e12…1e12). The equation may have no real roots.")
        }
        // Periodic equations have infinitely many roots; keep the ones nearest 0.
        let sorted = roots.sorted { Swift.abs($0) < Swift.abs($1) || (Swift.abs($0) == Swift.abs($1) && $0 < $1) }
        let limit = 10
        return CalculatorEngine.Solution(
            variable: variable,
            roots: Array(sorted.prefix(limit)).sorted(),
            truncated: sorted.count > limit
        )
    }

    static func bisect(_ f: (Double) -> Double?, _ a0: Double, _ b0: Double, _ fa0: Double) -> Double {
        var (a, b, fa) = (a0, b0, fa0)
        for _ in 0..<200 {
            let m = (a + b) / 2
            guard m != a, m != b, let fm = f(m) else { return m }
            if fm == 0 { return m }
            if (fm < 0) == (fa < 0) { (a, fa) = (m, fm) } else { b = m }
        }
        return (a + b) / 2
    }

    static func minimizeAbs(_ f: (Double) -> Double?, _ a0: Double, _ b0: Double) -> Double {
        let ratio = (5.0.squareRoot() - 1) / 2
        var (a, b) = (a0, b0)
        for _ in 0..<200 {
            let c = b - ratio * (b - a)
            let d = a + ratio * (b - a)
            guard c != d, let fc = f(c), let fd = f(d) else { break }
            if Swift.abs(fc) < Swift.abs(fd) { b = d } else { a = c }
        }
        return (a + b) / 2
    }
}
