//
//  AgentTodoParsingTests.swift
//  osaurusTests
//
//  Validates the markdown-checklist parser at the heart of `AgentTodo`.
//  This is the only complex bit of the new tool surface; everything
//  else is a thin pass-through.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentTodoParsingTests {

    @Test
    func parse_recognisesPendingAndDoneBoxes() {
        let items = AgentTodo.parseItems(
            from: """
                - [ ] First step
                - [x] Second step
                - [X] Third step (capital X)
                """
        )
        #expect(items.count == 3)
        #expect(items[0].text == "First step")
        #expect(items[0].isDone == false)
        #expect(items[1].isDone == true)
        #expect(items[2].isDone == true)
    }

    @Test
    func parse_acceptsAsteriskBullet() {
        let items = AgentTodo.parseItems(from: "* [ ] alpha\n* [x] beta")
        #expect(items.map(\.text) == ["alpha", "beta"])
        #expect(items.map(\.isDone) == [false, true])
    }

    @Test
    func parse_ignoresProseAndHeadings() {
        let items = AgentTodo.parseItems(
            from: """
                # Plan

                Some prose explaining context.

                - [ ] do the thing
                Some more prose.
                - [x] done thing
                """
        )
        #expect(items.count == 2)
        #expect(items[0].text == "do the thing")
        #expect(items[1].text == "done thing")
    }

    @Test
    func parse_indentationUpToSixSpacesAllowed() {
        let items = AgentTodo.parseItems(
            from: """
                - [ ] root
                  - [ ] nested 1
                      - [x] nested 2
                """
        )
        #expect(items.count == 3)
        #expect(items[2].isDone == true)
    }

    @Test
    func parse_skipsEmptyAndMalformedLines() {
        let items = AgentTodo.parseItems(
            from: """
                - [ ]
                - []wrong
                - [ ] real one
                random
                """
        )
        #expect(items.map(\.text) == ["real one"])
    }

    @Test
    func snapshot_doneAndTotalCountsMatchItems() {
        let todo = AgentTodo.parse("- [x] a\n- [ ] b\n- [x] c")
        #expect(todo.totalCount == 3)
        #expect(todo.doneCount == 2)
    }

    @Test
    func snapshot_idsAreStableAcrossParses() {
        let markdown = "- [ ] alpha\n- [x] beta"
        let a = AgentTodo.parse(markdown).items
        let b = AgentTodo.parse(markdown).items
        #expect(a.map(\.id) == b.map(\.id))
    }
}
