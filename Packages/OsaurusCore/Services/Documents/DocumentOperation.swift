//
//  DocumentOperation.swift
//  osaurus
//
//  One entry of `file_edit`'s `operations` array, with typed accessors
//  whose errors name the failing entry (`operations[2] (set_cells): …`).
//

import Foundation

struct DocumentOperation {
    let index: Int
    let name: String
    let args: [String: Any]

    /// Key sets that identify an operation when `op` is omitted. Only
    /// content edits are listed: deleting, reordering, or restructuring
    /// always needs an explicit `op`.
    static let signatures: [String: [[String]]] = [
        "replace_text": [["old_string"], ["find"]],
        "set_cells": [["cells"]],
        "set_table_cell": [["table", "row", "column", "text"]],
        "set_slide_text": [["slide", "shape", "text"]],
        "insert_paragraph": [["text", "after"], ["text", "before"]],
        "append_markdown": [["markdown"]],
    ]

    /// `allowed` is the target format's operation list, used to identify an
    /// entry that omits `op` by its keys.
    init(index: Int, raw: [String: Any], allowed: [String] = []) throws {
        self.index = index
        self.args = raw
        if let op = (raw["op"] as? String)?.trimmingCharacters(in: .whitespaces), !op.isEmpty {
            self.name = op.lowercased()
            return
        }
        let present = Set(raw.filter { !($0.value is NSNull) }.keys)
        let matches = allowed.filter { name in
            Self.signatures[name]?.contains { Set($0).isSubset(of: present) } ?? false
        }
        guard matches.count == 1 else {
            let choices = allowed.isEmpty ? "" : " Operations for this file: \(allowed.joined(separator: ", "))."
            throw DocumentEditError(
                "`operations[\(index)]` needs an `op` name, e.g. {\"op\": \"replace_text\", \"old_string\": \"old\", \"new_string\": \"new\"}."
                    + choices
            )
        }
        self.name = matches[0]
    }

    func fail(_ message: String) -> DocumentEditError {
        DocumentEditError("`operations[\(index)]` (\(name)): \(message)")
    }

    func has(_ key: String) -> Bool {
        guard let value = args[key] else { return false }
        return !(value is NSNull)
    }

    func string(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = args[key] as? String else {
            throw fail("`\(key)` must be a string.")
        }
        if !allowEmpty, value.isEmpty { throw fail("`\(key)` must not be empty.") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        return try string(key, allowEmpty: true)
    }

    func int(_ key: String) throws -> Int {
        guard let value = try optionalInt(key) else { throw fail("`\(key)` is required (a number).") }
        return value
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard has(key) else { return nil }
        if let parsed = Self.coerceInt(args[key]) { return parsed }
        throw fail("`\(key)` must be a whole number.")
    }

    func ints(_ key: String) throws -> [Int] {
        guard let value = try optionalInts(key) else { throw fail("`\(key)` is required (an array of numbers).") }
        return value
    }

    func optionalInts(_ key: String) throws -> [Int]? {
        guard has(key) else { return nil }
        if let single = Self.coerceInt(args[key]) { return [single] }
        guard let array = args[key] as? [Any] else { throw fail("`\(key)` must be an array of whole numbers.") }
        return try array.map { item in
            guard let n = Self.coerceInt(item) else { throw fail("`\(key)` must contain only whole numbers.") }
            return n
        }
    }

    func bool(_ key: String) -> Bool {
        switch args[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "yes", "1"].contains(s.lowercased())
        default: return false
        }
    }

    static func coerceInt(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double where d.rounded() == d && abs(d) < 1e12: return Int(d)
        case let n as NSNumber:
            let d = n.doubleValue
            return d.rounded() == d ? n.intValue : nil
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Validates a 1-based position against `count` items.
    func position(_ value: Int, of count: Int, noun: String) throws -> Int {
        guard value >= 1, value <= count else {
            throw fail("\(noun) \(value) doesn't exist (there \(count == 1 ? "is 1 \(noun)" : "are \(count) \(noun)s")).")
        }
        return value - 1
    }

    /// `order` must be a permutation of 1...count.
    func permutation(_ key: String, count: Int, noun: String) throws -> [Int] {
        let order = try ints(key)
        guard order.count == count, Set(order) == Set(1...max(count, 1)) else {
            throw fail("`\(key)` must list every \(noun) exactly once (1…\(count)), e.g. \(Array(1...max(count, 1)).reversed()).")
        }
        return order.map { $0 - 1 }
    }
}
