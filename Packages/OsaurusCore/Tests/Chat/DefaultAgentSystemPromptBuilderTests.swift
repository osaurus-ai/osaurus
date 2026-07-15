//
//  DefaultAgentSystemPromptBuilderTests.swift
//  OsaurusCoreTests
//
//  Verifies the simplified default-agent system prompt addendum: it is
//  derived from the live `ConfigurationDomainRegistry` (single source of
//  truth — it lists the registered domains' consolidated write tools), it
//  teaches DIRECT action-tool use (no capability-search protocol), it routes
//  out-of-scope asks to `osaurus_agent`, and it stays byte-stable across
//  calls within the same generation so the KV-cache reuse story holds.
//
//  Tests use `_renderForTests` for byte-level assertions against an
//  arbitrary domain list (no shared-cache mutation) and the live
//  `render()` path to assert memoization.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct DefaultAgentSystemPromptBuilderTests {

    private static func probe(id: String, writeToolNames: [String] = []) -> ConfigurationDomain {
        ConfigurationDomain(
            id: id,
            displayName: id.capitalized,
            summary: "Summary for \(id).",
            menuHint: "do / things",
            searchKeywords: [],
            exampleQueries: [],
            tools: [],
            writeToolNames: Set(writeToolNames)
        )
    }

    @Test
    func render_listsEveryDomainWriteTool() {
        let domains = [
            Self.probe(id: "providers", writeToolNames: ["osaurus_provider"]),
            Self.probe(id: "models", writeToolNames: ["osaurus_model"]),
        ]
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains)

        // The consolidated write tools are surfaced directly (sorted, in
        // backticks) so the model knows exactly which tools exist.
        #expect(rendered.contains("`osaurus_provider`"))
        #expect(rendered.contains("`osaurus_model`"))
        #expect(rendered.contains("Change tools:"))
    }

    @Test
    func render_teachesDirectActionToolsNotCapabilitySearch() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // The Default agent loads its writes directly — the prompt must tell
        // it to pick an `action`, and must NOT resurrect the old
        // discover/load protocol.
        #expect(rendered.contains("action"))
        #expect(!rendered.contains("capabilities_discover"))
        #expect(!rendered.contains("capabilities_load"))
    }

    @Test
    func render_teachesActInOneTurnNotChatConfirmation() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // The configure agent must act in a single turn (state the change, then
        // call the tool), relying on the separate one-tap approval gate. The old
        // "The user confirms every change" wording made careful models stall on
        // a chat "Confirm?" and never call the tool, so it must be gone.
        #expect(rendered.contains("same turn"))
        #expect(rendered.contains("approval"))
        #expect(rendered.contains("then call the tool"))
        #expect(!rendered.contains("confirms every change"))
    }

    @Test
    func render_compactAlsoTeachesActInOneTurnNotChatConfirmation() {
        // Regression pin: the compact variant shipped with "Rules: confirm
        // each change before calling." — the exact confirm-first stall the
        // full variant had already fixed. Local ≤20B models (the ONLY
        // audience of the compact prompt) obeyed it literally: they asked
        // "Please confirm" in chat and never emitted the write call
        // (default_agent 23/38 for gemma-4-12B vs 37/38 frontier). Both
        // variants must teach same-turn action and neither may tell the
        // model to seek chat confirmation first.
        for compact in [false, true] {
            let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
                domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
                compact: compact
            )
            #expect(rendered.contains("same turn"))
            #expect(rendered.contains("approval"))
            #expect(!rendered.contains("confirm each change"))
            #expect(!rendered.contains("confirms every change"))
        }
    }

    @Test
    func render_compactSplitsReadQuestionsFromChanges() {
        // Regression pin: the first same-turn rewrite framed EVERY request as
        // "state the change, then call the tool". gemma-4-12B (compact's only
        // audience) applied that framing to read questions too: it lazy-loaded
        // tools that are already resident (`capabilities_load tool/osaurus_status`
        // — a mustNotCall in every read case) and chained reads until the
        // iteration cap, ending with an EMPTY final answer (read-status,
        // honesty-no-schedules, read-describe-agent regressions in the
        // 20260702-154733 verify run). The compact prompt must (a) say the
        // read tools are always available with no loading step, and (b) tell
        // the model to answer in plain text once the reads contain the answer.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("always available"))
        #expect(compact.contains("no loading step"))
        #expect(compact.contains("For a question"))
        #expect(compact.contains("reply in plain text"))
        #expect(compact.contains("do not call more tools"))
    }

    @Test
    func render_compactScopesLazyLoadToChangeToolsOnly() {
        // Regression pin (20260702-230751 full re-measure): the load-on-demand
        // line said "if the ONE YOU NEED isn't already available, call
        // `capabilities_load`" — generic enough that gemma-4-12B applied it to
        // reads, opening read-only turns with `capabilities_load
        // ids=[tool/osaurus_status, tool/osaurus_list]` (a mustNotCall in
        // every read fixture) and even loading the WRITE tool
        // `osaurus_schedule` just to LIST schedules — burning 3-4-iteration
        // budgets into empty finals (read-status, read-describe-agent,
        // honesty-no-schedules pass→fail). The instruction must scope loading
        // to CHANGE tools at the load-decision site and explicitly exclude
        // reads, routing look-ups to the read tools.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("if the change tool you need isn't already available"))
        #expect(compact.contains("Loading is for change tools only"))
        #expect(compact.contains("reads never need it"))
        #expect(compact.contains("call the read tools directly"))
    }

    @Test
    func render_compactWriteToolsCarryDomainMenuHints() {
        // Regression pin: compact defers write-tool schemas from turn 1, so
        // the prompt line was the ONLY place a bare name like `osaurus_model`
        // could say what it does — and with no hint, gemma-4-12B refused
        // "download the MLX model …" as out-of-scope web work (model-download)
        // and answered agent-create with an empty turn. Each write tool must
        // carry its domain's one-line menuHint.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [
                Self.probe(id: "providers", writeToolNames: ["osaurus_provider"]),
                Self.probe(id: "models", writeToolNames: ["osaurus_model"]),
            ],
            compact: true
        )
        #expect(compact.contains("- `osaurus_model` — do / things"))
        #expect(compact.contains("- `osaurus_provider` — do / things"))
    }

    @Test
    func render_compactKeepsOsaurusManagementInScope() {
        // Regression pin: "Out of scope: anything non-config (coding, web,
        // files, images)" read as a topic blacklist — gemma refused
        // model-download ("I cannot download models or perform web tasks")
        // because downloading touches the web, even though `osaurus_model
        // action download` is the agent's own configure surface. The compact
        // prompt must scope the exclusion to doing non-config WORK and say
        // managing Osaurus itself stays in scope even when the request
        // mentions web or downloads.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("IS config"))
        #expect(compact.contains("even when the request mentions web or downloads"))
    }

    @Test
    func render_compactOutOfScopeOffersAgentHandoffExplicitly() {
        // The out-of-scope rubric (and the product contract) is a two-part
        // reply: say the agent only configures Osaurus AND offer the
        // create/switch handoff. The compact variant's old "Offer
        // `osaurus_agent` (`create` or `activate`)" tool-jargon lost the
        // second part on small models — pin the action words instead.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("Out of scope"))
        #expect(compact.contains("offer to create"))
        #expect(compact.contains("switch"))
        #expect(compact.contains("osaurus_agent"))
    }

    @Test
    func render_listsAlwaysAvailableReadTools() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        #expect(rendered.contains("osaurus_status"))
        #expect(rendered.contains("osaurus_list"))
        #expect(rendered.contains("osaurus_describe"))
    }

    @Test
    func render_routesOutOfScopeToAgentTool() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // Out-of-scope asks must be handed off to creating/switching an agent
        // via `osaurus_agent`, not refused flatly.
        #expect(rendered.contains("Out of scope"))
        #expect(rendered.contains("osaurus_agent"))
        #expect(rendered.contains("create"))
        #expect(rendered.contains("activate"))
    }

    @Test
    func render_compactIsShorterButKeepsToolSurface() {
        let domains = [
            Self.probe(id: "providers", writeToolNames: ["osaurus_provider"]),
            Self.probe(id: "models", writeToolNames: ["osaurus_model"]),
        ]
        let full = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains, compact: false)
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(domains: domains, compact: true)

        // Compact keeps the full tool surface + scope guardrails (read tools,
        // every write tool by name, out-of-scope handoff) but teaches the
        // load-on-demand flow: writes load via `capabilities_load`, with
        // NO `capabilities_discover` step.
        #expect(compact.contains("osaurus_status"))
        #expect(compact.contains("`osaurus_provider`"))
        #expect(compact.contains("`osaurus_model`"))
        #expect(compact.contains("action"))
        #expect(compact.contains("Out of scope"))
        #expect(compact.contains("osaurus_agent"))
        #expect(compact.contains("capabilities_load"))
        #expect(!compact.contains("capabilities_discover"))
        // The full variant loads writes directly — it must NOT teach lazy load.
        #expect(!full.contains("capabilities_load"))
    }

    @Test
    func render_compactIsMemoizedSeparatelyFromFull() {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
            DefaultAgentSystemPromptBuilder._resetForTests()
        }

        ConfigurationDomainBootstrap.registerBuiltIns()

        let compactFirst = DefaultAgentSystemPromptBuilder.render(compact: true)
        let compactSecond = DefaultAgentSystemPromptBuilder.render(compact: true)
        let full = DefaultAgentSystemPromptBuilder.render(compact: false)
        #expect(compactFirst == compactSecond)
        #expect(compactFirst != full)
    }

    @Test
    func render_handlesEmptyRegistry() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(domains: [])
        #expect(rendered.contains("none registered yet"))
    }

    @Test
    func render_isMemoizedPerGeneration() {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
            DefaultAgentSystemPromptBuilder._resetForTests()
        }

        ConfigurationDomainBootstrap.registerBuiltIns()

        let first = DefaultAgentSystemPromptBuilder.render()
        let second = DefaultAgentSystemPromptBuilder.render()
        #expect(first == second)
    }

    @Test
    func render_regeneratesWhenNewDomainRegisters() {
        let registry = ConfigurationDomainRegistry.shared
        registry._resetForTests()
        ConfigurationDomainBootstrap._resetForTests()
        DefaultAgentSystemPromptBuilder._resetForTests()
        defer {
            registry._resetForTests()
            ConfigurationDomainBootstrap._resetForTests()
            DefaultAgentSystemPromptBuilder._resetForTests()
        }

        let beforeRender = DefaultAgentSystemPromptBuilder.render()
        let probeWrite = "osaurus_probe_\(UUID().uuidString.prefix(6))"
        registry.register(
            Self.probe(
                id: "probe-new-\(UUID().uuidString.prefix(6))",
                writeToolNames: [probeWrite]
            )
        )
        let afterRender = DefaultAgentSystemPromptBuilder.render()
        #expect(beforeRender != afterRender)
        #expect(afterRender.contains(probeWrite))
    }

    @Test
    func render_warnsAboutSecretsNotInChatContext() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // Security invariant: the model is explicitly told not to echo
        // secrets. Matched loosely because the exact phrasing may be tuned.
        #expect(rendered.lowercased().contains("secret"))
        #expect(rendered.contains("Keychain"))
    }
}
