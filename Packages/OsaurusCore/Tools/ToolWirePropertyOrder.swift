//
//  ToolWirePropertyOrder.swift
//  osaurus
//
//  Authored property order for tool schemas on the provider wire.
//
//  Why this exists: schema-constrained decoders only let a model emit
//  optional properties in the order the schema declares them — once a
//  later-declared key has been written, earlier ones are unreachable
//  (measured on xAI grok-4.3, 5/5 deterministic; llama.cpp-style
//  JSON-schema grammars behave the same way). Osaurus encodes every wire
//  body with `.sortedKeys` for prompt-cache determinism, which turns the
//  authored order into alphabetical order. For `file_edit` that put
//  `new_string` before `old_string`; the model naturally writes
//  `old_string` first, `new_string` then became unreachable, and the call
//  arrived as `{"path", "old_string", "replace_all": false}` — every time.
//  Declaring `properties` on `operations.items` failed the same way (`op`
//  was emitted first, so every key sorting before "op" — `cells`, `fields`,
//  `index`, `new_string`, `old_string` — vanished).
//
//  Tools that care declare `parameterOrder`; `ToolRegistry.register` records
//  it here, and `RemoteProviderService` runs `apply(to:)` over the encoded
//  body right before send. The rewrite is deterministic (declared keys in
//  authored order, everything else sorted), so the cache contract holds.
//

import Foundation

public enum ToolWirePropertyOrder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var orders: [String: [String]] = [:]

    /// Record (or clear, with `nil`) the authored order for a tool name.
    static func register(toolName: String, order: [String]?) {
        lock.lock()
        defer { lock.unlock() }
        if let order, !order.isEmpty {
            orders[toolName] = order
        } else {
            orders.removeValue(forKey: toolName)
        }
    }

    static func order(for toolName: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return orders[toolName]
    }

    /// Rewrite an encoded provider request body so each function schema
    /// belonging to a tool with a declared order lists its `properties` in
    /// that order (nested object schemas — `items`, property sub-schemas,
    /// `anyOf` branches — are ordered by the same list for the keys they
    /// contain). Returns the input untouched when no such tool is present
    /// or the body is not a JSON object/array.
    static func apply(to body: Data) -> Data {
        lock.lock()
        let snapshot = orders
        lock.unlock()
        guard !snapshot.isEmpty,
            let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        else { return body }
        var touched = false
        let rewritten = rewrite(root, orders: snapshot, touched: &touched)
        guard touched else { return body }
        var out = ""
        out.reserveCapacity(body.count + 64)
        write(rewritten, into: &out)
        return Data(out.utf8)
    }

    /// Ordered stand-in for a `properties` map; the writer emits its pairs
    /// verbatim instead of sorting.
    final class OrderedObject {
        let pairs: [(key: String, value: Any)]
        init(_ pairs: [(key: String, value: Any)]) { self.pairs = pairs }
    }

    // MARK: - Tree rewrite

    private static let schemaKeys = ["parameters", "input_schema"]

    private static func rewrite(_ value: Any, orders: [String: [String]], touched: inout Bool) -> Any {
        if let array = value as? [Any] {
            return array.map { rewrite($0, orders: orders, touched: &touched) }
        }
        guard var dict = value as? [String: Any] else { return value }
        if let name = dict["name"] as? String, let order = orders[name] {
            for key in schemaKeys {
                guard let schema = dict[key] as? [String: Any] else { continue }
                dict[key] = orderSchema(schema, order: order, touched: &touched)
            }
        }
        for (key, child) in dict {
            dict[key] = rewrite(child, orders: orders, touched: &touched)
        }
        return dict
    }

    /// Apply `order` to this schema object's `properties` and recurse into
    /// nested schema positions.
    static func orderSchema(_ schema: [String: Any], order: [String], touched: inout Bool) -> Any {
        var out: [String: Any] = [:]
        for (key, child) in schema {
            switch key {
            case "properties":
                guard let properties = child as? [String: Any] else {
                    out[key] = child
                    continue
                }
                let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                let sortedKeys = properties.keys.sorted { a, b in
                    switch (rank[a], rank[b]) {
                    case let (ra?, rb?): return ra < rb
                    case (.some, nil): return true
                    case (nil, .some): return false
                    case (nil, nil): return a < b
                    }
                }
                if sortedKeys != properties.keys.sorted() { touched = true }
                out[key] = OrderedObject(
                    sortedKeys.map { name in
                        let sub = properties[name]!
                        if let subSchema = sub as? [String: Any] {
                            return (key: name, value: orderSchema(subSchema, order: order, touched: &touched))
                        }
                        return (key: name, value: sub)
                    }
                )
            case "items", "additionalProperties", "not":
                if let subSchema = child as? [String: Any] {
                    out[key] = orderSchema(subSchema, order: order, touched: &touched)
                } else {
                    out[key] = child
                }
            case "anyOf", "oneOf", "allOf":
                if let branches = child as? [Any] {
                    out[key] = branches.map { branch -> Any in
                        guard let subSchema = branch as? [String: Any] else { return branch }
                        return orderSchema(subSchema, order: order, touched: &touched)
                    }
                } else {
                    out[key] = child
                }
            default:
                out[key] = child
            }
        }
        return out
    }

    // MARK: - Deterministic writer (sorted keys except `OrderedObject`)

    static func write(_ value: Any, into out: inout String) {
        switch value {
        case let ordered as OrderedObject:
            out.append("{")
            for (index, pair) in ordered.pairs.enumerated() {
                if index > 0 { out.append(",") }
                writeString(pair.key, into: &out)
                out.append(":")
                write(pair.value, into: &out)
            }
            out.append("}")
        case let dict as [String: Any]:
            out.append("{")
            for (index, key) in dict.keys.sorted().enumerated() {
                if index > 0 { out.append(",") }
                writeString(key, into: &out)
                out.append(":")
                write(dict[key]!, into: &out)
            }
            out.append("}")
        case let array as [Any]:
            out.append("[")
            for (index, element) in array.enumerated() {
                if index > 0 { out.append(",") }
                write(element, into: &out)
            }
            out.append("]")
        case let string as String:
            writeString(string, into: &out)
        case is NSNull:
            out.append("null")
        case let number as NSNumber:
            writeNumber(number, into: &out)
        default:
            // JSONSerialization never yields anything else; keep the body valid.
            writeString(String(describing: value), into: &out)
        }
    }

    private static func writeNumber(_ number: NSNumber, into out: inout String) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            out.append(number.boolValue ? "true" : "false")
            return
        }
        let type = String(cString: number.objCType)
        switch type {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
            out.append(number.stringValue)
        default:
            let double = number.doubleValue
            if double.isFinite, double == double.rounded(), abs(double) < 1e15 {
                out.append(String(Int64(double)))
            } else if double.isFinite {
                out.append("\(double)")
            } else {
                out.append("null")
            }
        }
    }

    /// RFC 8259 string escaping; slashes and non-ASCII pass through, matching
    /// `.withoutEscapingSlashes` canonical output.
    private static func writeString(_ string: String, into out: inout String) {
        out.append("\"")
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}
