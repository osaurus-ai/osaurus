//
//  WorkspaceDiffNewFileCountTests.swift
//  osaurusTests
//
//  Pins the new-file diff counts surfaced on the file-write card header.
//  Creating a file must read as pure additions (`+N −0`): an empty `old`
//  side has zero lines, not one empty line, so it must not diff as a phantom
//  removal. Genuine edits still report removals.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkspaceDiffNewFileCountTests {

    /// Count added / removed body lines the way the card header does, skipping
    /// the `---` / `+++` file headers.
    private func counts(_ text: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") { continue }
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    @Test func newSingleLineFileIsPureAddition() {
        let diff = WorkspaceWriteSafety.unifiedDiffText(
            old: "", new: "firmlink-fixed", path: "out.txt", existed: false
        )
        let c = counts(diff.text)
        #expect(c.added == 1)
        #expect(c.removed == 0)
    }

    @Test func newMultiLineFileCountsEveryAddedLineAndNoRemovals() {
        let diff = WorkspaceWriteSafety.unifiedDiffText(
            old: "", new: "alpha\nbeta\ngamma", path: "out.txt", existed: false
        )
        let c = counts(diff.text)
        #expect(c.added == 3)
        #expect(c.removed == 0)
    }

    @Test func genuineEditStillReportsRemovals() {
        let diff = WorkspaceWriteSafety.unifiedDiffText(
            old: "before", new: "after", path: "out.txt", existed: true
        )
        let c = counts(diff.text)
        #expect(c.added == 1)
        #expect(c.removed == 1)
    }
}
