//
//  RampartWindowingTests.swift
//  osaurusTests
//
//  The Rampart tokenizer truncates at 512 wordpieces, so large inputs
//  must be windowed before the forward pass. These cover the window
//  splitter: full coverage, line alignment, and the oversized-line case.
//

import Foundation
import Testing

@testable import OsaurusCore

struct RampartWindowingTests {

    @Test func smallInput_isSingleWindow() {
        let text = "short text"
        let windows = RampartPrivacyDetector.windows(of: text)
        #expect(windows.count == 1)
        #expect(String(windows[0].text) == text)
    }

    @Test func windows_coverWholeInput_inOrder() {
        let line = "Attendee: Sarah Chen, sarah@example.com\n"
        let text = String(repeating: line, count: 500)  // ~20K chars
        let windows = RampartPrivacyDetector.windows(of: text)
        #expect(windows.count > 1)
        #expect(windows.map { String($0.text) }.joined() == text)
    }

    @Test func windows_splitOnLineBoundaries() {
        let line = "Attendee: Sarah Chen joined the review.\n"
        let text = String(repeating: line, count: 200)
        for window in RampartPrivacyDetector.windows(of: text) {
            // Every window except possibly the last ends exactly at a
            // line break, so no single-line entity straddles windows.
            if window.text.endIndex != text.endIndex {
                #expect(window.text.hasSuffix("\n"))
            }
        }
    }

    @Test func windows_respectCap_forNormalLines() {
        let line = "Contact: marcus.webb@example.com, (555) 010-4477\n"
        let text = String(repeating: line, count: 400)
        for window in RampartPrivacyDetector.windows(of: text, cap: 1_500) {
            #expect(window.text.count <= 1_500 + line.count)
        }
    }

    @Test func oversizedSingleLine_becomesItsOwnWindow() {
        let huge = String(repeating: "a", count: 5_000)
        let text = "first line\n" + huge + "\nlast line"
        let windows = RampartPrivacyDetector.windows(of: text, cap: 1_500)
        #expect(windows.map { String($0.text) }.joined() == text)
        #expect(windows.contains { $0.text.count >= 5_000 })
    }
}
