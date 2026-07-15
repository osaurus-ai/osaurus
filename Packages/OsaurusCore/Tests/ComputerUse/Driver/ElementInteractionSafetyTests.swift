import Testing

@testable import OsaurusCore

@Suite
struct ElementInteractionSafetyTests {
    @Test
    func clearFallbackFailsClosedWhenNonActivatingFocusFails() {
        var selectAllCalled = false
        var deleteCalled = false

        let result = ElementInteraction.performClearFallback(
            focusWithoutActivation: { .fail("cannot focus without activation") },
            selectAll: {
                selectAllCalled = true
                return true
            },
            delete: {
                deleteCalled = true
                return true
            },
            delta: { nil }
        )

        #expect(!result.success)
        #expect(!selectAllCalled)
        #expect(!deleteCalled)
    }

    @Test
    func clearFallbackUsesOnlyFocusAndKeyboardOperations() {
        var operations: [String] = []

        let result = ElementInteraction.performClearFallback(
            focusWithoutActivation: {
                operations.append("focus_without_activation")
                return .ok()
            },
            selectAll: {
                operations.append("select_all")
                return true
            },
            delete: {
                operations.append("delete")
                return true
            },
            delta: { nil }
        )

        #expect(result.success)
        #expect(operations == ["focus_without_activation", "select_all", "delete"])
    }
}
