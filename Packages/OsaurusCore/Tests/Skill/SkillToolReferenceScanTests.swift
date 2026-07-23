//
//  SkillToolReferenceScanTests.swift
//  osaurusTests
//
//  Verifies the tool-name scan used to pre-load tools a skill's
//  instructions reference (issue #2145: a `/skill-name` invocation injected
//  instructions naming MCP tools that were never exposed to the turn, so
//  every call failed with tool_not_found).
//

import Foundation
import Testing

@testable import OsaurusCore

struct SkillToolReferenceScanTests {

    private let candidates: Set<String> = [
        "runalyze_mcp_get_activities",
        "runalyze_mcp_get_activity",
        "web_search",
        "notion-search",
    ]

    @Test
    func findsToolNamesSurroundedByProseAndPunctuation() {
        let text = """
            To fetch runs, call `runalyze_mcp_get_activities` with a date.
            For a single run use runalyze_mcp_get_activity.
            """
        #expect(
            SkillManager.toolNames(referencedIn: text, from: candidates)
                == ["runalyze_mcp_get_activities", "runalyze_mcp_get_activity"]
        )
    }

    @Test
    func matchesHyphenatedNamesAndSortsOutput() {
        let text = "Use notion-search first, then web_search as a fallback."
        #expect(
            SkillManager.toolNames(referencedIn: text, from: candidates)
                == ["notion-search", "web_search"]
        )
    }

    @Test
    func doesNotMatchSubstringsOfLongerIdentifiers() {
        // `web_search` appears only inside a longer identifier; the token
        // scan must not treat the substring as a mention.
        let text = "The my_web_search_wrapper helper handles retries."
        #expect(SkillManager.toolNames(referencedIn: text, from: candidates).isEmpty)
    }

    @Test
    func emptyInputsYieldNoMatches() {
        #expect(SkillManager.toolNames(referencedIn: "", from: candidates).isEmpty)
        #expect(SkillManager.toolNames(referencedIn: "call web_search", from: []).isEmpty)
    }
}
