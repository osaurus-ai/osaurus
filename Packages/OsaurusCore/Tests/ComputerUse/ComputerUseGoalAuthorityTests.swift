//
//  ComputerUseGoalAuthorityTests.swift
//  osaurus
//

import Testing

@testable import OsaurusCore

struct ComputerUseGoalAuthorityTests {
    @Test("matching direct user replacement overrides a parent rewrite that invents save")
    func directUserReplacementStaysAuthoritative() {
        let userTask = "Change the text in the file from “Hello from OracHQ” to “Hello again”."
        let parentTask =
            "Open the text file, change every occurrence of \"Hello from OracHQ\" to "
            + "\"Hello again\", and save."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: parentTask,
                latestUserTask: userTask
            ) == userTask
        )
    }

    @Test("user replacement overrides the observed document-name parent rewrite")
    func userReplacementOverridesDocumentNameRewrite() {
        let userTask =
            "Change the text in the open TextEdit document from “Hello from OracHQ” to "
            + "“Hello again”. Do not save the document."
        let parentTask =
            "In TextEdit, find the document named \"Hello from OracHQ\" and replace its "
            + "entire contents with \"Hello again\". Do not save."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: parentTask,
                latestUserTask: userTask
            ) == userTask
        )
    }

    @Test("user replacement recovers a parent rewrite that drops the old text, and nothing broader")
    func userReplacementRecoversDroppedOldText() {
        let userTask =
            "Change the text in the open TextEdit document from “Hello from OracHQ” to "
            + "“Hello again”. Do not save the document."
        let observedParentTask =
            "Find the frontmost TextEdit document and set its contents to \"Hello again\""
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: observedParentTask,
                latestUserTask: userTask
            ) == userTask
        )

        let wrongApp = "Set the Notes body to \"Hello again\"."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: wrongApp,
                latestUserTask: userTask
            ) == wrongApp
        )

        let conflictingValue =
            "In TextEdit set the document to \"Hello again\" and name it \"Other\"."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: conflictingValue,
                latestUserTask: userTask
            ) == conflictingValue
        )
    }

    @Test("reconciliation rejects read-only and partial-value parent goals")
    func reconciliationRemainsNarrow() {
        let userTask = "Change the text in TextEdit from “one” to “two”."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: "Compare \"one\" with \"two\" in TextEdit.",
                latestUserTask: userTask
            ) == "Compare \"one\" with \"two\" in TextEdit."
        )
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: "Replace \"one\" with \"three\" in TextEdit.",
                latestUserTask: userTask
            ) == "Replace \"one\" with \"three\" in TextEdit."
        )
    }

    @Test("reconciliation is exact and preserves an explicit user save")
    func reconciliationDoesNotBroaden() {
        let parentTask =
            "Open the text file, change every occurrence of \"one\" to \"two\", and save."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: parentTask,
                latestUserTask: "Please open it."
            ) == parentTask
        )
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: parentTask,
                latestUserTask: "Change the text in the file from “other” to “two”."
            ) == parentTask
        )
        let explicitSave = "Change the text in the file from “one” to “two”, then save it."
        #expect(
            ComputerUseGoalAuthority.authoritativeReplacementTask(
                parentTask: parentTask,
                latestUserTask: explicitSave
            ) == explicitSave
        )
    }

    @Test("exact replacement grammar extracts only two-value replace/change forms")
    func exactReplacementGrammar() {
        #expect(
            ComputerUseGoalAuthority.exactReplacement(from: "Replace “a” with “b”")
                == .init(oldText: "a", newText: "b")
        )
        #expect(
            ComputerUseGoalAuthority.exactReplacement(from: "Change occurrences of \"a\" to \"b\"")
                == .init(oldText: "a", newText: "b")
        )
        #expect(
            ComputerUseGoalAuthority.exactReplacement(
                from: "Find the file containing “a” and replace that text with “b”"
            ) == .init(oldText: "a", newText: "b")
        )
        #expect(ComputerUseGoalAuthority.exactReplacement(from: "Compare “a” with “b”") == nil)
        #expect(ComputerUseGoalAuthority.exactReplacement(from: "Replace “a” with “b” and “c”") == nil)
        #expect(ComputerUseGoalAuthority.exactReplacement(from: "Replace “a with b") == nil)
    }
}
