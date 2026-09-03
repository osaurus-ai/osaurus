//
//  DefaultAgentSystemPromptBuilderTests.swift
//  OsaurusCoreTests
//
//  Verifies the simplified default-agent system prompt addendum: it is
//  derived from the live `ConfigurationDomainRegistry` (single source of
//  truth — it lists the registered domains' consolidated write tools), it
//  teaches DIRECT action-tool use (no capability-search protocol), it routes
//  non-Osaurus work to delegation (create the agent via `osaurus_config`,
//  then run it with `spawn_agent` in the same turn), and it stays
//  byte-stable across calls within the same generation so the KV-cache
//  reuse story holds.
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
        // tools that are already resident (`capabilities_load tool/osaurus_inspect`
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
        #expect(compact.contains("Look things up any time"))
        #expect(compact.contains("no loading step"))
        #expect(compact.contains("For a question"))
        #expect(compact.contains("reply in plain text"))
        #expect(compact.contains("do not call more tools"))
        // Ornith-9B regression: framing the lookup tools as "read tools" /
        // "Reads" primed the model to invent `<read><name>…` markup instead
        // of real tool calls, and compact under-specified osaurus_help's
        // action shape. The compact prompt must name actions explicitly and
        // never coin a "read tools" noun.
        #expect(compact.contains("{action: 'topics' | 'read', topic: ...}"))
        #expect(!compact.contains("read tools"))
        #expect(!compact.contains("Reads are"))
    }

    @Test
    func render_compactScopesTheWriteToolToChangesOnly() {
        // Regression lineage (20260702-230751 full re-measure): generic
        // "use the tool" guidance made gemma-4-12B route READ questions
        // through write-tool machinery, burning 3-4-iteration budgets into
        // empty finals (read-status, read-describe-agent,
        // honesty-no-schedules pass→fail). The compact prompt must scope
        // `osaurus_config` to changes at the decision site and explicitly
        // route look-ups to the read tools. It must also spell out the
        // YAML workflow, since the compact tool schema strips the prose
        // that would otherwise teach it.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        // Gap 0.5 consolidation: the change workflow is stated once in the
        // shared write contract, which the compact prompt embeds verbatim.
        #expect(compact.contains(ConfigurationReadNextStep.writeContract))
        #expect(compact.contains("only the keys to change"))
        #expect(compact.contains("`osaurus_config` is for changes only"))
        #expect(compact.contains("call `osaurus_inspect` or `osaurus_help` directly"))
        #expect(!compact.contains("capabilities_load"))
        #expect(!compact.contains("capabilities_discover"))
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
        // prompt must scope the exclusion to doing non-Osaurus WORK and say
        // managing/explaining Osaurus itself stays in scope even when the
        // request mentions web or downloads. (Was "IS config" before the
        // configure+explain revamp widened the agent's job.)
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("IS your job"))
        #expect(compact.contains("even when the request mentions web or downloads"))
    }

    @Test
    func render_compactDelegationTeachesCreateThenSpawn() {
        // Orchestrator-first contract: the delegation rubric is a two-part
        // ACTION, not an offer — create the fitting agent (an `agents:`
        // entry via `osaurus_config`) and run the task with `spawn_agent`
        // in the SAME turn. Pin the route words so small models don't fall
        // back to offering a switch or asking permission.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("Delegation"))
        #expect(compact.contains("`agents:` entry"))
        #expect(compact.contains("spawn_agent"))
        #expect(compact.contains("SAME turn"))
        #expect(compact.contains("spawnable right away"))
    }

    @Test
    func render_bothVariantsPinTheOrchestratorPersona() {
        // Orchestrator-first persona (live regression: asked "i want to make
        // a website", the assistant replied "Building a website is outside
        // what I can do directly here", listed two options, and ended with
        // "Want me to…? tell me a bit about the site…" — a decline, a menu,
        // and questions instead of create+spawn). Both variants must:
        // (a) identify as the orchestrator who gets anything done,
        // (b) teach create-then-spawn in the SAME turn and reporting the
        //     spawn result as the answer,
        // (c) forbid suggesting an agent switch or re-sending the request
        //     (the conversation always stays here — `active_agent` only
        //     governs NEW chats),
        // (d) demand brevity: no option menus, act first, assume sensibly.
        for compact in [false, true] {
            let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
                domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
                compact: compact
            )
            #expect(rendered.contains("orchestrator"), "variant compact=\(compact)")
            #expect(rendered.contains("spawn_agent"), "variant compact=\(compact)")
            #expect(rendered.contains("SAME turn"), "variant compact=\(compact)")
            #expect(rendered.contains("spawn result"), "variant compact=\(compact)")
            #expect(rendered.contains("Never suggest"), "variant compact=\(compact)")
            #expect(rendered.contains("NEW chats"), "variant compact=\(compact)")
            #expect(rendered.contains("option menus"), "variant compact=\(compact)")
            #expect(rendered.contains("`clarify`"), "variant compact=\(compact)")
            // The decline framing is gone: no "Out of scope" section header,
            // and no live-chat handoff wording ("answered by that agent")
            // from the reverted active_agent retargeting.
            #expect(!rendered.contains("Out of scope"), "variant compact=\(compact)")
            #expect(!rendered.contains("answered by that agent"), "variant compact=\(compact)")
        }
    }

    @Test
    func render_compactTeachesTheKnowledgeGapContracts() {
        // Ornith-9B knowledge-gap pins (26/53 run): the model concluded
        // "Osaurus can't delete agents" (delete = prune), narrated an API-key
        // paste flow (rotation = set_api_key), and said "Osaurus doesn't do
        // slash commands" (no read result names the `commands` section). The
        // compact prompt must teach delete-via-prune, set_api_key, and the
        // full section roster — rendered from ConfigSectionID so it can
        // never drift from the real schema.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("prune: true"))
        #expect(compact.contains("set_api_key: true"))
        #expect(compact.contains("never the key value"))
        for section in ConfigSectionID.allNames {
            #expect(compact.contains(section), "roster must name section \(section)")
        }
        // yaml_shape short-circuit: read results now carry the shape, so the
        // prompt routes schema calls to the "when they don't" case only.
        #expect(compact.contains("yaml_shape"))
    }

    @Test
    func render_fullVariantTeachesTheSameKnowledgeContracts() {
        // Grok iter-5 pins: with only the compact variant taught, the full
        // prompt let a frontier model claim it can't download models (zero
        // calls) and map "core model" onto default_agent.model. The full
        // variant must carry the roster, the install-vs-use split, the
        // foundation value, and the dry-run contract too.
        let full = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: false
        )
        for section in ConfigSectionID.allNames {
            #expect(full.contains(section), "full roster must name section \(section)")
        }
        #expect(full.contains("starts the download"))
        #expect(full.contains("default_agent.model"))
        #expect(full.contains("foundation"))
        #expect(full.contains("prune: true"))
        #expect(full.contains("set_api_key: true"))
        #expect(full.contains("never report a planned change as done"))
        // Scope reduction 2: the full prompt must route server/chat/app
        // asks to the Settings UI instead of the removed sections.
        #expect(full.contains("Settings UI"))
    }

    @Test
    func render_compactForbidsNarratedToolCalls() {
        // Ornith-9B degeneration pin (provider-add-anthropic, 0 calls): the
        // model typed tool-call JSON and invented results in its reply text
        // instead of emitting real calls. The compact rules must forbid it.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(compact.contains("Emit tool calls only as real tool calls"))
        #expect(compact.contains("never type a tool call"))
    }

    @Test
    func render_compactDelegationForbidsDoingTheWorkInChat() {
        // Ornith-9B handoff pin (handoff-non-osaurus-task): asked for a
        // Python script, the model wrote the script (or offered to co-write
        // it) instead of delegating. The delegation rubric must still say to
        // never produce the work in chat — the orchestrator spawns a
        // specialist and relays the result.
        let compact = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
            compact: true
        )
        #expect(
            compact.contains("never produce that work in chat"),
            "compact prompt must forbid doing the work in chat")
    }

    @Test
    func render_listsAlwaysAvailableReadTools() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        #expect(rendered.contains("osaurus_inspect"))
    }

    @Test
    func render_teachesHelpToolForOsaurusQuestionsInBothVariants() {
        // Configure+explain revamp: both variants must (a) name
        // `osaurus_help` as the way to answer questions about Osaurus,
        // (b) tell the model to ground answers in the topic text instead
        // of guessing from memory, and (c) never deflect Osaurus questions
        // as out-of-scope.
        for compact in [false, true] {
            let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
                domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])],
                compact: compact
            )
            #expect(rendered.contains("osaurus_help"))
            #expect(rendered.contains("answer"))
            #expect(rendered.lowercased().contains("memory") || rendered.contains("from its text"))
        }
    }

    @Test
    func render_routesNonOsaurusWorkToDelegation() {
        let rendered = DefaultAgentSystemPromptBuilder._renderForTests(
            domains: [Self.probe(id: "providers", writeToolNames: ["osaurus_provider"])]
        )
        // Non-Osaurus asks are delegated (create the agent via an
        // `osaurus_config` apply, then spawn it), never refused flatly and
        // never handed off by suggesting the user switch agents.
        #expect(rendered.contains("Delegation"))
        #expect(rendered.contains("osaurus_config"))
        #expect(rendered.contains("create"))
        #expect(rendered.contains("spawn_agent"))
        // `active_agent` stays documented as the NEW-chats pointer only.
        #expect(rendered.contains("active_agent"))
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
        // every write tool by name, the delegation contract, the declarative
        // YAML workflow) with trimmed prose. Neither variant teaches the
        // capability-search protocol.
        #expect(compact.contains("osaurus_inspect"))
        #expect(compact.contains("`osaurus_provider`"))
        #expect(compact.contains("`osaurus_model`"))
        #expect(compact.contains("action"))
        #expect(compact.contains("Delegation"))
        #expect(compact.contains("osaurus_config"))
        #expect(!compact.contains("capabilities_load"))
        #expect(!compact.contains("capabilities_discover"))
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
