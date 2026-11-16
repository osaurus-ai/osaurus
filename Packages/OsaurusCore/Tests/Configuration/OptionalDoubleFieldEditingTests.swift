import Foundation
@preconcurrency import MLXLMCommon
import Testing
@testable import OsaurusCore

struct OptionalDoubleFieldEditingTests {
    @Test func decimalKeystrokesStayUnchangedUntilCommit() {
        var editor = OptionalDoubleFieldEditing()
        editor.reset(value: nil, format: "%.2f")
        var text = ""
        for character in "0.70" {
            text.append(character)
            editor.edit(text)
            #expect(editor.text == text)
            #expect(editor.isEditing)
        }
        #expect(editor.commit(value: nil, clamp: 0.10...1.00, format: "%.2f") == 0.70)
        #expect(editor.text == "0.70")
        #expect(!editor.isEditing)
    }

    @Test func deletionClearsOnlyOnCommitAndReopensBlank() {
        var editor = OptionalDoubleFieldEditing()
        editor.reset(value: 0.7, format: "%.2f")
        for text in ["0.7", "0.", "0", ""] {
            editor.edit(text)
            #expect(editor.text == text)
        }
        let committed = editor.commit(value: 0.7, clamp: 0.1...1, format: "%.2f")
        #expect(committed == nil)
        var reopened = OptionalDoubleFieldEditing()
        reopened.reset(value: committed, format: "%.2f")
        #expect(reopened.text.isEmpty)
    }

    @Test(arguments: [".", "-", "not a number", "0.10.70", "nan", "inf", "1e999"])
    func invalidCommitPreservesExistingValue(text: String) {
        var editor = OptionalDoubleFieldEditing()
        editor.edit(text)
        #expect(editor.commit(value: 0.7, clamp: 0.1...1, format: "%.2f") == 0.7)
        #expect(editor.text == "0.70")
        editor.edit(text)
        #expect(editor.commit(value: nil, clamp: nil, format: nil) == nil)
        #expect(editor.text.isEmpty)
    }

    @Test func pasteClampsOnCommitAndReopensCommittedValue() {
        var editor = OptionalDoubleFieldEditing()
        editor.edit("  1.25  ")
        #expect(editor.text == "  1.25  ")
        let value = editor.commit(value: 0.7, clamp: 0.1...1, format: "%.2f")
        #expect(value == 1)
        #expect(editor.text == "1.00")
        editor.edit("0.")
        #expect(editor.text == "0.")
        #expect(editor.commit(value: value, clamp: 0.1...1, format: "%.2f") == 0.1)
        var reopened = OptionalDoubleFieldEditing()
        reopened.reset(value: value, format: "%.2f")
        #expect(reopened.text == "1.00")
    }

    @Test func externalResetDiscardsUncommittedText() {
        var editor = OptionalDoubleFieldEditing()
        editor.reset(value: 0.7, format: "%.2f")
        editor.edit("0.")
        editor.receive(value: 0.8, format: "%.2f")
        #expect(editor.text == "0.80")
        #expect(editor.commit(value: 0.8, clamp: 0.1...1, format: "%.2f") == 0.8)
    }

    @Test(arguments: ["20", "0.0", "nan"])
    @MainActor func focusedCorrectionCanFlushButStillRequiresValidation(text: String) {
        let committer = OptionalDoubleFieldCommitter()
        var draft = VMLXServerRuntimeSettings()
        draft.cache.blockDisk.enabled = true
        draft.cache.blockDisk.maxSizePercent = 0
        func blocked() -> Bool { draft.validationIssues().contains { $0.severity == .error } }
        #expect(blocked())
        #expect(committer.blocksSaveAttempt(hasBlockingIssues: blocked()))
        var editor = OptionalDoubleFieldEditing()
        editor.reset(value: 0, format: "%g")
        editor.edit(text)
        committer.setPending(id: UUID(), changed: editor.text != "0", commit: {
            draft.cache.blockDisk.maxSizePercent = editor.commit(
                value: draft.cache.blockDisk.maxSizePercent, clamp: nil, format: "%g")
        }, discard: {})
        // Save/Cmd-S must reach the flush while the bound fraction is still invalid.
        #expect(!committer.blocksSaveAttempt(hasBlockingIssues: blocked()))
        committer.commit()
        #expect(!committer.hasPendingChanges)
        // This is the same validator the form checks again before persisting.
        #expect(blocked() == (text != "20"))
        #expect(committer.blocksSaveAttempt(hasBlockingIssues: blocked()) == (text != "20"))
        #expect(draft.cache.blockDisk.maxSizePercent == (text == "20" ? 20 : 0))
    }

    @Test @MainActor func saveFlushesFocusedDraftAndResetDiscardsIt() {
        let committer = OptionalDoubleFieldCommitter()
        let field = UUID()
        var editor = OptionalDoubleFieldEditing()
        var value: Double? = 0.5
        editor.reset(value: value, format: "%.2f")
        editor.edit("0.70")
        committer.setPending(id: field, changed: true, commit: {
            value = editor.commit(value: value, clamp: 0.1...1, format: "%.2f")
        }, discard: { editor.reset(value: value, format: "%.2f") })
        #expect(committer.hasPendingChanges)
        #expect(value == 0.5)
        committer.clear(id: UUID()) // A disappearing sibling cannot clear this field.
        #expect(committer.hasPendingChanges)
        committer.commit()
        #expect(value == 0.7)
        #expect(!committer.hasPendingChanges)
        editor.edit("0.2")
        committer.setPending(id: field, changed: true, commit: {
            value = editor.commit(value: value, clamp: 0.1...1, format: "%.2f")
        }, discard: { editor.reset(value: value, format: "%.2f") })
        committer.discard()
        #expect(value == 0.7)
        #expect(editor.text == "0.70")
        #expect(!committer.hasPendingChanges)
    }
}
