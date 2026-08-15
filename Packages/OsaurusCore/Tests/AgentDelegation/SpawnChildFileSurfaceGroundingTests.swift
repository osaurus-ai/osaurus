//
//  SpawnChildFileSurfaceGroundingTests.swift
//  OsaurusCore
//
//  A spawned child can hold BOTH filesystem surfaces at once — `file_read` /
//  `file_search` (the user's open folder on the host) and `sandbox_read_file` /
//  `sandbox_search_files` (inside the Linux sandbox) — while `spawn_model` runs
//  it with an EMPTY system prompt. Nothing told it which was which.
//
//  Live: a child told "use the file_read tool to read 'AGENTS.md' from the
//  current working folder" called `sandbox_read_file` instead. That failed; an
//  identical retry succeeded. Two similarly-named tools plus zero grounding is a
//  coin flip, not a race.
//

import Testing

@testable import OsaurusCore

@Suite("A spawned child is told which filesystem each read tool reads")
struct SpawnChildFileSurfaceGroundingTests {

    /// The live failure shape: both surfaces in one toolset.
    @Test("both surfaces present: the child is told they are separate filesystems")
    func bothSurfacesAreDisambiguated() throws {
        let grounding = try #require(
            TextSubagentKind.fileSurfaceGrounding(toolNames: [
                "file_read", "file_search", "sandbox_read_file", "sandbox_search_files",
            ]))

        #expect(grounding.contains("file_read"))
        #expect(grounding.contains("sandbox_read_file"))
        // The load-bearing fact: they are NOT the same filesystem.
        #expect(grounding.contains("open folder"))
        #expect(grounding.contains("sandbox"))
        #expect(grounding.contains("NOT reachable"))
    }

    @Test("host tools only: no sandbox tool is ever mentioned")
    func hostOnlyDoesNotMentionSandbox() throws {
        let grounding = try #require(
            TextSubagentKind.fileSurfaceGrounding(toolNames: ["file_read", "file_search"]))

        #expect(grounding.contains("file_read"))
        // Never name a tool the child does not have.
        #expect(grounding.contains("sandbox_read_file") == false)
    }

    @Test("sandbox tools only: no host tool is ever mentioned")
    func sandboxOnlyDoesNotMentionHost() throws {
        let grounding = try #require(
            TextSubagentKind.fileSurfaceGrounding(toolNames: [
                "sandbox_read_file", "sandbox_search_files",
            ]))

        #expect(grounding.contains("sandbox_read_file"))
        #expect(grounding.contains("file_read") == false)
    }

    /// A text-only child (no tool access) must stay text-only: no file section,
    /// no wasted tokens, and nothing that implies tools it cannot call.
    @Test("no file tools: no grounding is injected at all")
    func noFileToolsInjectsNothing() {
        #expect(TextSubagentKind.fileSurfaceGrounding(toolNames: []) == nil)
        #expect(TextSubagentKind.fileSurfaceGrounding(toolNames: ["web_search"]) == nil)
    }
}
