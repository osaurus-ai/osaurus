//
//  ANSIStripperTests.swift
//
//  Pin the escape-code coverage. Best-effort, not a vt100 emulator —
//  but the SGR / cursor / OSC families that actually appear in shell
//  output (claude REPL, cargo build, npm install, mysql) must reduce
//  to plain text the chat UI can render verbatim.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ANSIStripperTests {

    @Test func sgrColorsAreStripped() {
        let input = "\u{1B}[31mhello\u{1B}[0m world"
        #expect(ANSIStripper.strip(input) == "hello world")
    }

    @Test func sgrComplexParametersAreStripped() {
        let input = "\u{1B}[1;36;48;5;234mfancy\u{1B}[0m"
        #expect(ANSIStripper.strip(input) == "fancy")
    }

    @Test func cursorMovesAreStripped() {
        let input = "go\u{1B}[1A\u{1B}[5C\u{1B}[Hmove\u{1B}[2J"
        #expect(ANSIStripper.strip(input) == "gomove")
    }

    @Test func alternateScreenTogglesAreStripped() {
        let input = "\u{1B}[?1049hbody\u{1B}[?1049l"
        #expect(ANSIStripper.strip(input) == "body")
    }

    @Test func oscTitleSetIsStripped() {
        // OSC 0 sets the terminal title; terminated by BEL.
        let input = "\u{1B}]0;my-tab\u{07}body"
        #expect(ANSIStripper.strip(input) == "body")
    }

    @Test func oscWithStringTerminatorIsStripped() {
        // OSC 8 hyperlink; terminated by ESC \\.
        let input = "\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\"
        #expect(ANSIStripper.strip(input) == "link")
    }

    @Test func bellAndShiftCharsAreSwallowed() {
        let input = "ring\u{07}ding\u{0E}so\u{0F}out"
        #expect(ANSIStripper.strip(input) == "ringdingsoout")
    }

    @Test func plainTextIsUnchanged() {
        let input = "no escapes here\nat all"
        #expect(ANSIStripper.strip(input) == input)
    }

    @Test func dataOverloadStripsAndRoundTrips() {
        let input = "\u{1B}[31mred\u{1B}[0m"
        let data = Data(input.utf8)
        let stripped = ANSIStripper.strip(data)
        #expect(String(data: stripped, encoding: .utf8) == "red")
    }
}
