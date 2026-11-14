import Testing
@testable import OsaurusCore

struct OptionalIntFieldEditingTests {
    @Test func typingContextCapDoesNotInsertClampedPrefix() {
        let range = 2048...131072
        var text = ""
        for digit in "8192" {
            text.append(digit)
            let saved = min(max(Int(text)!, range.lowerBound), range.upperBound)
            text = OptionalIntFieldEditing.reconcile(text, value: saved, clamp: range)
        }
        #expect(text == "8192")
    }

    @Test func echoesPreserveDraftButExternalUpdatesReplaceIt() {
        #expect(OptionalIntFieldEditing.reconcile("8", value: 2048, clamp: 2048...131072) == "8")
        #expect(OptionalIntFieldEditing.reconcile("8192", value: 16384, clamp: 2048...131072) == "16384")
        #expect(OptionalIntFieldEditing.reconcile("", value: nil, clamp: nil) == "")
        #expect(OptionalIntFieldEditing.reconcile("invalid", value: 4096, clamp: nil) == "4096")
        #expect(OptionalIntFieldEditing.reconcile("8192", value: nil, clamp: nil) == "")
        #expect(OptionalIntFieldEditing.reconcile("999999", value: 131072, clamp: 2048...131072) == "999999")
    }
}
