import Foundation
import Testing

@testable import OsaurusCore

/// `content` (one verbatim string) and `contents` (a `{name: text}` map) differ
/// by one letter and by type. A model that reaches for the plural with a single
/// block used to get `invalid_args: Property 'contents' must be an object`.
///
/// Observed live on Raptor 1.0 16B: two consecutive `invalid_args` rejections
/// of that family, then the turn collapsed into a verbatim repetition loop that
/// spent the entire token budget and recorded no stop reason. Accepting what
/// the model plainly meant removes the provocation.
@Suite("AppleScript string-contents promotion")
struct AppleScriptStringContentsPromotionTests {

    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("a string `contents` becomes `content`")
    func promotesStringContents() {
        let out = AppleScriptToolDispatch.promotingStringContents(
            #"{"question":"does the note body match?","contents":"the exact body text"}"#)
        let o = object(out)
        #expect(o["content"] as? String == "the exact body text")
        #expect(o["contents"] == nil)
        #expect(o["question"] as? String == "does the note body match?")
    }

    @Test("an explicit `content` is never clobbered")
    func doesNotClobberExplicitContent() {
        let input = #"{"question":"q","content":"real","contents":"other"}"#
        let out = AppleScriptToolDispatch.promotingStringContents(input)
        let o = object(out)
        #expect(o["content"] as? String == "real")
        #expect(o["contents"] as? String == "other", "left alone for the schema to judge")
    }

    @Test("a `contents` that is already a map is untouched")
    func leavesObjectContentsAlone() {
        let input = #"{"question":"q","contents":{"title":"Hello","body":"World"}}"#
        let out = AppleScriptToolDispatch.promotingStringContents(input)
        let o = object(out)
        let map = o["contents"] as? [String: Any]
        #expect(map?["title"] as? String == "Hello")
        #expect(o["content"] == nil)
    }

    @Test("an empty or whitespace string is left for the schema to reject")
    func leavesEmptyStringAlone() {
        for blank in ["", "   ", "\n"] {
            let input = "{\"question\":\"q\",\"contents\":\"\(blank == "\n" ? "\\n" : blank)\"}"
            let out = AppleScriptToolDispatch.promotingStringContents(input)
            #expect(object(out)["content"] == nil, "promoted a blank value: \(blank.debugDescription)")
        }
    }

    @Test("malformed JSON passes through unchanged")
    func passesThroughMalformedJSON() {
        let input = "{not json"
        #expect(AppleScriptToolDispatch.promotingStringContents(input) == input)
    }

    // MARK: - Through the tools' own normalization hooks

    @Test("mac_query normalizes a string `contents` before validation")
    func macQueryNormalizes() {
        let out = MacQueryTool().normalizeArgumentsBeforeValidation(
            #"{"question":"is the body equal to this?","contents":"exact block"}"#)
        let o = object(out)
        #expect(o["content"] as? String == "exact block")
        #expect(o["contents"] == nil)
    }

    /// The WRITE path must keep its safety property: an unrecognized `contents`
    /// string stays untouched so arbitrary text is never reinterpreted as user
    /// data before a mutation. Promotion is read-only and must not weaken it.
    @Test func automationLeavesUnrecognizedContentsUntouched() {
        let input = #"{"task":"set the note body to the exact text","contents":"the exact text"}"#
        #expect(AppleScriptToolDispatch.normalizeAutomationArguments(input) == input)
    }

    /// And the automation path's own narrow recovery still works, unaffected.
    @Test func automationExactReplacementRecoveryStillWorks() {
        let input =
            #"{"task":"replace \"alpha\" with \"beta\" in the note","contents":"oldText:alpha,newText:beta"}"#
        let o = object(AppleScriptToolDispatch.normalizeAutomationArguments(input))
        let map = o["contents"] as? [String: Any]
        #expect(map?["oldText"] as? String == "alpha")
        #expect(map?["newText"] as? String == "beta")
    }
}
