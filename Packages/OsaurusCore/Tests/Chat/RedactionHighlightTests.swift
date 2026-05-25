//
//  RedactionHighlightTests.swift
//  osaurusTests
//
//  Unit tests for `RedactionHighlighter.apply` — the post-pass that
//  decorates an `NSTextStorage` with inline highlights for Privacy
//  Filter matches. Focus areas:
//    • Empty inputs short-circuit without allocations.
//    • Longest-original-first ordering so overlapping originals
//      don't paint over each other.
//    • Custom attributes (`.redactionPlaceholder`, `.redactionDirection`)
//      land on every painted run so the hover controller can resolve
//      glyph -> placeholder without a parallel range list.
//    • Underline + foreground color match the cell's accent.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite("RedactionHighlighter")
struct RedactionHighlightTests {

    private func makeStorage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    @Test func emptyHighlights_isNoOp() {
        let storage = makeStorage("phone is 949-238-0232")
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: [:],
            accentColor: .red,
            a11yLabelBuilder: { _ in "label" }
        )
        #expect(applied.isEmpty)
        // No attribute should have landed on the storage.
        #expect(
            storage.attribute(.redactionPlaceholder, at: 0, effectiveRange: nil) == nil
        )
    }

    @Test func emptyStorage_isNoOp() {
        let storage = makeStorage("")
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: ["foo": RedactionHighlight(placeholderToken: "[X_1]", direction: .outbound)],
            accentColor: .red,
            a11yLabelBuilder: { _ in "label" }
        )
        #expect(applied.isEmpty)
    }

    @Test func paintsExpectedRange_outbound() {
        let text = "my number is 949-238-0232 right"
        let storage = makeStorage(text)
        let highlights: [String: RedactionHighlight] = [
            "949-238-0232": RedactionHighlight(
                placeholderToken: "[PHONE_1]",
                direction: .outbound
            )
        ]
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: highlights,
            accentColor: .systemBlue,
            a11yLabelBuilder: { hl in "Sent as \(hl.placeholderToken)" }
        )
        #expect(applied.count == 1)
        let range = applied[0].range
        let nsText = text as NSString
        #expect(nsText.substring(with: range) == "949-238-0232")

        // Verify all the expected attributes landed on the range.
        let placeholderAttr =
            storage.attribute(.redactionPlaceholder, at: range.location, effectiveRange: nil)
            as? String
        #expect(placeholderAttr == "[PHONE_1]")

        let directionAttr =
            storage.attribute(.redactionDirection, at: range.location, effectiveRange: nil)
            as? String
        #expect(directionAttr == RedactionHighlight.Direction.outbound.rawValue)

        let foreground =
            storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
            as? NSColor
        #expect(foreground == .systemBlue)

        // Tooltip is a backup a11y surface so RTF/drag exports
        // still carry the metadata.
        let tooltip =
            storage.attribute(.toolTip, at: range.location, effectiveRange: nil)
            as? NSString
        #expect(tooltip == "Sent as [PHONE_1]" as NSString)
    }

    @Test func paintsMultipleOccurrencesOfSameOriginal() {
        let text = "ping 949-238-0232 then call 949-238-0232 again"
        let storage = makeStorage(text)
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: [
                "949-238-0232": RedactionHighlight(
                    placeholderToken: "[PHONE_1]",
                    direction: .outbound
                )
            ],
            accentColor: .red,
            a11yLabelBuilder: { _ in "phone" }
        )
        #expect(applied.count == 2)
        let nsText = text as NSString
        for entry in applied {
            #expect(nsText.substring(with: entry.range) == "949-238-0232")
            #expect(entry.highlight.placeholderToken == "[PHONE_1]")
        }
    }

    @Test func longerOriginalsWinOverShorterSubstrings() {
        // "Alice" is a substring of "Alice Smith". The longer key
        // must paint first; the shorter one must NOT then overwrite
        // characters inside the longer's range, otherwise the
        // placeholder displayed for "Alice Smith" would point at
        // the wrong sibling.
        let text = "to Alice Smith and Alice"
        let storage = makeStorage(text)
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: [
                "Alice Smith": RedactionHighlight(
                    placeholderToken: "[PERSON_1]",
                    direction: .outbound
                ),
                "Alice": RedactionHighlight(
                    placeholderToken: "[PERSON_2]",
                    direction: .outbound
                ),
            ],
            accentColor: .red,
            a11yLabelBuilder: { _ in "name" }
        )
        // We expect two highlighted runs:
        //   • "Alice Smith" -> [PERSON_1]
        //   • the trailing standalone "Alice" -> [PERSON_2]
        #expect(applied.count == 2)
        let nsText = text as NSString
        let mapped = applied.map { entry -> (String, String) in
            (nsText.substring(with: entry.range), entry.highlight.placeholderToken)
        }
        #expect(mapped.contains(where: { $0.0 == "Alice Smith" && $0.1 == "[PERSON_1]" }))
        #expect(mapped.contains(where: { $0.0 == "Alice" && $0.1 == "[PERSON_2]" }))
        // The standalone-"Alice" entry must point at index 19
        // (after "to Alice Smith and "). It must NOT be the
        // "Alice" that sits inside "Alice Smith".
        guard
            let standalone = applied.first(where: {
                $0.highlight.placeholderToken == "[PERSON_2]"
            })
        else {
            Issue.record("Expected standalone Alice highlight")
            return
        }
        #expect(standalone.range.location == 19)
    }

    @Test func inboundDirection_setsDirectionAttribute() {
        let text = "Got it, Alice"
        let storage = makeStorage(text)
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: [
                "Alice": RedactionHighlight(
                    placeholderToken: "[PERSON_1]",
                    direction: .inbound
                )
            ],
            accentColor: .green,
            a11yLabelBuilder: { _ in "name" }
        )
        #expect(applied.count == 1)
        let direction =
            storage.attribute(.redactionDirection, at: applied[0].range.location, effectiveRange: nil)
            as? String
        #expect(direction == RedactionHighlight.Direction.inbound.rawValue)
    }

    // MARK: - buildDictionary bridge

    /// Shared bridge used by `NativeMessageCellView` (user +
    /// assistant bubbles) and `NativeThinkingView` (reasoning
    /// pane). Drift between the cell sites would manifest as some
    /// bubbles being highlighted and the thinking pane staying raw.
    @Test func buildDictionary_mapsSessionRedactionsToInbound() {
        let session: [String: String] = [
            "949-238-0232": "[PHONE_1]",
            "Alice": "[PERSON_1]",
        ]
        let dict = RedactionHighlight.buildDictionary(from: session, direction: .inbound)
        #expect(dict.count == 2)
        #expect(dict["949-238-0232"]?.placeholderToken == "[PHONE_1]")
        #expect(dict["949-238-0232"]?.direction == .inbound)
        #expect(dict["Alice"]?.direction == .inbound)
    }

    @Test func buildDictionary_skipsEmptyEntries() {
        let dict = RedactionHighlight.buildDictionary(
            from: ["": "[X_1]", "foo": "", "bar": "[BAR_1]"],
            direction: .outbound
        )
        #expect(dict.count == 1)
        #expect(dict["bar"]?.placeholderToken == "[BAR_1]")
    }

    @Test func buildDictionary_emptyInput_returnsEmpty() {
        let dict = RedactionHighlight.buildDictionary(from: [:], direction: .outbound)
        #expect(dict.isEmpty)
    }

    /// Integration: the thinking-pane wiring is "build inbound
    /// dict, then run the highlighter on a textStorage matching
    /// the restored assistant reasoning". This test exercises the
    /// same two calls in sequence and asserts the storage carries
    /// the inbound placeholder + direction attributes — the same
    /// signal the hover controller uses.
    @Test func inboundDirection_appliedFromThinkingPaneWiring() {
        let session: [String: String] = ["949-238-0232": "[PHONE_1]"]
        let highlights = RedactionHighlight.buildDictionary(
            from: session,
            direction: .inbound
        )
        let text = "The user message is: \"my phone is 949-238-0232\""
        let storage = NSTextStorage(string: text)
        let applied = RedactionHighlighter.apply(
            on: storage,
            highlights: highlights,
            accentColor: .systemBlue,
            a11yLabelBuilder: { _ in "phone" }
        )
        #expect(applied.count == 1)
        let placeholder =
            storage.attribute(.redactionPlaceholder, at: applied[0].range.location, effectiveRange: nil)
            as? String
        let direction =
            storage.attribute(.redactionDirection, at: applied[0].range.location, effectiveRange: nil)
            as? String
        #expect(placeholder == "[PHONE_1]")
        #expect(direction == RedactionHighlight.Direction.inbound.rawValue)
    }
}
