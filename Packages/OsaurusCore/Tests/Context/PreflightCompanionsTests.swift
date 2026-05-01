//
//  PreflightCompanionsTests.swift
//  osaurus
//
//  Pure-function tests for `PreflightCompanions` — the phase-2 teaser
//  layer that surfaces sibling plugin tools + bundled skills after the
//  LLM picks a tool from a cohesive plugin.
//
//  Tests here intentionally avoid the registry / SkillManager state path:
//  they exercise `selectSiblings`, `tokenize`, `render`, and the no-op
//  branches of `derive` so the suite stays runnable in any harness
//  without plugin fixtures. The integration paths (real registry, real
//  pluginDisplayName lookup) are exercised by the OsaurusEvals package.
//

import Foundation
import Testing

@testable import OsaurusCore

struct PreflightCompanionsTests {

    // MARK: - PreflightResult shape

    @Test func emptyResultCarriesEmptyCompanions() {
        // The companion path is an opt-in addition to PreflightResult — the
        // legacy `.empty` singleton must keep returning no companions so
        // existing call sites that assert "no preflight" stay correct.
        #expect(PreflightResult.empty.companions.isEmpty)
    }

    @Test func defaultInitOmitsCompanions() {
        // Backwards-compat init: callers that don't pass companions get
        // an empty list, not a crash. Mirrors the behaviour the ChatView
        // and PluginHostAPI paths relied on before phase 2 landed.
        let result = PreflightResult(toolSpecs: [], items: [])
        #expect(result.companions.isEmpty)
    }

    // MARK: - derive (no-registry paths)

    @Test func deriveReturnsEmptyForEmptySelection() async {
        // No picks -> no plugins to consult -> no companions. This path
        // doesn't touch the registry, so it's safe to run without any
        // fixture setup.
        let companions = await MainActor.run {
            PreflightCompanions.derive(selectedNames: [], query: "anything")
        }
        #expect(companions.isEmpty)
    }

    @Test func deriveSkipsBuiltInToolPicks() async {
        // Built-in tools have no `groupName`, so even if they show up in
        // `selectedNames` (defensive: shouldn't, but the catalog filter
        // could regress), companion derivation must drop them silently
        // rather than emit a "no plugin" stub.
        let companions = await MainActor.run {
            PreflightCompanions.derive(
                selectedNames: ["capabilities_search"],
                query: "anything"
            )
        }
        #expect(companions.isEmpty)
    }

    // MARK: - selectSiblings

    private static func makeSiblings(_ names: [String]) -> [ToolRegistry.ToolEntry] {
        names.map {
            ToolRegistry.ToolEntry(
                name: $0,
                description: "desc for \($0)",
                enabled: true,
                parameters: nil
            )
        }
    }

    @Test func selectSiblingsCapsAtMaxSiblingTools() {
        // Big plugins (the browser plugin ships ~22 tools) would blow the
        // teaser budget without a cap. The exact ceiling is policy in
        // `PreflightCompanions.maxSiblingTools` — the test asserts the
        // contract, not the literal number.
        let names = (0 ..< 20).map { "browser_tool_\(String(format: "%02d", $0))" }
        let kept = PreflightCompanions.selectSiblings(
            from: Self.makeSiblings(names),
            query: "browse the web"
        )
        #expect(kept.count == PreflightCompanions.maxSiblingTools)
    }

    @Test func selectSiblingsOrdersAlphabeticallyAfterCap() {
        // KV-cache stability requires byte-stable rendering across runs.
        // Within the kept slice the final ordering must be alphabetical
        // so two runs with the same inputs produce identical prompt
        // bytes regardless of dictionary iteration order in the catalog.
        let names = ["browser_zoom", "browser_alpha", "browser_mid", "browser_beta"]
        let kept = PreflightCompanions.selectSiblings(
            from: Self.makeSiblings(names),
            // Empty query -> all overlap scores equal (zero) -> tie-break
            // falls back to alphabetical, exercising the same path that
            // would run for low-signal queries in production.
            query: ""
        )
        let keptNames = kept.map(\.name)
        #expect(keptNames == keptNames.sorted())
    }

    @Test func selectSiblingsPreferQueryOverlap() {
        // The whole point of scoring before capping: a high-signal sibling
        // (matches a query token) must survive the cap even when many
        // low-signal siblings exist. We pad with 10 unrelated tools and
        // check the matching one is still in the kept slice.
        var names = (0 ..< 10).map { "browser_unrelated_\($0)" }
        names.append("browser_open_login")
        let kept = PreflightCompanions.selectSiblings(
            from: Self.makeSiblings(names),
            query: "please log me in to amazon"
        )
        #expect(kept.contains { $0.name == "browser_open_login" })
    }

    @Test func selectSiblingsReturnsEmptyForNoCandidates() {
        let kept = PreflightCompanions.selectSiblings(from: [], query: "anything")
        #expect(kept.isEmpty)
    }

    // MARK: - tokenize

    @Test func tokenizeStripsPunctuationAndShortTokens() {
        // Single-char tokens are noise (a, e, i) — they inflate overlap
        // scores without adding signal. Punctuation like `?` and `-`
        // must split words rather than become part of them.
        let tokens = PreflightCompanions.tokenize("Amazon-orders? a I")
        #expect(tokens.contains("amazon"))
        #expect(tokens.contains("orders"))
        #expect(tokens.contains("a") == false)
        #expect(tokens.contains("i") == false)
    }

    // MARK: - render

    @Test func renderReturnsNilForEmptyInput() {
        // Empty companions -> no section -> caller skips append. We
        // return `nil` rather than an empty string so the composer's
        // `append` filter doesn't have to special-case whitespace.
        #expect(PreflightCompanions.render([]) == nil)
    }

    @Test func renderPlacesSkillBeforeSiblingTools() {
        // The whole behavioural nudge — "load the skill first" — depends
        // on the skill line appearing physically before the sibling tool
        // lines. If this ever flips, the trailing nudge becomes a lie
        // and the rendering becomes stylistically inconsistent.
        let companion = PluginCompanion(
            pluginId: "osaurus.browser",
            pluginDisplay: "Browser",
            skill: SkillTeaser(name: "osaurus-browser", description: "Browser skill"),
            siblingTools: [
                ToolTeaser(name: "browser_open_login", description: "Login window"),
                ToolTeaser(name: "browser_screenshot", description: "PNG screenshot"),
            ]
        )
        let rendered = PreflightCompanions.render([companion]) ?? ""
        guard let skillIdx = rendered.range(of: "skill/osaurus-browser"),
            let toolIdx = rendered.range(of: "tool/browser_open_login")
        else {
            Issue.record("skill or tool line missing from rendered companions section")
            return
        }
        #expect(skillIdx.lowerBound < toolIdx.lowerBound)
    }

    @Test func renderIncludesLoadInstructionAndPluginDisplayName() {
        // The teaser line must call out the plugin by display name (not
        // raw plugin id) so the model has a human-readable cue, and the
        // closing line must reference `capabilities_load` so the model
        // knows exactly which tool to call.
        let companion = PluginCompanion(
            pluginId: "osaurus.browser",
            pluginDisplay: "Browser",
            skill: nil,
            siblingTools: [ToolTeaser(name: "browser_open_login", description: "Login")]
        )
        let rendered = PreflightCompanions.render([companion]) ?? ""
        #expect(rendered.contains("**Browser**"))
        #expect(rendered.contains("capabilities_load"))
    }

    @Test func renderNudgeWarnsAgainstReLoadingAndExplainsCallByName() {
        // Reasoning models were observed treating `capabilities_load` as
        // the action itself and re-loading the same id every turn instead
        // of calling the now-available tool. The nudge MUST contain the
        // one-shot contract and the "call by name" reminder so the
        // behavioural fix doesn't silently regress in a future copy edit.
        let companion = PluginCompanion(
            pluginId: "osaurus.browser",
            pluginDisplay: "Browser",
            skill: nil,
            siblingTools: [ToolTeaser(name: "browser_open_login", description: "Login")]
        )
        let rendered = PreflightCompanions.render([companion]) ?? ""
        #expect(rendered.lowercased().contains("one-shot"))
        #expect(rendered.contains("Do NOT call `capabilities_load` again"))
        #expect(rendered.contains("call the tool directly by its name"))
    }

    @Test func renderHandlesSkillOnlyAndToolOnlyCompanions() {
        // A plugin can ship a skill but only one tool (already picked) —
        // resulting companion has skill + empty siblings. Conversely a
        // plugin can ship many tools and no skill. Both must render
        // without crashing or producing dangling formatting.
        //
        // Match against the bullet-line pattern `` - `tool/`` (and
        // `` - `skill/``) rather than the bare `tool/` / `skill/`
        // substring — the trailing `usageNudge` legitimately mentions
        // both as load-syntax examples (`capabilities_load({"ids":
        // ["skill/<name>", "tool/<name>"]})`), so a substring check
        // false-positives on every render.
        let skillOnly = PluginCompanion(
            pluginId: "x.example",
            pluginDisplay: "Example",
            skill: SkillTeaser(name: "example-skill", description: "Helps"),
            siblingTools: []
        )
        let toolOnly = PluginCompanion(
            pluginId: "y.example",
            pluginDisplay: "Y",
            skill: nil,
            siblingTools: [ToolTeaser(name: "y_alpha", description: "Alpha")]
        )
        let renderedSkill = PreflightCompanions.render([skillOnly]) ?? ""
        let renderedTool = PreflightCompanions.render([toolOnly]) ?? ""
        #expect(renderedSkill.contains("- `skill/example-skill`"))
        #expect(renderedSkill.contains("- `tool/") == false)
        #expect(renderedTool.contains("- `tool/y_alpha`"))
        #expect(renderedTool.contains("- `skill/") == false)
    }

    // MARK: - rankSkillSuggestions

    /// Helper: build a `SkillSearchResult` from a name + score, with
    /// a default description and optional `pluginId` to mark the
    /// skill as plugin-bundled.
    private static func makeHit(
        _ name: String,
        score: Float,
        pluginId: String? = nil
    ) -> SkillSearchResult {
        let skill = Skill(
            id: UUID(),
            name: name,
            description: "desc for \(name)",
            instructions: "body",
            pluginId: pluginId
        )
        return SkillSearchResult(skill: skill, searchScore: score)
    }

    @Test func rankSkillSuggestionsCapsAtThree() {
        // The whole point of this section is "compact preview" — five
        // ranked hits must surface only the top 3. The cap is policy
        // (`maxSkillSuggestions`), so we test the contract not the
        // literal number.
        let hits = (0 ..< 5).map { Self.makeHit("skill_\($0)", score: Float(10 - $0) / 10) }
        let teasers = PreflightCompanions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.count == PreflightCompanions.maxSkillSuggestions)
        // Top 3 by descending score = skill_0..skill_2.
        #expect(teasers.map(\.name) == ["skill_0", "skill_1", "skill_2"])
    }

    @Test func rankSkillSuggestionsExcludesPluginBundledSkills() {
        // Plugin-bundled skills are surfaced via `derive(...)` when
        // one of their plugin's tools is picked. Showing them twice
        // (once as a companion, once as a suggestion) is noise; the
        // post-search filter must drop them.
        let hits = [
            Self.makeHit("standalone-1", score: 0.9),
            Self.makeHit("plugin-skill", score: 0.85, pluginId: "osaurus.browser"),
            Self.makeHit("standalone-2", score: 0.8),
        ]
        let teasers = PreflightCompanions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.map(\.name) == ["standalone-1", "standalone-2"])
    }

    @Test func rankSkillSuggestionsExcludesAlreadyLoadedSkills() {
        // After the model calls `capabilities_load("skill/X")`, X
        // shouldn't keep showing up as a fresh suggestion every turn —
        // the loader already injected its full body. Callers thread
        // the loaded names in via `alreadyLoadedSkillNames`.
        let hits = [
            Self.makeHit("alpha", score: 0.9),
            Self.makeHit("beta", score: 0.8),
            Self.makeHit("gamma", score: 0.7),
        ]
        let teasers = PreflightCompanions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: ["beta"]
        )
        #expect(teasers.map(\.name) == ["alpha", "gamma"])
    }

    @Test func rankSkillSuggestionsTieBreaksAlphabetically() {
        // KV-cache stability: when two skills tie on score the
        // rendered prompt bytes must be identical across runs. The
        // search service doesn't promise a tie-break order, so the
        // rank step does it explicitly. Three skills on the same
        // score must come back in name order.
        let hits = [
            Self.makeHit("zulu", score: 0.5),
            Self.makeHit("alpha", score: 0.5),
            Self.makeHit("mike", score: 0.5),
        ]
        let teasers = PreflightCompanions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.map(\.name) == ["alpha", "mike", "zulu"])
    }

    @Test func rankSkillSuggestionsReturnsEmptyWhenNoStandaloneHits() {
        // Pure plugin-bundled hit set -> nothing to suggest. Tests the
        // guard that returns `[]` rather than rendering an empty section.
        let hits = [
            Self.makeHit("p1", score: 0.9, pluginId: "x"),
            Self.makeHit("p2", score: 0.8, pluginId: "y"),
        ]
        let teasers = PreflightCompanions.rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: []
        )
        #expect(teasers.isEmpty)
    }

    // MARK: - deriveSkillSuggestions short-circuits

    @Test func deriveSkillSuggestionsReturnsEmptyForBlankQuery() async {
        // No query -> no point hitting the search service. The
        // composer wires this gate around preflight too; this test
        // pins the same short-circuit at the function level so a
        // future caller bypassing the gate doesn't fire a useless
        // (and async) search call.
        #expect(await PreflightCompanions.deriveSkillSuggestions(query: "").isEmpty)
        #expect(await PreflightCompanions.deriveSkillSuggestions(query: "   \n\t  ").isEmpty)
    }

    // MARK: - renderSkillSuggestions

    @Test func renderSkillSuggestionsReturnsNilForEmptyTeasers() {
        // Empty teasers -> no section -> caller skips append. Same
        // contract as `render([])` for `pluginCompanions`.
        #expect(PreflightCompanions.renderSkillSuggestions([]) == nil)
    }

    @Test func renderSkillSuggestionsIncludesNameDescriptionAndLoaderNudge() {
        let teasers = [
            SkillTeaser(name: "data-viz", description: "Render charts inline"),
            SkillTeaser(name: "code-review", description: "Catch obvious smells"),
        ]
        let rendered = PreflightCompanions.renderSkillSuggestions(teasers) ?? ""
        // Name + description are surfaced in bullet rows so the model
        // can decide whether the skill is worth loading.
        #expect(rendered.contains("- `skill/data-viz`"))
        #expect(rendered.contains("Render charts inline"))
        #expect(rendered.contains("- `skill/code-review`"))
        // Loader story is identical to plugin companions so the model
        // doesn't see two different "how to load" sets.
        #expect(rendered.contains("capabilities_load"))
        #expect(rendered.lowercased().contains("one-shot"))
    }

    @Test func renderSkillSuggestionsHandlesEmptyDescriptionGracefully() {
        // Some skills (especially user-imports) ship without a
        // description. The teaser must still render with a stable
        // placeholder rather than a dangling `— ` after the name.
        let teasers = [SkillTeaser(name: "no-desc", description: "")]
        let rendered = PreflightCompanions.renderSkillSuggestions(teasers) ?? ""
        #expect(rendered.contains("- `skill/no-desc`"))
        #expect(rendered.contains("(no description)"))
    }
}
