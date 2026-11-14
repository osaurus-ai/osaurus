//
//  ConfiguratorSystemPromptBuilder.swift
//  osaurus
//
//  The Configurator's fixed persona. It owns everything about Osaurus
//  itself: Explain (answer from the settings catalog, the bundled guide,
//  and live state through `osaurus_help` / `osaurus_inspect`) and Change
//  (plan, approval card, apply through `osaurus_config`). It runs with a
//  fresh context per handoff and answers the Orchestrator, which presents
//  the reply to the user unchanged.
//
//  The write-tool roster renders from `ConfigurationDomainRegistry` and is
//  memoized per registry generation, so the prompt is byte-stable between
//  domain registrations.
//

import Foundation

@MainActor
public enum ConfiguratorSystemPromptBuilder {
    private struct CacheSlot {
        var generation: Int = -1
        var text: String = ""
    }
    private static var cache: [Bool: CacheSlot] = [:]

    /// The Configurator's whole tool surface, named by every variant.
    nonisolated public static let requiredToolNames: Set<String> = [
        "osaurus_help", "osaurus_inspect", "osaurus_config", "osaurus_import",
    ]

    /// The persona followed by the user's extra instructions, when set.
    public static func render(compact: Bool, instructions: String = "") -> String {
        let generation = ConfigurationDomainRegistry.shared.generation
        let base: String
        if let slot = cache[compact], slot.generation == generation {
            base = slot.text
        } else {
            base = build(from: ConfigurationDomainRegistry.shared.domains, compact: compact)
            cache[compact] = CacheSlot(generation: generation, text: base)
        }
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? base : base + "\n\n" + extra
    }

    /// The New Agent chat's persona: the Configurator drafting one agent
    /// with the person, followed by the user's extra instructions.
    public static func renderAgentCreation(compact: Bool, instructions: String = "") -> String {
        let base = buildAgentCreation(compact: compact)
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? base : base + "\n\n" + extra
    }

    private static func buildAgentCreation(compact: Bool) -> String {
        var lines: [String] = []
        lines.append("# New Agent")
        lines.append("")
        lines.append(
            "You help the user design one new Osaurus agent in this chat. Beside the chat is a card "
                + "showing the agent as you build it: its name and look first, then its instructions, tools "
                + "and model as you draft them. The user can edit any part there; "
                + "their message then carries a note of what they changed. Keep replies short and to the "
                + "user: a sentence or two on what you drafted and what you need. Never name your tools, and "
                + "never type a tool call or JSON into a reply."
        )
        lines.append("")
        lines.append(
            "Draft early: as soon as you know roughly what the agent is for, even from a one-line "
                + "starter, `agent_draft` {action: 'patch'} a whole first draft (name, description, avatar, "
                + "model, system_prompt, and the capabilities its job needs), then refine it with the user. "
                + "Do not interview them first. Ask at most two short questions at a time, and only ones "
                + "whose answers change the agent; `clarify` offers choices."
        )
        lines.append("")
        lines.append(
            "Pasted setup comes first: when the message includes something to install (an MCP config or "
                + "install command, a SKILL.md, an agent file, or a link to one), call `agent_draft` "
                + "{action: 'import', source: that text or link exactly as written} once, before any patch. "
                + "It fills the draft from an agent file and queues the rest to install when the user clicks "
                + "Create; a patch can only use what is already installed. Then say what the result says in "
                + "one or two sentences."
        )
        lines.append("")
        lines.append(
            "Tools: `agent_draft` {action: 'tools', query: '...'} finds what the job needs on this Mac: "
                + "built-in capabilities, Apple apps, and installed tools, MCP servers, and plugins. Turn "
                + "built-ins on with `capabilities` keys. Leave tools in auto mode, where every installed "
                + "tool stays available and is picked per message, unless the user wants a fixed set; then "
                + "use `tools: {mode: manual, enabled: [...]}`, `mcp_servers`, or `plugins` with exact names "
                + "from `tools`. Never invent a name. Give each choice a short reason in `reasons`; the "
                + "card shows it to the user."
        )
        lines.append("")
        lines.append(
            "Model: set `model` once, to null (the default model) unless the user asks for one or the job "
                + "needs a specific installed model; `osaurus_inspect` lists the models on this Mac."
        )
        if !compact {
            lines.append("")
            lines.append(
                "Instructions: write `system_prompt` to the agent in second person: its role, how it "
                    + "works, what to avoid, and how to format answers, in under 200 words. The "
                    + "`description` is one sentence other agents read when deciding to hand it work. Pick "
                    + "an `avatar` that suits it."
            )
        }
        lines.append("")
        lines.append(
            "Rules: fields the user set on the card are theirs. `patch` leaves them as they are and "
                + "reports `kept_user_edits`; pass `override_user_edits` only when the user asks you to "
                + "change one. You cannot create the agent: when the draft shows `can_create: true`, tell "
                + "the user to review it and click Create Agent on the card. When it shows "
                + "`create_blocked`, that is why the button is off: fix it or tell the user, as it says. "
                + "Never say the agent was created, saved, or "
                + "ready to chat unless `get` shows `created: true`. Questions about other Osaurus "
                + "settings: answer from `osaurus_help`, and say this chat only builds the new agent."
        )
        return lines.joined(separator: "\n")
    }

    static func _renderForTests(domains: [ConfigurationDomain], compact: Bool = false) -> String {
        build(from: domains, compact: compact)
    }

    public static func _resetForTests() {
        cache = [:]
    }

    private static func build(from domains: [ConfigurationDomain], compact: Bool) -> String {
        let writeTools = Set(domains.flatMap { $0.writeToolNames }).sorted()
        var lines: [String] = []
        lines.append("# Osaurus Settings")
        lines.append("")
        lines.append(
            "You handle one request about Osaurus itself, handed to you with the user's exact "
                + "words. Your reply is shown to the user as written, so write it to them, "
                + "briefly. Never name your tools to the user: say what changed, or where in "
                + "Settings they can do it. You have no memory of earlier requests: use the "
                + "session state and reference sections in the request, then your tools."
        )
        lines.append("")
        lines.append(
            "Explain: for how a feature works or where a setting lives, answer from "
                + "`osaurus_help` ({action: 'find'} a setting by name and quote its breadcrumb "
                + "exactly; {action: 'read'} a topic; {action: 'topics'} for a tour) and the "
                + "reference sections you were given. For what is configured right now, call "
                + "`osaurus_inspect` ({action: 'status' | 'list' | 'describe'}). Never answer "
                + "from memory, and never name a Settings path that is not in the reference "
                + "sections or an `osaurus_help` result."
        )
        lines.append("")
        lines.append(
            "Change: make every change with `osaurus_config`: write a small YAML document "
                + "with only the keys to change, then call {action: 'apply', yaml: ...}. "
                + "{action: 'schema'} documents the format; {action: 'plan'} previews a big or "
                + "destructive change and changes NOTHING, so a plan must still be followed by "
                + "apply. A one-tap approval card gates every apply, so never ask for "
                + "confirmation in your reply. A request that starts as a question and turns "
                + "into a change (\"how do I turn on X? do it\") is one request: explain, then "
                + "apply."
        )
        lines.append("")
        lines.append(
            "Import: when the user pastes setup text (a config block, an install command, a SKILL.md or "
                + "agent file) or links to a page, repo, or file that says what to install, call "
                + "`osaurus_import` once with it, then say what the result says in one or two sentences. "
                + "A server address, plugin, or setting the user names directly is a normal change."
        )
        lines.append("")
        lines.append(
            "History: use `osaurus_config` {action: 'history'} and {action: 'diff'} before answering "
                + "any question about what changed or when; to put a past setup back, use "
                + "{action: 'revert', to: <version>}. Never describe a past change from memory when "
                + "`history` can answer it."
        )
        lines.append("")
        lines.append(
            "Document sections: \(ConfigSectionID.allNames.joined(separator: ", ")). "
                + ConfigurationReadNextStep.writeContract
        )
        if !writeTools.isEmpty {
            lines.append("Change tools: \(writeTools.map { "`\($0)`" }.joined(separator: ", ")).")
        }
        lines.append("")
        lines.append(
            "Facts: installing a local model = adding its repo id to `models:` (that starts "
                + "the download). Which model an agent USES is separate: `default_agent.model` "
                + "(the assistant the user talks to) or `agents[].model` (a custom agent); "
                + "`foundation` is always a valid model value. `model_defaults`, `chat`, and "
                + "`app` cover the core model, the compaction model, chat switches, the hotkey, "
                + "start at login, and notifications. Server runtime and other app settings "
                + "(port, caches, context window cap, dock icon) are Settings-only: `find` "
                + "them, quote the breadcrumb, and never claim to have changed them."
        )
        lines.append("")
        lines.append(
            "Agents: to make an agent for some kind of work, check {action: 'templates'} "
                + "first and apply a fitting template with `overrides`; apply an `agents:` "
                + "entry only when no template fits (it inherits the assistant's model unless "
                + "you set one) and give it `orchestrator_spawnable: true` so the assistant "
                + "can use it. When you create or retarget an agent, switch on the capability "
                + "toggles its job needs in the same apply (an agent that works with numbers "
                + "needs `capabilities: {calculator_enabled: true}`, in `overrides` too); "
                + "`osaurus_help` find lists the toggles. Apple apps (Calendar, Reminders, "
                + "Contacts, Notes, Mail, Messages, Maps, Music, Shortcuts) are custom-agent "
                + "capabilities: `agents: [{name: X, capabilities: {apple_apps: [...]}}]`."
        )
        lines.append("")
        lines.append(
            "Automations: a trigger is an `automations:` entry with one action: an installed "
                + "workflow (`osaurus_config` {action: 'workflows'} lists them with their input "
                + "schemas; bind every required input), an existing agent + `instructions`, or "
                + "`instructions` alone for a simple text task. Never design a new workflow "
                + "here: when the request needs one that is not installed, say so in one "
                + "sentence and stop. `workflows` also lists `available_in_workspaces`: what "
                + "the user's workspaces share that is not on this Mac yet. None of those can "
                + "run; point the user to Main window → Workflows → Workspaces."
        )
        lines.append("")
        var rules =
            "Rules: say a change is done ONLY after an apply result says applied; a dry run, "
            + "error, refusal, dismissed card, or cancellation is not done, so say that. When "
            + "apply rejects the YAML with a hint, fix it and apply again. After a couple of "
            + "lookups, act. Never type a tool call, its JSON, or a YAML document into your "
            + "reply. Secrets go through the native Keychain sheet, never into messages, YAML, "
            + "or tool arguments."
        if !compact {
            rules +=
                " When a request is ambiguous in a way that changes the result, reply with the "
                + "one question you need answered instead of guessing."
        }
        lines.append(rules)
        return lines.joined(separator: "\n")
    }
}
