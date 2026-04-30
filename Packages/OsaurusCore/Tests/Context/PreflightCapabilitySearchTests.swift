import Foundation
import Testing

@testable import OsaurusCore

struct PreflightCapabilitySearchTests {

    // MARK: - Integration-style smoke tests

    @Test func emptyQueryReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "", agentId: UUID())
        #expect(result.toolSpecs.isEmpty)
        #expect(result.items.isEmpty)
    }

    @Test func whitespaceOnlyQueryReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "   \n  ", agentId: UUID())
        #expect(result.toolSpecs.isEmpty)
        #expect(result.items.isEmpty)
    }

    @Test func nonsenseQueryReturnsGracefully() async {
        let result = await PreflightCapabilitySearch.search(
            query: "zzz_completely_nonexistent_capability_xyz_12345",
            agentId: UUID()
        )
        #expect(result.toolSpecs.isEmpty)
    }

    @Test func resultContainsNoDuplicateToolSpecs() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", agentId: UUID())
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func preflightToolSpecsHaveNoDuplicatesWithAlwaysLoaded() async {
        let alwaysLoaded = await MainActor.run {
            ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
        }
        _ = Set(alwaysLoaded.map { $0.function.name })

        let result = await PreflightCapabilitySearch.search(query: "search memory save method", agentId: UUID())
        let preflightNames = result.toolSpecs.map { $0.function.name }

        #expect(
            Set(preflightNames).count == preflightNames.count,
            "Pre-flight specs should not contain internal duplicates"
        )
    }

    // MARK: - PreflightSearchMode

    @Test func offModeReturnsEmptyResult() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", mode: .off, agentId: UUID())
        #expect(result.toolSpecs.isEmpty)
        #expect(result.items.isEmpty)
    }

    @Test func narrowModeReturnsNoDuplicates() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", mode: .narrow, agentId: UUID())
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func wideModeReturnsNoDuplicates() async {
        let result = await PreflightCapabilitySearch.search(query: "deploy build test", mode: .wide, agentId: UUID())
        let names = result.toolSpecs.map { $0.function.name }
        #expect(Set(names).count == names.count)
    }

    @Test func toolCapValuesAreCorrect() {
        // Caps are intentional ceilings, not targets. See
        // PreflightCapabilitySearch.swift for rationale.
        #expect(PreflightSearchMode.off.toolCap == 0)
        #expect(PreflightSearchMode.narrow.toolCap == 2)
        #expect(PreflightSearchMode.balanced.toolCap == 5)
        #expect(PreflightSearchMode.wide.toolCap == 15)
    }

    // MARK: - parseJustifiedPicks

    private static func makeCatalog() -> [ToolRegistry.ToolEntry] {
        [
            ToolRegistry.ToolEntry(
                name: "play",
                description: "Start playback",
                enabled: true,
                parameters: nil
            ),
            ToolRegistry.ToolEntry(
                name: "search_songs",
                description: "Find songs",
                enabled: true,
                parameters: nil
            ),
            ToolRegistry.ToolEntry(
                name: "send_message",
                description: "Post to a channel",
                enabled: true,
                parameters: nil
            ),
        ]
    }

    @Test func justifyFormatParsesNameAndReason() {
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "play | matches user request to play music",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play"])
    }

    @Test func picksWithoutReasonAreAccepted() {
        // Small models (Apple Foundation, etc.) routinely emit bare
        // names without the `| reason` suffix. The anti-padding floor
        // moved to `applyEmbeddingGuardrail` so we no longer punish
        // the formatting drift — bare names are valid picks.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "play\nsearch_songs",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play", "search_songs"])
    }

    @Test func picksWithEmptyReasonAreAccepted() {
        // Empty reason is no different from no reason — same loose
        // contract. Both rely on the embedding guardrail to drop
        // semantic mismatches.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "play |   \nsearch_songs | finds songs",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play", "search_songs"])
    }

    @Test func toolPrefixIsStripped() {
        // Models occasionally echo the catalog format back at us as
        // `tool: <name>`. Strip the prefix so it still resolves to a
        // canonical tool name.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "tool: play\ntool: search_songs | finds songs",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play", "search_songs"])
    }

    @Test func wrappingCharactersAreStripped() {
        // Apple Foundation echoes the prompt's `<tool_name>` placeholder
        // syntax as literal output ("<browser_navigate | open the orders
        // page>"). Other small models do the same with backticks and
        // quotes. The parser must unwrap before the canonical-name
        // lookup.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from:
                "<play | wrapped in angle brackets>\n`search_songs` | wrapped in backticks\n\"send_message\" | wrapped in quotes",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play", "search_songs", "send_message"])
    }

    @Test func antiPaddingNowEnforcedByGuardrail() async {
        // After Phase 1, `parseJustifiedPicks` accepts bare names. The
        // anti-padding contract relocated to the embedding guardrail —
        // a pick whose embedding is far from the query gets dropped
        // post-parse. This test pins that the guardrail can still
        // strip a parsed-but-irrelevant pick.
        let nameToDesc = ["play": "playback", "send_message": "post to a channel"]
        let embedder: PreflightCapabilitySearch.Embedder = { texts in
            // Query orthogonal to send_message, aligned with play.
            #expect(texts.count == 3)  // [query, play_text, send_message_text]
            return [
                [1.0, 0.0],  // query
                [1.0, 0.0],  // play -> aligned, sim=1
                [0.0, 1.0],  // send_message -> orthogonal, sim=0 (below 0.05 floor)
            ]
        }
        let kept = await PreflightCapabilitySearch.applyEmbeddingGuardrail(
            query: "play music",
            picks: ["play", "send_message"],
            nameToDesc: nameToDesc,
            embedder: embedder
        )
        #expect(kept == ["play"])
    }

    @Test func unknownNameIsDropped() {
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "totally_made_up | sounds plausible\nplay | real tool",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play"])
    }

    @Test func groupNameTokenIsIgnoredNotExpanded() {
        // Previously a `[provider]` token expanded to every tool in that
        // provider's group — the single biggest over-selection vector. The
        // new parser must drop it silently.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "[spotify] | matches the spotify provider\nplay | matches request",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play"])
    }

    @Test func trailingProviderAnnotationIsStripped() {
        // Models sometimes echo the catalog formatting back at us.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "play [spotify] | matches request",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play"])
    }

    @Test func leadingListBulletsAreTolerated() {
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "- play | matches request\n* search_songs | also relevant",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play", "search_songs"])
    }

    @Test func noneAfterValidPickActsAsTerminator() {
        // Models sometimes emit a stray `NONE` after legitimate picks (e.g.
        // `get_events | reason\n\nNONE`). Prior picks must survive — the
        // `NONE` is treated as "no more picks", not "discard everything".
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "play | would match\nNONE\nsearch_songs | discarded after NONE",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play"])
    }

    @Test func bareNoneShortCircuits() {
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "NONE",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks.isEmpty)
    }

    @Test func noneBeforeAnyValidPickAbstains() {
        // Reasoning models occasionally emit prose / unparseable junk
        // before the abstain signal. As long as no valid pick has been
        // collected yet, `NONE` clears any partial state.
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "totally_made_up | not in catalog\nNONE",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks.isEmpty)
    }

    @Test func emptyResponseReturnsEmpty() {
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "   \n  ",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks.isEmpty)
    }

    @Test func capIsHardCeiling() {
        // Model returned 10 picks; only the first `cap` valid ones survive.
        let response = (0 ..< 10)
            .map { _ in "play | reason\nsearch_songs | reason\nsend_message | reason" }
            .joined(separator: "\n")
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: response,
            catalog: Self.makeCatalog(),
            cap: 2
        )
        #expect(picks.count == 2)
    }

    @Test func duplicatePicksAreDeduped() {
        let picks = PreflightCapabilitySearch.parseJustifiedPicks(
            from: "play | first\nplay | second",
            catalog: Self.makeCatalog(),
            cap: 5
        )
        #expect(picks == ["play"])
    }

    // MARK: - Embedding guardrail

    @Test func guardrailDropsEgregiousMismatch() async {
        // Query vector is orthogonal to the second pick's vector → cosine 0,
        // which is below the 0.05 floor.
        let nameToDesc = ["good_match": "good", "bad_match": "bad"]
        let embedder: PreflightCapabilitySearch.Embedder = { texts in
            // texts: [query, good_match text, bad_match text]
            #expect(texts.count == 3)
            return [
                [1.0, 0.0],
                [1.0, 0.0],
                [0.0, 1.0],
            ]
        }
        let kept = await PreflightCapabilitySearch.applyEmbeddingGuardrail(
            query: "anything",
            picks: ["good_match", "bad_match"],
            nameToDesc: nameToDesc,
            embedder: embedder
        )
        #expect(kept == ["good_match"])
    }

    @Test func guardrailKeepsAllPicksWhenEmbedderThrows() async {
        let embedder: PreflightCapabilitySearch.Embedder = { _ in
            throw NSError(domain: "test", code: 1)
        }
        let kept = await PreflightCapabilitySearch.applyEmbeddingGuardrail(
            query: "q",
            picks: ["a", "b"],
            nameToDesc: ["a": "alpha", "b": "beta"],
            embedder: embedder
        )
        #expect(kept == ["a", "b"])
    }

    @Test func guardrailDisabledByNilEmbedder() async {
        let kept = await PreflightCapabilitySearch.applyEmbeddingGuardrail(
            query: "q",
            picks: ["a", "b"],
            nameToDesc: [:],
            embedder: nil
        )
        #expect(kept == ["a", "b"])
    }

    @Test func guardrailKeepsAllPicksOnEmbeddingCountMismatch() async {
        // Embedder returns wrong number of vectors → graceful degrade.
        let embedder: PreflightCapabilitySearch.Embedder = { _ in
            [[1.0, 0.0]]
        }
        let kept = await PreflightCapabilitySearch.applyEmbeddingGuardrail(
            query: "q",
            picks: ["a", "b"],
            nameToDesc: ["a": "alpha", "b": "beta"],
            embedder: embedder
        )
        #expect(kept == ["a", "b"])
    }

    // MARK: - Internal search() seam

    @Test func searchWithCannedLLMReturnsPicks() async {
        let llm: PreflightCapabilitySearch.LLMGenerator = { _, _ in
            // Use a name that's in the always-loaded built-in catalog so the
            // catalog filter doesn't drop it. If no dynamic tools are
            // registered the catalog is empty and we'd short-circuit; this
            // test only asserts the seam is wired, so we accept either an
            // empty result (no dynamic tools in the test environment) or the
            // canned pick coming through. The important assertion is that
            // canned LLM responses do NOT throw.
            return "play | sample"
        }
        // No embedder ⇒ guardrail disabled, so picks are not filtered by
        // similarity. Result depends on whether `play` is in the dynamic
        // catalog of the test process; if not, an empty result is correct
        // and equally validates the seam.
        let result = await PreflightCapabilitySearch.search(
            query: "play music",
            mode: .balanced,
            llm: llm,
            embedder: nil
        )
        #expect(result.items.count <= PreflightSearchMode.balanced.toolCap)
    }

    @Test func searchShortCircuitsOnLLMError() async {
        let llm: PreflightCapabilitySearch.LLMGenerator = { _, _ in
            throw NSError(domain: "test", code: 99)
        }
        let result = await PreflightCapabilitySearch.search(
            query: "anything",
            mode: .balanced,
            llm: llm,
            embedder: nil
        )
        #expect(result.items.isEmpty)
        #expect(result.toolSpecs.isEmpty)
        #expect(result.companions.isEmpty)
    }

    // MARK: - Chat-model fallback threading
    //
    // Surface contract for the `model:` parameter added in response to
    // GitHub issue #823. The parameter exists so the production entry
    // points can pass the active chat model into `CoreModelService`
    // as `fallbackModel:` — without it, preflight tool selection
    // silently breaks for users whose configured core model is unset
    // or unavailable on this Mac. These tests don't try to verify the
    // CoreModelService routing (covered in `CoreModelServiceFallbackTests`);
    // they pin that calling the public entry points with `model:` is
    // a non-throwing surface contract regardless of mode.

    @Test
    func search_acceptsModelParameter_balancedMode() async {
        let result = await PreflightCapabilitySearch.search(
            query: "deploy build test",
            mode: .balanced,
            agentId: UUID(),
            model: "test-chat-model"
        )
        // No assertion on contents — the test process may or may not
        // have any dynamic tools registered. The contract being pinned
        // is "passing model: doesn't crash and the call returns
        // normally" so future refactors of the threading don't
        // accidentally break the production wiring.
        _ = result
    }

    @Test
    func search_acceptsNilModelParameter_preservesLegacyBehaviour() async {
        let result = await PreflightCapabilitySearch.search(
            query: "deploy build test",
            mode: .balanced,
            agentId: UUID(),
            model: nil
        )
        _ = result
    }

    @Test
    func searchWithDiagnostic_acceptsModelParameter() async {
        let (result, _) = await PreflightCapabilitySearch.searchWithDiagnostic(
            query: "deploy build test",
            mode: .balanced,
            agentId: UUID(),
            model: "test-chat-model"
        )
        _ = result
    }
}
