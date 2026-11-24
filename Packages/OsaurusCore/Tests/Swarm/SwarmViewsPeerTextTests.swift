//
//  SwarmViewsPeerTextTests.swift
//  OsaurusCoreTests
//
//  Node-supplied text (names, model ids, OS/GPU strings, pause and error
//  reasons) must never reach a Markdown-interpreting text path in the Swarm
//  settings views: a node named "[click](https://example.com) **bold**"
//  must render as those characters, not as a link. Catalog-key APIs
//  (`LocalizedStringKey`, `Text(_:bundle:)`, a callout's default message)
//  interpret Markdown, so every dynamic string goes through a verbatim path.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Swarm views render peer text verbatim")
struct SwarmViewsPeerTextTests {
    static let swarmViews = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Views/Settings/Swarm")

    static func sources() throws -> [(name: String, text: String)] {
        let files = try FileManager.default.contentsOfDirectory(at: swarmViews, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no Swarm view sources found at \(swarmViews.path)")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The argument text after `label:` in a call's text: the rest of that
    /// line, or the next non-empty line when the value starts below it.
    static func argument(_ label: String, in call: Substring) -> Substring? {
        guard let range = call.range(of: label + ":") else { return nil }
        let rest = call[range.upperBound...]
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// A plain string literal (no interpolation) is a catalog key we wrote.
    static func isLiteral(_ argument: Substring) -> Bool {
        argument.hasPrefix("\"") && !argument.contains("\\(")
    }

    /// Each `call(...)`'s full argument text, matched by parentheses outside
    /// string literals.
    static func calls(of call: String, in text: String) -> [Substring] {
        var out: [Substring] = []
        var search = text.startIndex
        while let range = text.range(of: call, range: search ..< text.endIndex) {
            var depth = 1
            var inString = false
            var previous: Character = " "
            var index = range.upperBound
            while index < text.endIndex, depth > 0 {
                let character = text[index]
                if character == "\"", previous != "\\" {
                    inString.toggle()
                } else if !inString {
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1 }
                }
                previous = character
                index = text.index(after: index)
            }
            out.append(text[range.lowerBound ..< index])
            search = range.upperBound
        }
        return out
    }

    @Test func noMarkdownInterpretingConstructors() throws {
        for (name, text) in try Self.sources() {
            #expect(!text.contains("LocalizedStringKey("), "\(name) builds a LocalizedStringKey")
            #expect(!text.contains("AttributedString(markdown"), "\(name) parses Markdown")
        }
    }

    @Test func calloutsWithDynamicMessagesAreVerbatim() throws {
        for (name, text) in try Self.sources() {
            for window in Self.calls(of: "SettingsCallout(", in: text) {
                guard let message = Self.argument("message", in: window) else { continue }
                if Self.isLiteral(message) { continue }
                #expect(
                    window.contains("verbatimMessage: true"),
                    "\(name): SettingsCallout with a dynamic message must pass verbatimMessage: true (\(message))"
                )
            }
        }
    }

    @Test func rowsWithDynamicTitlesAreVerbatim() throws {
        for (name, text) in try Self.sources() {
            for call in ["SettingsRow(", "SettingsToggle("] {
                for window in Self.calls(of: call, in: text) {
                    if let title = Self.argument("title", in: window), !Self.isLiteral(title) {
                        #expect(
                            window.contains("verbatimTitle: true") || window.contains("verbatim: true"),
                            "\(name): \(call) with a dynamic title must render it verbatim (\(title))"
                        )
                    }
                    // A closure description renders its own Text; a string
                    // description is a catalog key unless marked verbatim.
                    if let description = Self.argument("description", in: window),
                        !description.hasPrefix("{"), !Self.isLiteral(description)
                    {
                        #expect(
                            window.contains("verbatimDescription: true") || window.contains("verbatim: true"),
                            "\(name): \(call) with a dynamic description must render it verbatim (\(description))"
                        )
                    }
                }
            }
        }
    }
}
