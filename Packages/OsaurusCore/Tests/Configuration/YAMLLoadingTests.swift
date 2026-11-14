//
//  YAMLLoadingTests.swift
//  OsaurusCoreTests
//
//  A list or mapping used as a YAML key used to trap the process inside
//  Yams (it force-unwraps every key as a string). Model-written config,
//  templates, and fetched API documents now throw instead.
//

import Foundation
import Testing

@testable import OsaurusCore

struct YAMLLoadingTests {
    static let nonScalarKeys = [
        "? [a, b]\n: c\n",
        "agents:\n  ? {name: x}\n  : y\n",
        "- {[1, 2]: z}\n",
    ]

    @Test(arguments: nonScalarKeys)
    func aNonScalarKeyThrows(_ yaml: String) {
        #expect(throws: YAMLLoading.Failure.nonScalarKey) { try YAMLLoading.load(yaml) }
    }

    @Test(arguments: nonScalarKeys)
    func modelWrittenConfigWithANonScalarKeyIsMalformedNotACrash(_ yaml: String) {
        #expect(throws: ConfigYAMLError.self) { try ConfigYAML.decode(yaml) }
    }

    @Test
    func ordinaryYAMLStillLoads() throws {
        let tree = try YAMLLoading.load("base: &b {x: 1}\nmerged:\n  <<: *b\n  y: [1, 2]\n") as? [String: Any]
        let merged = try #require(tree?["merged"] as? [String: Any])
        #expect(merged["x"] as? Int == 1)
        #expect(merged["y"] as? [Int] == [1, 2])
    }
}
