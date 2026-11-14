//
//  YAMLLoading.swift
//  osaurus
//
//  `Yams.load` for text Osaurus did not write (a model's `osaurus_config`
//  YAML, a fetched OpenAPI document, an imported template). Yams builds a
//  mapping by force-unwrapping every key as a string, so a list or mapping
//  used as a key (`? [a, b]: c`, `{a: b}: c`) traps the process. The tree is
//  composed and checked first, and such a document throws instead.
//

import Foundation
import Yams

enum YAMLLoading {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case nonScalarKey

        var description: String {
            switch self {
            case .nonScalarKey:
                return "A mapping key is a list or a mapping; every key must be plain text."
            }
        }
    }

    static func load(_ yaml: String) throws -> Any? {
        if let node = try Yams.compose(yaml: yaml) { try check(node) }
        return try Yams.load(yaml: yaml)
    }

    private static func check(_ node: Node) throws {
        switch node {
        case .mapping(let mapping):
            for (key, value) in mapping {
                guard case .scalar = key else { throw Failure.nonScalarKey }
                try check(value)
            }
        case .sequence(let sequence):
            for item in sequence { try check(item) }
        case .scalar, .alias:
            return
        }
    }
}
