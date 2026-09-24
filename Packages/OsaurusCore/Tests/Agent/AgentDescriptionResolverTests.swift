import Foundation
import Testing
@testable import OsaurusCore

struct AgentDescriptionResolverTests {
    @Test func preservesManualDescriptionWithoutGeneration() async throws {
        let result = try await AgentDescriptionResolver.resolve(
            description: "  Checks citations.  ", systemPrompt: "Different purpose"
        ) { _ in
            Issue.record("Must not replace a supplied description")
            return "Replacement"
        }
        #expect(result == "Checks citations.")
    }

    @Test func blankDescriptionUsesPrompt() async throws {
        let result = try await AgentDescriptionResolver.resolve(
            description: " \n ", systemPrompt: " Check citations. "
        ) { prompt in
            #expect(prompt == "Check citations.")
            return " Checks sources when independent verification is needed. "
        }
        #expect(result == "Checks sources when independent verification is needed.")
    }

    @Test func noPromptRequiresManualInput() async {
        await #expect(throws: AgentDescriptionPolicy.Violation.required) {
            try await AgentDescriptionResolver.resolve(description: "", systemPrompt: " \n ") { _ in
                Issue.record("Must not generate a generic fallback")
                return "Generic"
            }
        }
    }

    @Test func invalidManualDescriptionIsNotReplaced() async {
        await #expect(throws: AgentDescriptionPolicy.Violation.tooLong) {
            try await AgentDescriptionResolver.resolve(
                description: String(repeating: "a", count: 161), systemPrompt: "Prompt"
            ) { _ in
                Issue.record("Invalid explicit input must be surfaced")
                return "Replacement"
            }
        }
    }

    @Test(arguments: ["", String(repeating: "a", count: 161), "First\nSecond", "x\u{202E}y",
        "a" + String(repeating: "\u{301}", count: 600)])
    func invalidGeneratedDescriptionsAreRejected(output: String) async {
        await #expect(throws: AgentDescriptionPolicy.Violation.self) {
            try await AgentDescriptionResolver.resolve(description: "", systemPrompt: "Prompt") { _ in output }
        }
    }

    @Test func acceptsExactCharacterLimit() async throws {
        let expected = String(repeating: "界", count: 160)
        let result = try await AgentDescriptionResolver.resolve(description: "", systemPrompt: "Prompt") { _ in expected }
        #expect(result == expected)
    }

    @Test func cancellationAfterGenerationCannotReturnDescription() async {
        let task = Task {
            try await AgentDescriptionResolver.resolve(description: "", systemPrompt: "Prompt") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return "Otherwise valid"
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
