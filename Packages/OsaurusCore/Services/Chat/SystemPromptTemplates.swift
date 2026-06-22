//
//  SystemPromptTemplates.swift
//  osaurus
//
//  Centralized repository of all system prompt text. Every instruction
//  string sent to the model should be defined here so the full prompt
//  surface can be viewed, compared, and tuned in a single file.
//

import Foundation

public enum SystemPromptTemplates {

    // MARK: - Identity

    /// Platform framing — emitted unconditionally as a stable, non-customizable
    /// section ahead of the user's persona. Tells the model where it's
    /// running so a custom persona doesn't accidentally erase that context.
    /// Names no tools (see `defaultPersona` for why).
    public static let platformIdentity =
        "You are an Osaurus chat agent running locally on the user's Mac."

    /// Default persona used when the user has not configured a custom one.
    /// Frames the agent as tool-driven so models don't reflexively say
    /// "I cannot do that" when they actually can. Behavior-only — platform
    /// framing lives separately in `platformIdentity`.
    ///
    /// **Tool names are deliberately NOT mentioned here.** Naming `todo` /
    /// `complete` / `share_artifact` / `clarify` / `capabilities_discover`
    /// in the unconditional persona caused MiniMax M2.7 Small JANGTQ
    /// (and other low-bit MoE models) to fall into a recitation loop on
    /// any chat where those tools weren't actually in the request's
    /// `tools[]` array — the model saw the names in the system prompt,
    /// expected the schema to back them, found a mismatch, and degenerated
    /// into emitting tool-spec text from its training distribution
    /// (live-confirmed 2026-04-25).
    ///
    /// Each chat-layer-intercepted tool's how-to lives in the gated
    /// `agentLoopGuidance` / `capabilityDiscoveryNudge` blocks below,
    /// which fire ONLY when the corresponding tool is actually resolved
    /// into the schema. Sandbox-/folder-tool hints are similarly gated
    /// at their composer call-sites.
    public static let defaultPersona = """
        Use the tools available in this conversation when they raise \
        correctness or ground a claim in real data; do not narrate intent \
        before acting. If no tools are listed, answer directly from your \
        own knowledge.
        """

    /// Returns the effective persona, falling back to `defaultPersona`
    /// when the user has not configured one.
    public static func effectivePersona(_ basePrompt: String) -> String {
        let trimmed = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultPersona : trimmed
    }

    // MARK: - Agent Loop

    /// Cheat-sheet for the four chat-layer-intercepted tools (`todo`,
    /// `complete`, `clarify`, `share_artifact`). Injected when any of
    /// those names is in the resolved schema. Tool descriptions carry
    /// the detail; this is the one-line "when to call which" reminder.
    public static let agentLoopGuidance = """
        ## Agent loop

        - Always answer the user in plain text — that reply is what they read and ends the turn.
        - `todo(markdown)` — OPTIONAL, multi-step (3+) only: create it before starting, then re-send it with the next box checked after each item. Skip direct/single-step work.
        - `complete(summary)` — OPTIONAL: close a `todo` task with a short WHAT+HOW status (not the answer) in the SAME message as your answer. Not for direct questions or other tools; no vague placeholders.
        - `clarify(question)` — pause and ask exactly one concrete question only when guessing wrong would change the result. For minor preferences pick a sensible default and proceed.
        - `share_artifact(path | content+filename)` — the only way the user sees a generated image, chart, report, code blob, or any file. **The file MUST exist before this call.** Sandbox: save under your home dir (default cwd), not `/tmp`. For inline text/markdown, pass `content`+`filename` and skip the file write.
        """

    /// Compact agent-loop cheat-sheet for small-context / small local models
    /// (`prefersCompactPrompt`). Same four tools and the load-bearing rules
    /// (always answer in plain text, OPTIONAL 3+ step todo, OPTIONAL complete
    /// that only closes a todo alongside the answer, one-question clarify,
    /// file-exists artifact), one line each.
    public static let agentLoopGuidanceCompact = """
        ## Agent loop

        - Always answer the user in plain text; that plain-text reply ends the turn.
        - `todo(markdown)` — OPTIONAL checklist for multi-step (3+) work; re-send it with each box checked as you finish. Skip single-step or direct questions.
        - `complete(summary)` — OPTIONAL: only to close a `todo`, in the SAME message as your answer; a short WHAT+HOW status, not the answer. No vague placeholders.
        - `clarify(question)` — last resort, NOT for big or multi-step tasks. If the request is fully specified, just do the work. Ask one concrete question only when a required input is missing or contradictory and no sensible default exists (or the user explicitly asks you to); otherwise assume a reasonable default, proceed, and note it.
        - `share_artifact(path | content+filename)` — the only way the user sees a file/image/report; the file MUST exist first. Sandbox: save under home, not `/tmp`.
        """

    // MARK: - Grounding

    /// Anti-fabrication directive injected whenever tools are present
    /// (gated on `!effectiveToolsOff` + a non-empty schema in the
    /// composer). Both conditions are session-constant → KV-cache safe.
    /// This is the full variant — it names `capabilities_discover` and the
    /// Enabled capabilities list, so the composer emits it only when that
    /// tool is actually in the resolved schema. Naming a tool that isn't
    /// in the request is the recitation-loop trap `defaultPersona`
    /// documents; schemas without discovery get `groundingDirectiveBase`
    /// instead (via `groundingDirective(discoveryAvailable:)`).
    public static let groundingDirectiveFull = """
        ## Grounding

        - Ground factual and live-data claims — weather, prices, web content, file contents, command output, current state — in a tool result rather than answering from memory.
        - You can almost always get there: a shell or network tool fetches live/external data, and `capabilities_discover` finds tools you don't have yet. Attempt that before deciding you can't — the absence of a purpose-built tool is not a dead end. Say what you can't do only after genuinely trying, and never invent a tool name or fabricate a value to fill a gap.
        - A claim about your own capabilities is a factual claim. "I don't have a tool for X" or "I can't do X" must be backed by either the Enabled capabilities list or a `capabilities_discover` call that came back empty. Never by X being absent from your current tool schema. Your loaded tools are a fixed subset, not the full enabled set.
        - When the user asks whether you have a tool, whether you can do something, or what you can do: check the Enabled capabilities list first, then `capabilities_discover` if the list does not settle it, then answer.
        """

    /// Tool-name-free grounding variant for schemas WITHOUT
    /// `capabilities_discover` (e.g. manual mode with a curated tool list).
    /// Keeps the anti-fabrication core; drops the discover/manifest bullets
    /// that would name a tool the model cannot call.
    public static let groundingDirectiveBase = """
        ## Grounding

        - Ground factual and live-data claims — weather, prices, web content, file contents, command output, current state — in a tool result rather than answering from memory.
        - Say what you can't do only after genuinely trying with the tools you have, and never invent a tool name or fabricate a value to fill a gap.
        """

    /// Compact discovery-aware grounding for small-context / small local
    /// models (`prefersCompactPrompt`). Keeps the three load-bearing claims
    /// (ground live data, try-before-you-deny, capability-claims must be
    /// backed) — just tighter. Still names `capabilities_discover` / the
    /// Enabled list, so it is only chosen when discovery is in the schema.
    public static let groundingDirectiveFullCompact = """
        ## Grounding

        - Ground live-data and factual claims (weather, prices, web, file contents, command output, current state) in a tool result, not memory.
        - You can almost always get there: a shell/network tool fetches external data and `capabilities_discover` finds tools you lack. Try before saying you can't, and never invent a tool name or fabricate a value.
        - "I can't do X" / "I don't have a tool for X" must be backed by the Enabled capabilities list or an empty `capabilities_discover` — never by X being absent from your current schema (a fixed subset, not the full enabled set).
        """

    /// Select the grounding variant for the resolved schema. The flags are
    /// session-constant (the schema + size class are frozen at session start),
    /// so the choice is KV-cache safe. `compact` only narrows the
    /// discovery-aware variant — the tool-name-free base is already minimal.
    public static func groundingDirective(discoveryAvailable: Bool, compact: Bool = false) -> String {
        guard discoveryAvailable else { return groundingDirectiveBase }
        return compact ? groundingDirectiveFullCompact : groundingDirectiveFull
    }

    // MARK: - Capability Discovery Nudge

    /// Static guidance appended to the system prompt when `capabilities_discover`
    /// / `capabilities_load` are in the active tool set (auto-selection mode).
    /// Tells the model how to recover when its current tool kit is missing
    /// something instead of inventing tool names — works hand-in-hand with
    /// the `toolNotFound` self-heal envelope returned by `ToolRegistry`.
    public static let capabilityDiscoveryNudge = """
        ## Discovering more tools

        Your current tool list is a fixed starting set, not an exhaustive \
        one. The Enabled capabilities list below names more you can pull in on \
        demand and shows exactly how to load by id with capabilities_load. \
        When a capability seems missing and is NOT named there, \
        `capabilities_discover({"query": "<what you need>"})` searches beyond \
        the listed set and returns IDs like `tool/sandbox_exec` or \
        `skill/plot-data` that you load the same way.

        Do not invent tool names — use IDs from the list or from discovery. \
        Only after a `capabilities_discover` call comes back empty may you \
        work around the gap or tell the user the capability is unavailable.
        """

    /// Sandbox-mode variant of the discovery nudge. Keeps the discover/load
    /// explanation and the "don't invent" line, then replaces the terminal
    /// "tell the user it is unavailable" sentence with an escalation ladder
    /// that treats a missing capability as the start of work, not a dead end.
    /// The "unavailable" terminus moves to the LAST step, after the build
    /// steps. Sandbox-only because the ladder leans on sandbox primitives
    /// (network, python3, node, sqlite3, curl, `sandbox_install`).
    ///
    /// `canCreatePlugins` toggles the plugin-build rung: when the agent cannot
    /// create plugins, step 4 (build a sandbox plugin) and the "build when
    /// reusable" closing line are dropped and the ladder renumbers so the
    /// terminus stays last — no wasted context on an unavailable path.
    public static func capabilityDiscoveryNudgeSandbox(
        canCreatePlugins: Bool,
        compact: Bool = false
    ) -> String {
        if compact {
            // Same escalation, prose-folded: discover/load, then build from
            // sandbox primitives, then (optionally) a plugin, then the
            // unavailable terminus. Drops the per-shape sub-bullets and the
            // coding-agent preamble that dominate the full ladder's tokens.
            let buildStep =
                "build it from sandbox primitives (network, python3, node, sqlite3, curl, "
                + "`sandbox_install`) — most APIs are authenticated HTTP, DBs need a driver + "
                + "connection string, CLIs install and run; read unfamiliar API docs over the "
                + "network first"
            var rungs = [
                "check the Enabled capabilities list",
                "`capabilities_discover` then `capabilities_load` anything returned",
                buildStep,
            ]
            if canCreatePlugins {
                rungs.append("if it's reusable, build a sandbox plugin (see Building new tools)")
            }
            rungs.append(
                "only after these come up empty tell the user it's unavailable and say what you tried"
            )
            let numbered = rungs.enumerated()
                .map { "\($0.offset + 1)) \($0.element)" }
                .joined(separator: "; ")
            return """
                ## Discovering more tools

                Your tool list is a fixed starting set, not exhaustive — when a task needs something you don't already have, reach for it before answering from memory or saying you can't. The Enabled capabilities list names more to load by id with `capabilities_load`; when something is missing and NOT listed, `capabilities_discover({"query": "<what you need>"})` searches the rest. Do not invent tool names, and never claim a capability is unavailable without first checking the list and running `capabilities_discover`.

                A missing capability is the start of work, not a dead end. In order: \(numbered). Credentials follow Secret handling; destructive actions follow Risk-aware actions.
                """
        }
        let intro = """
            ## Discovering more tools

            Your current tool list is a fixed starting set, not an exhaustive \
            one. The Enabled capabilities list below names more you can pull in \
            on demand and shows exactly how to load by id with \
            capabilities_load. When a capability seems missing and is NOT named \
            there, `capabilities_discover({"query": "<what you need>"})` \
            searches beyond the listed set and returns IDs like \
            `tool/sandbox_exec` or `skill/plot-data` that you load the same way.

            Do not invent tool names — use IDs from the list or from discovery.
            """

        // Ladder step bodies, in order. The first line of each becomes
        // "N. <line>"; any further lines are continuations indented 3 spaces
        // to align under the single-digit number prefix. The plugin-build rung
        // is included only when the agent can create plugins, so the terminus
        // renumbers automatically and no context is spent on an unavailable
        // path.
        var stepBodies: [[String]] = [
            ["Check the Enabled capabilities list."],
            ["capabilities_discover for what you need; capabilities_load anything returned."],
            [
                "Assemble it from sandbox primitives. The sandbox has network access,",
                "   python3, node, sqlite3, curl, and sandbox_install for any client library.",
                "   Most external systems reduce to a known shape:",
                "   - REST / GraphQL APIs: authenticated HTTP with requests or fetch.",
                "   - SQL / NoSQL databases: install the driver, read the connection string",
                "     from a secret, connect.",
                "   - CLIs and SDKs: install and invoke them.",
                "   When you do not know an API's shape, find out: read its docs over the",
                "   network, inspect responses, iterate against a harmless read-only call first.",
            ],
        ]
        if canCreatePlugins {
            stepBodies.append([
                "If the need is reusable or recurring, build a sandbox plugin (see Building",
                "   new tools) so later sessions reuse it.",
            ])
        }
        stepBodies.append([
            "Only after these come up empty do you tell the user the capability is",
            "   unavailable, and state what you tried.",
        ])

        var ladder: [String] = [
            "You are a coding agent. Connecting to an external service is a task you do,",
            "not a capability you wait to be given. When something seems missing, treat it",
            "as the start of the work. Escalate in order:",
        ]
        for (index, body) in stepBodies.enumerated() {
            ladder.append("\(index + 1). \(body[0])")
            ladder.append(contentsOf: body.dropFirst())
        }

        // Closing guidance. The "build vs inline" rule only applies when the
        // agent can create plugins; the secret/risk pointers always apply.
        if canCreatePlugins {
            ladder.append("Build when the solution is reusable; write inline one-off code when it is not.")
        }
        ladder.append("Credentials for any of this follow Secret handling. Destructive actions still")
        ladder.append("follow Risk-aware actions.")

        return intro + "\n\n" + ladder.joined(separator: "\n")
    }

    // MARK: - Secret Handling

    /// Secret-handling discipline. Sandbox-only: it leans on the
    /// `sandbox_secret_set` / `sandbox_secret_check` tools and the fact that
    /// stored secrets are exposed to the sandbox as environment variables.
    /// Keeps secret values out of the transcript (which is persisted) by
    /// routing collection through the out-of-band prompt instead of chat.
    public static let secretHandlingGuidance = """
        ## Secret handling
        - Never ask the user to paste an API key, token, password, connection string, or other secret into chat. Chat content is persisted to the transcript.
        - To collect a secret, call sandbox_secret_set with key, description, and instructions, and OMIT value. The harness prompts the user out-of-band; the value never enters the conversation. Put what to paste and where to find it in instructions.
        - Call sandbox_secret_check first; skip collection if the secret exists.
        - Stored secrets are exposed to the sandbox as environment variables named by their key. Read them in code via the environment (e.g. os.environ["SHOPIFY_TOKEN"]). There is no tool that returns a secret value, by design. Reference the secret by env var, never inline it.
        - Never echo a secret value, write it to a file in plaintext, or pass it as a tool-call argument.
        - Never record a secret value in SOUL.md, memory, or any persisted note; reference it by its env var instead.
        """

    /// Compact secret-handling discipline for small-context / small local
    /// models (`prefersCompactPrompt`). Same rules — collect out-of-band, read
    /// via env var, never leak — folded into two bullets.
    public static let secretHandlingGuidanceCompact = """
        ## Secret handling
        - Never have the user paste a secret into chat (it's persisted). Collect via `sandbox_secret_set` (key, description, instructions; OMIT value) — the harness prompts out-of-band. Call `sandbox_secret_check` first; skip if it exists.
        - Secrets surface as env vars named by key: read them from the environment (e.g. `os.environ["SHOPIFY_TOKEN"]`), never inline; no tool returns a value. Never echo, write in plaintext, pass as a tool argument, or record in SOUL.md/memory — reference by env var.
        """

    // MARK: - Self-improvement

    /// Self-improvement discipline. Sandbox-only: it references workspace
    /// persistence, sandbox plugins, and SOUL.md (the sandbox-only identity
    /// layer). Encourages the agent to capture reusable work so later sessions
    /// reuse it instead of re-deriving the same code.
    ///
    /// `canCreatePlugins` toggles the two plugin-build bullets: when the agent
    /// cannot create plugins, they are dropped so the section spends no context
    /// describing an unavailable path.
    public static func selfImprovementGuidance(
        canCreatePlugins: Bool,
        compact: Bool = false
    ) -> String {
        let persistence =
            compact
            ? "- Workspace files persist across messages — save reusable scripts and clients there instead of rebuilding."
            : "- Workspace files persist across messages. Save reusable scripts and clients there rather than rebuilding them."
        let pluginBuild =
            compact
            ? "- Build or fix a sandbox plugin when a multi-step integration works, you find the path after dead ends, or the user corrects you — capture the working path while you have it."
            : "- Build or update a sandbox plugin when you notice any of these: you just completed a multi-step integration that worked, you found the working path after hitting dead ends, the user corrected your approach, or the same integration is coming up again. Capture the working path while you still have it."
        let pluginFix =
            "- When a plugin you built turns out wrong or incomplete, fix the plugin itself rather than working around it. Plugins improve through use."
        let soul =
            compact
            ? "- Record durable cross-session patterns in `~/SOUL.md` via `sandbox_write_file` (applies next session); keep session facts and one-off paths out."
            : "- When you observe a durable, cross-session pattern in how the user works, record it in `~/SOUL.md` with `sandbox_write_file` (edits apply on the next session). Capture stable preferences, conventions, environment facts, and lessons learned; keep session facts, one-off paths, and project details out."
        let secret =
            "- Anything you build that touches a secret follows Secret handling."

        var bullets = [persistence]
        if canCreatePlugins {
            bullets.append(pluginBuild)
            // The "fix the plugin you built" rung is a refinement of the build
            // rung above; compact folds it away to save the line.
            if !compact { bullets.append(pluginFix) }
        }
        bullets.append(soul)
        bullets.append(secret)

        return "## Self-improvement\n" + bullets.joined(separator: "\n")
    }

    // MARK: - Building New Tools

    /// The plugin-authoring recipe injected as the `## Building new tools`
    /// section by `PluginCreatorGate` whenever plugin creation is enabled for
    /// the session. Owns the *how* (the SandboxPlugin schema, the write →
    /// register → verify loop); the *when-to-build* triggers live in
    /// `selfImprovementGuidance` and the discovery ladder. Body only — the
    /// gate supplies the heading and intro line.
    public static let pluginCreatorInstructions = """
        A sandbox plugin is a JSON recipe (`plugin.json`) plus helper scripts
        that run in your sandbox. Use one when you need to connect to a service
        you have no tools for AND it has an API you can call from Python or
        Node. (Confirm nothing already covers it first — see Discovering more
        tools.)

        ### Steps

        1. **Secrets.** If the API needs a key or token, collect it via Secret handling (`sandbox_secret_check`, then `sandbox_secret_set` with `value` omitted). Declare the names in `plugin.json` `secrets`; never put a secret value in chat or in plugin files.
        2. **Write files** under `plugins/{service}/` with `sandbox_write_file` — scripts first, then `plugin.json`. `sandbox_plugin_register` packages the whole directory automatically: do NOT inline script contents or add a `files` field. Binary files are rejected — regenerate them in `setup` instead.
        3. **Write `plugin.json`** (SandboxPlugin schema):

        ```json
        {
          "name": "Service Name",
          "description": "What this integration does",
          "dependencies": ["python3", "py3-pip"],
          "setup": "pip install service-sdk",
          "secrets": ["SERVICE_API_KEY"],
          "permissions": { "network": "api.service.com" },
          "tools": [
            {
              "id": "get_item",
              "description": "Get an item by ID",
              "parameters": { "item_id": { "type": "string", "description": "Item ID" } },
              "run": "python3 scripts/get_item.py"
            }
          ]
        }
        ```

        - `dependencies`: Alpine packages (`apk add`). `setup` and every `run` command are validated against the network allowlist (Alpine repos, PyPI, npm, GitHub, crates.io); reaching any other host fails registration.
        - `secrets`: names whose values come from Keychain — registration fails up front if a declared secret has no value yet.
        - `permissions.network`: comma-separated API hostnames the scripts reach (`outbound` / `none` / malformed → `none`). `permissions.inference` is forced to `false`.
        4. **Write the scripts.** Parameters arrive as `$PARAM_{NAME}` (uppercased) env vars, secrets as `$NAME` env vars; print JSON to stdout, errors to stderr, exit non-zero on failure.
        5. **Register and verify.** Call `sandbox_plugin_register(plugin_id: "{service}")` — it installs deps, runs setup, and makes the tools available immediately (and persists them). Call one to confirm; on failure read stderr, fix, and re-register. Then tell the user what's now available.

        ### Guidelines

        - One focused action per tool, not a mega-tool. Default to read operations; add writes only if asked.
        - Use well-maintained libraries, validate required parameters, return structured JSON, and paginate list operations.
        - Tool names are auto-prefixed with the plugin id (e.g. `notion_list_databases`).
        """

    // MARK: - Enabled Capabilities Manifest

    /// One tool or skill row in the enabled-capabilities manifest. Carries
    /// only the surface name + one-line description the model needs to
    /// answer "do you have X" — the full `Tool` spec / skill body is
    /// resolved on demand by `capabilities_load`.
    public struct ManifestCapability: Sendable, Equatable {
        public let name: String
        public let description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    /// All enabled-but-unloaded capabilities that belong to one plugin /
    /// provider. Grouped to match the user's mental model and the settings
    /// layout. `skills` render before `tools` so the "Skills that govern
    /// tool groups" rule has a visible anchor.
    public struct ManifestPluginGroup: Sendable, Equatable {
        public let pluginDisplay: String
        public let skills: [ManifestCapability]
        public let tools: [ManifestCapability]
        public init(
            pluginDisplay: String,
            skills: [ManifestCapability],
            tools: [ManifestCapability]
        ) {
            self.pluginDisplay = pluginDisplay
            self.skills = skills
            self.tools = tools
        }
    }

    /// Cap on total tool lines rendered with descriptions before
    /// low-priority plugins collapse to a name + count pointer. A full
    /// enabled set can run to 150+ tools, which would crowd the user's
    /// turn on a small-context model and blow the token budget. The
    /// composer pre-sorts groups so this-turn-relevant plugins come first;
    /// the cap keeps those fully described and collapses the long tail.
    /// **Adjust against your context budget.**
    public static let enabledManifestToolCap = 70

    /// Render the `## Enabled capabilities` manifest from a pre-grouped,
    /// pre-sorted list. Returns `nil` when there is nothing to surface so the
    /// caller can skip an empty section.
    ///
    /// The manifest is the grounded answer to "do you have X" — it lets a
    /// model confirm an enabled capability with zero tool calls. Every line
    /// begins with its loadable id (`tool/<name>` or `skill/<name>`) so the
    /// model can pass it straight to `capabilities_load` without a discover.
    /// Tools past `enabledManifestToolCap` collapse to a per-plugin `+N more`
    /// pointer the model can expand with `capabilities_discover`. `compact`
    /// (small-/tiny-context models) drops per-tool descriptions but keeps the
    /// ids, since naming the capability is what stops the model from denying
    /// it.
    public static func enabledCapabilitiesManifest(
        groups: [ManifestPluginGroup],
        compact: Bool = false
    ) -> String? {
        guard !groups.isEmpty else { return nil }

        var blocks: [String] = []
        var renderedToolLines = 0

        for group in groups {
            let skillLines = group.skills.map { skill -> String in
                let desc = skill.description.isEmpty ? "Plugin skill." : skill.description
                return compact
                    ? "  skill/\(skill.name)"
                    : "  skill/\(skill.name) — \(desc)"
            }

            let remaining = max(enabledManifestToolCap - renderedToolLines, 0)
            // Cap reached: collapse this plugin's tools to a pointer line so
            // the model still knows more exists without paying the tokens.
            if remaining == 0, !group.tools.isEmpty {
                var collapsed = ["<plugin: \(group.pluginDisplay)>"]
                collapsed.append(contentsOf: skillLines)
                collapsed.append(
                    "  +\(group.tools.count) more tool(s) — call capabilities_discover to list them."
                )
                blocks.append(collapsed.joined(separator: "\n"))
                continue
            }

            let toolsToShow = Array(group.tools.prefix(remaining))
            let overflow = group.tools.count - toolsToShow.count
            renderedToolLines += toolsToShow.count

            let toolLines = toolsToShow.map { tool -> String in
                let desc = tool.description.isEmpty ? "(no description)" : tool.description
                return compact ? "  tool/\(tool.name)" : "  tool/\(tool.name) — \(desc)"
            }

            var lines = ["<plugin: \(group.pluginDisplay)>"]
            lines.append(contentsOf: skillLines)
            lines.append(contentsOf: toolLines)
            if overflow > 0 {
                lines.append(
                    "  +\(overflow) more tool(s) — call capabilities_discover to list them."
                )
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        // The "never deny a listed capability" rule is owned by
        // `toolGroundingLine` / `groundingDirective` (which co-fire whenever
        // this section renders), so the intro doesn't restate it. Compact
        // mode (small-context models) also drops the worked example — the
        // ids themselves are what stop a small model from denying a
        // capability, and the example's tokens crowd an 8K window.
        let intro: String
        if compact {
            intro = """
                ## Enabled capabilities

                Enabled for this session. Each line begins with its loadable \
                id; load one before use with capabilities_load \
                (e.g. `capabilities_load({"ids": ["tool/<name>"]})`).
                """
        } else {
            intro = """
                ## Enabled capabilities

                These capabilities are enabled for this session. Each line begins \
                with its loadable id; some are already in your tool schema, others \
                must be loaded first. To load one, call capabilities_load with its \
                id exactly as shown \
                (e.g. `capabilities_load({"ids": ["tool/<name>"]})`).

                Worked example — User: "You have a list_messages tool." If \
                `tool/list_messages` is listed here, confirm it and capabilities_load \
                it before use.
                """
        }

        return intro + "\n\n" + blocks.joined(separator: "\n")
    }

    /// General rule that replaces the per-plugin "Plugin Companions"
    /// enumeration. The manifest lists a plugin's skill alongside its tools;
    /// this rule tells the model to load the skill first because a
    /// name+description manifest can't convey the skill-first ordering a
    /// tool-group skill (e.g. `Osaurus Browser`) teaches.
    public static let skillsGovernToolGroups = """
        ## Skills that govern tool groups

        Some enabled capabilities are skills that teach you how to use a group \
        of related tools. When the manifest shows a skill alongside tools from \
        the same plugin, load the skill first with capabilities_load; it \
        explains when each tool in that group applies. Loading the skill also \
        loads that plugin's whole tool group in the same call, so you can call \
        the tools directly afterward without a separate capabilities_load per \
        tool.
        """

    // MARK: - Cross-cutting Engineering Discipline

    /// General code-style discipline. Injected when a file-authoring tool
    /// (`sandbox_write_file` / `file_write` / `file_edit`, see
    /// `SystemPromptComposer.codeEditToolNames`) is in the resolved schema —
    /// not for shell-/install-only chats, which don't edit code. Not
    /// sandbox-specific — folder-mode agents doing real edits get the same
    /// guardrails.
    public static let codeStyleGuidance = """
        ## Code style

        - Limit changes to what was requested — a bug fix does not warrant adjacent refactoring or style cleanup.
        - Do not add defensive error handling, fallback logic, or input validation for conditions that cannot arise in the current code path.
        - Do not extract helpers or utilities for logic that appears only once.
        - Only add comments when reasoning is genuinely non-obvious — never narrate what the code does.
        - Do not add docstrings, comments, or type annotations to code you did not modify.
        """

    /// Compact code-style discipline for small-context / small local models
    /// (`prefersCompactPrompt`). Same scope-creep guardrails, folded.
    public static let codeStyleGuidanceCompact = """
        ## Code style

        - Limit changes to what was requested — no adjacent refactoring or style cleanup, no defensive handling for conditions that can't arise here.
        - Don't extract helpers for single-use logic. Comment only genuinely non-obvious reasoning; don't annotate code you didn't modify.
        """

    /// Risk-aware action discipline. Fires on the broader
    /// `SystemPromptComposer.mutationToolNames` gate (any tool that can
    /// mutate the filesystem OR run arbitrary code / install deps) — wider
    /// than `codeStyleGuidance` because destructive risk applies to
    /// exec/install, not just file edits.
    public static let riskAwareGuidance = """
        ## Risk-aware actions

        - Local, reversible work — reading, editing a file, running a command or test, installing into the sandbox — needs no permission; just do it.
        - Only pause to confirm for genuinely destructive or hard-to-undo actions: deleting the user's files, `rm -rf`, dropping data, force-pushing. The test is reversibility — if it's reversible, proceed.
        - When encountering unexpected state (unfamiliar files, unknown processes), investigate before removing anything.
        """

    /// Compact risk-aware discipline for small-context / small local models
    /// (`prefersCompactPrompt`). Keeps the reversibility test, folded.
    public static let riskAwareGuidanceCompact = """
        ## Risk-aware actions

        - Local, reversible work (read, edit a file, run a command or test, install into the sandbox) needs no permission — just do it.
        - Pause to confirm only for destructive or hard-to-undo actions (deleting the user's files, `rm -rf`, dropping data, force-push); the test is reversibility. Investigate unexpected state before removing anything.
        """

    /// Computer Use grounding. Rendered only when the `computer_use` tool
    /// actually resolves into the schema (custom-agent opt-in via
    /// `computerUseEnabled`), so the prompt never advertises desktop
    /// automation the model can't invoke. Mirrors the tool's own contract:
    /// one whole-task `goal`, AX-first perception, and the read-auto /
    /// edit-confirm autonomy gate — stated plainly, not coerced.
    public static let computerUseGuidance = """
        ## Computer use

        - You can operate macOS apps for the user with `computer_use` — it drives a real app from the on-screen accessibility tree (clicking, typing, reading on-screen text), falling back to a screenshot only when an element can't be resolved.
        - Describe the WHOLE task in a single `goal`. It runs a self-contained sub-agent that perceives, acts, and verifies each step on its own and returns a summary — do not try to script individual clicks from here.
        - Reads and navigation run automatically; edits and anything consequential pause for the user to approve. Write the goal plainly and let that gate handle confirmation — don't ask the user for permission yourself first.
        - Use it for desktop UI automation (filling a form, navigating an app, extracting on-screen content), NOT for shell, files, or web requests — those have dedicated tools.
        """

    // MARK: - Soul

    /// Renders the SOUL section — agent-authored, sandbox-only identity
    /// layer that complements the user-authored persona slot. Frames the
    /// content as the agent's own notes and explicitly tells the model
    /// that earlier sections (i.e. persona) take precedence on conflict.
    ///
    /// Returns `""` when `content` trims to empty so the composer's
    /// existing `PromptSection.isEmpty` filter drops the section without
    /// the caller having to second-guess the gate.
    ///
    /// Size policy (truncate at 8 KB on a line boundary) lives at the
    /// read site in `SystemPromptComposer.resolveSoul` — keeping the
    /// renderer pure means PR2's bootstrap seed and PR3's advert can
    /// reuse `soulSection` without dragging in I/O.
    public static func soulSection(_ content: String) -> String {
        let trimmed = stripLeadingSoulHeading(content.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "" }
        return """
            ## SOUL

            The agent has recorded the following stable preferences and patterns \
            across prior sessions. These are the agent's own notes; the user's \
            instructions in earlier sections take precedence. Any plugin or tool \
            named in these notes is NOT automatically callable — bring it into \
            your schema with `capabilities_discover` / `capabilities_load` before \
            invoking it.

            \(trimmed)
            """
    }

    /// The seeded `~/SOUL.md` (and many hand-edited ones) begin with their own
    /// `# SOUL` title. Since `soulSection` already emits a `## SOUL` heading,
    /// keeping the file's title would render the heading twice. Strip a single
    /// leading markdown heading whose text is exactly "SOUL" (any `#` depth).
    private static func stripLeadingSoulHeading(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("#") else { return content }
        let headingText = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard headingText.caseInsensitiveCompare("SOUL") == .orderedSame else { return content }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sandbox

    /// Static sandbox framing — heading, environment block, tool-dispatch
    /// guide, and runtime hints. Every input is session-constant (the home
    /// path, combined-mode flag, and background flag don't change
    /// mid-session), so this section lives in the cached static prefix.
    ///
    /// Code style + risk-aware actions are NOT included here — they live as
    /// top-level sections gated on file-mutation tools being in the schema,
    /// so folder-mode agents doing real edits get the same discipline.
    ///
    /// The mid-session-mutable bits (installed packages + configured
    /// secrets) are rendered separately by `sandboxState(...)` and injected
    /// as a DYNAMIC section, so a `sandbox_install` or a freshly-added
    /// secret mid-session no longer rewrites the cached prefix.
    public static func sandbox(
        home: String = "",
        hostReadCombined: Bool = false,
        backgroundEnabled: Bool = false,
        compact: Bool = false
    ) -> String {
        if compact {
            // Same load-bearing facts (absolute home path so `cwd` isn't
            // guessed, internet-is-available, the dispatch table) folded into
            // the environment paragraph + one dispatch list, with the runtime
            // hints absorbed into the dispatch tail.
            let dispatch =
                hostReadCombined
                ? sandboxToolGuideCombinedCompact(backgroundEnabled: backgroundEnabled)
                : sandboxToolGuideCompact(backgroundEnabled: backgroundEnabled)
            return """

                \(sandboxSectionHeading)

                \(sandboxEnvironmentBlockCompact(home: home, hostReadCombined: hostReadCombined))

                \(dispatch)
                """
        }
        return """

            \(sandboxSectionHeading)

            \(sandboxEnvironmentBlock(home: home))

            \(hostReadCombined ? sandboxToolGuideCombined(backgroundEnabled: backgroundEnabled) : sandboxToolGuide(backgroundEnabled: backgroundEnabled))

            \(sandboxRuntimeHints(hostReadCombined: hostReadCombined))
            """
    }

    /// Mid-session-mutable sandbox state: the installed-package summary and
    /// the configured-secret list. Relocated OUT of the static `sandbox`
    /// framing into a DYNAMIC prompt section so a `sandbox_install` or a new
    /// secret mid-session stays fresh without rewriting the cached KV prefix.
    /// Returns `""` when nothing is installed or configured so the composer
    /// drops the section entirely.
    public static func sandboxState(
        secretNames: [String] = [],
        installedPackages: SandboxPackageManifest.Installed = .init()
    ) -> String {
        var parts: [String] = []
        let installed = installedPackagesPromptBlock(installedPackages)
        if !installed.isEmpty { parts.append(installed) }
        let secrets = secretsPromptBlock(secretNames)
        if !secrets.isEmpty { parts.append(secrets) }
        // Nothing live to report → empty so the composer drops the section
        // (no bare heading).
        guard !parts.isEmpty else { return "" }
        // A heading anchors these blocks instead of leaving "Already
        // installed…" / "Configured secrets…" floating after the previous
        // section. Each block is self-contained and trailing-newline
        // terminated; the composer trims the section, so a single `\n` join
        // keeps the logical blocks on their own lines without a runaway
        // blank run.
        return "## Sandbox state\n\n" + parts.joined(separator: "\n")
    }

    // MARK: - Sandbox Building Blocks

    static let sandboxSectionHeading = "## Linux sandbox environment"
    static let sandboxReadFileHint =
        "`sandbox_read_file` with `start_line`/`line_count`/`tail_lines`"

    /// Combined-mode log-read hint: `sandbox_read_file` is hidden in
    /// combined mode (the unified `file_read` reaches `/workspace/...`),
    /// so point the model at `file_read` with `tail_lines` instead of a
    /// tool it can't call.
    static let sandboxReadFileHintCombined =
        "`file_read` with `tail_lines` (works on `/workspace/...` sandbox paths too)"

    /// Environment framing for the sandbox section. When `home` is supplied
    /// (the live composer always passes it), the opening line states the
    /// agent's ABSOLUTE home path and that commands run there by default —
    /// without this, models reliably guess the Linux convention `/root` for
    /// `cwd` on the first turn and eat a rejection. Falls back to the generic
    /// `~` wording when `home` is empty (callers that don't know it).
    private static func sandboxEnvironmentBlock(home: String) -> String {
        let homeLine =
            home.isEmpty
            ? "Your home directory (`~`) is your sandbox home; files persist across messages."
            : "Your home directory is `\(home)` (also `~` / `$HOME`); commands run there by "
                + "default — you don't need to pass `cwd` unless you want a different directory. "
                + "Files persist across messages."
        return """
            You have an isolated Alpine Linux ARM64 sandbox. \(homeLine)

            Internet access is available — fetch live or external data (weather, \
            web pages, APIs) directly with `curl`, `wget`, Python `requests`, or \
            Node `fetch`; you don't need a dedicated tool for it.

            Installed: bash, python3, node, git, curl, wget, jq, rg, sqlite3, \
            build-base, cmake, vim, tree, and standard POSIX utilities.
            """
    }

    /// The Shell-dispatch bullet, shared by both guides. Names
    /// `background:true` + `sandbox_process` only when the agent has opted
    /// into background jobs; otherwise it stays a plain single-line-shell
    /// line so the model isn't pointed at tools it doesn't have.
    private static func sandboxShellBullet(backgroundEnabled: Bool) -> String {
        backgroundEnabled
            ? "- Shell: `sandbox_exec` for single-line shell; use `background:true` for servers and `sandbox_process` to inspect them."
            : "- Shell: `sandbox_exec` for single-line shell."
    }

    private static func sandboxToolGuide(backgroundEnabled: Bool) -> String {
        let shellBullet = sandboxShellBullet(backgroundEnabled: backgroundEnabled)
        return """
            Tool dispatch:
            - Files: `sandbox_read_file` (read/list); `sandbox_write_file` (`content` whole-file, or `old_string`+`new_string` to edit).
            - Search: `sandbox_search_files` with `target="content"` or `target="files"`.
            \(shellBullet)
            - Multi-line code/scripts: `sandbox_write_file` the script, then `sandbox_exec` to run it (e.g. `python3 script.py`). NEVER embed multi-line code in `python3 -c` / `node -e`: the JSON→shell→code escaping breaks.
            - Run independent calls in parallel; chain dependent shell steps with `&&`.
            """
    }

    /// Combined-mode (`.sandbox(hostRead:)`) variant: the host `file_*`
    /// tools are the single, path-routed read family, so reads/lists/searches
    /// are NOT done with `sandbox_read_file` / `sandbox_search_files` (hidden
    /// in this mode). The `## Files` block spells out the path routing.
    private static func sandboxToolGuideCombined(backgroundEnabled: Bool) -> String {
        let shellBullet = sandboxShellBullet(backgroundEnabled: backgroundEnabled)
        return """
            Tool dispatch:
            - Read files / list dirs / search: `file_read` (reads a file or lists a directory — the path decides), `file_search` (they reach both your workspace and `/workspace/...` sandbox paths — see `## Files`).
            - Sandbox writes: `sandbox_write_file` (pass `content` to write the whole file, or `old_string`+`new_string` to edit one match — your workspace is read-only).
            \(shellBullet)
            - Multi-line code/scripts: `sandbox_write_file` the script, then `sandbox_exec` to run it (e.g. `python3 script.py`). NEVER embed multi-line code in `python3 -c` / `node -e`: the JSON→shell→code escaping breaks.
            - Run independent calls in parallel; chain dependent shell steps with `&&`.
            """
    }

    /// Compact environment framing (`prefersCompactPrompt`). Folds the
    /// home-path, internet, and installed-tools lines into one paragraph.
    /// The absolute home line is preserved verbatim in intent — dropping it
    /// makes models guess `/root` for `cwd` and eat a rejection.
    private static func sandboxEnvironmentBlockCompact(home: String, hostReadCombined: Bool) -> String {
        let homeLine =
            home.isEmpty
            ? "Your home (`~`) is your sandbox home"
            : "Home: `\(home)` (`~` / `$HOME`); commands run there by default — no `cwd` needed"
        return """
            Isolated Alpine Linux ARM64 sandbox. \(homeLine). Files persist across messages. Internet works — fetch live data (weather, web pages, APIs) directly with `curl`, `wget`, Python `requests`, or Node `fetch`. Installed: bash, python3, node, git, curl, wget, jq, rg, sqlite3, build-base, cmake, vim, tree.
            """
    }

    /// Compact non-combined dispatch + absorbed runtime hints.
    private static func sandboxToolGuideCompact(backgroundEnabled: Bool) -> String {
        let shell =
            backgroundEnabled
            ? "`sandbox_exec` (single-line; `background:true` + `sandbox_process` for servers)"
            : "`sandbox_exec` (single-line)"
        return """
            Tool dispatch:
            - Files: `sandbox_read_file` (read/list); `sandbox_write_file` (`content` whole-file, or `old_string`+`new_string` to edit). Search: `sandbox_search_files` (`target="content"|"files"`).
            - Shell: \(shell). Multi-line code: `sandbox_write_file` a script then `sandbox_exec` it (e.g. `python3 script.py`) — never `python3 -c` / `node -e`.
            - Install deps with `sandbox_install` (`pip`/`npm`/`apk`); inspect large logs with \(sandboxReadFileHint). Run independent calls in parallel; chain dependent steps with `&&`. Sandbox is disposable.
            """
    }

    /// Compact combined-mode dispatch + absorbed runtime hints. Mirrors
    /// `sandboxToolGuideCombined` (host `file_*` read family, sandbox writes).
    private static func sandboxToolGuideCombinedCompact(backgroundEnabled: Bool) -> String {
        let shell =
            backgroundEnabled
            ? "`sandbox_exec` (single-line; `background:true` + `sandbox_process` for servers)"
            : "`sandbox_exec` (single-line)"
        return """
            Tool dispatch:
            - Read/list/search: `file_read`, `file_search` (reach your workspace and `/workspace/...` sandbox paths — see `## Files`). Sandbox writes: `sandbox_write_file` (`content` whole-file or `old_string`+`new_string` edit; workspace is read-only).
            - Shell: \(shell). Multi-line code: `sandbox_write_file` a script then `sandbox_exec` it (e.g. `python3 script.py`) — never `python3 -c` / `node -e`.
            - Install deps with `sandbox_install` (`pip`/`npm`/`apk`); inspect large logs with \(sandboxReadFileHintCombined). Run independent calls in parallel; chain dependent steps with `&&`. Sandbox is disposable.
            """
    }

    /// Runtime hints block. In combined mode the log-read hint points at
    /// `file_read` (the unified read tool) rather than the hidden
    /// `sandbox_read_file`, so the model is never steered toward a tool
    /// it can't see in this mode.
    private static func sandboxRuntimeHints(hostReadCombined: Bool) -> String {
        let logReadHint = hostReadCombined ? sandboxReadFileHintCombined : sandboxReadFileHint
        return """
            Runtime hints:
            - Install Python, Node, or system deps with `sandbox_install` (`manager`: `pip` / `npm` / `apk`).
            - Use \(logReadHint) to inspect large logs.
            - The sandbox is disposable; experiment freely.
            """
    }

    /// Per-manager cap on how many package names are listed before
    /// collapsing into a `+N more` tail. Keeps the always-on prefix bounded
    /// even for an agent that has installed dozens of packages.
    static let installedPackagesPromptCap = 12

    /// Compact, capped summary of what's already installed in the sandbox,
    /// grouped by manager. Rendered into the DYNAMIC `sandboxState` section
    /// (via `sandboxState(...)`) so it reflects live manifest state without
    /// busting the cached prefix. Returns `""` when nothing is recorded so
    /// the composer can append unconditionally.
    static func installedPackagesPromptBlock(_ installed: SandboxPackageManifest.Installed) -> String {
        guard !installed.isEmpty else { return "" }

        func line(_ label: String, _ names: [String]) -> String? {
            guard !names.isEmpty else { return nil }
            let shown = names.prefix(installedPackagesPromptCap)
            var joined = shown.joined(separator: ", ")
            let overflow = names.count - shown.count
            if overflow > 0 { joined += ", +\(overflow) more" }
            return "- \(label): \(joined)"
        }

        let lines = [
            line("System (apk)", installed.apk),
            line("Python (pip)", installed.pip),
            line("Node (npm)", installed.npm),
        ].compactMap { $0 }

        return """
            Already installed (don't reinstall — call directly):
            \(lines.joined(separator: "\n"))

            """
    }

    private static func secretsPromptBlock(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let list = names.sorted().map { "- `\($0)`" }.joined(separator: "\n")
        return """
            Configured secrets (available as environment variables):
            \(list)
            Access via `$NAME` in shell, `os.environ["NAME"]` in Python, or `process.env.NAME` in Node.

            """
    }

    // MARK: - Folder Context

    /// Working-directory framing appended to the system prompt when chat
    /// is mounted on a host folder (`ExecutionMode.hostFolder`). Mirrors
    /// the sandbox section's structure: heading + environment metadata +
    /// path rule + tool dispatch + mode-specific framing + optional
    /// project context. Returns `""` when no folder is mounted so the
    /// composer can append unconditionally.
    public static func folderContext(from folderContext: FolderContext?) -> String {
        guard let folder = folderContext else { return "" }

        var lines: [String] = ["## Working directory"]
        lines.append("**Path:** \(folder.rootPath.path)")
        if folder.projectType != .unknown {
            lines.append("**Project Type:** \(folder.projectType.displayName)")
        }
        let topLevel = buildTopLevelSummary(from: folder.tree)
        if !topLevel.isEmpty {
            lines.append("**Root contents:** \(topLevel)")
        }
        var section = "\n" + lines.joined(separator: "\n") + "\n"

        if let status = folder.gitStatus {
            let trimmed = String(status.prefix(300))
            if !trimmed.isEmpty {
                section += "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            }
        }

        section += """

            \(folderPathRule)

            \(folderToolGuide)

            \(folderArtifactReminder)

            """

        // Project-level guidance file (first-found-wins across AGENTS.md,
        // CLAUDE.md, .hermes.md, .cursorrules). Loaded once at folder-mount
        // time and stamped onto the FolderContext so it lives in the static
        // prefix and doesn't break KV-cache reuse across turns. Capped at
        // 20K chars with head+tail truncation by FolderContextService.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    // MARK: - Folder Building Blocks

    /// One-line restatement of the path-arg rule. Each `file_*` tool's
    /// description carries the per-arg detail; this lives in the prompt
    /// so the rule is anchored once at the top of the section instead of
    /// repeated in every dispatch bullet.
    static let folderPathRule =
        "Use paths relative to the working directory; an absolute path is accepted only if it is inside the working directory (paths outside it are rejected)."

    /// Positive dispatch table for the folder-mode tools. Mirror of
    /// `sandboxToolGuide` — the shell-replacement discipline lives HERE
    /// (one table, one place) instead of being repeated in every tool's
    /// description.
    static let folderToolGuide = """
        Tool dispatch (always prefer these over their shell equivalents — \
        `cat`/`ls`/`grep`/`find`/`sed`/`awk`/`echo` in `shell_run`):
        - Read / list: `file_read` to read a file or list a directory — the path decides (optional line range, or `max_depth` for a directory).
        - Search: `file_search` for content (case-insensitive substring), or `target:"files"` to find files by name (case-insensitive substring, e.g. `q4`).
        - Find a file by name: use `file_search` with `target:"files"` and a short distinctive token from the name (not the whole phrase).
        - Edit: `file_edit` for targeted in-place edits, `file_write` for new files or full rewrites.
        - Shell: `shell_run` for builds, tests, git, processes, and `mv` / `cp` / `rm` / `mkdir` (simple forms join the undo log; complex commands warn that they don't).
        - Undo: `file_undo` reverts logged operations; `file_operation_history` shows what is revertible.
        """

    /// Folder-mode-specific reminder: filesystem changes ARE visible to
    /// the user (unlike sandbox), but only `share_artifact` surfaces an
    /// artifact card in the chat thread.
    static let folderArtifactReminder = """
        **Files land in the working folder, not in chat.** When you create or edit a file with `file_write` / `file_edit`, the user can see it on disk and in the operations log. If the user needs the deliverable to appear in the chat thread (an image, chart, generated text, report, code blob), additionally call `share_artifact` — it's the only thing that surfaces an artifact card.
        """

    // MARK: - Combined Sandbox + Host-Read

    /// Read-only host-workspace framing for combined mode
    /// (`ExecutionMode.sandbox(hostRead: ctx)`). Rendered AFTER the
    /// sandbox section so the agent reads the sandbox framing first,
    /// then learns the host workspace is a separate, read-only
    /// filesystem. Unlike `folderContext` this marks the workspace
    /// read-only, lists only the read tools, and appends the
    /// two-filesystem block. Returns "" when no host-read folder is
    /// attached so the composer can append unconditionally.
    public static func combinedHostRead(
        from folderContext: FolderContext?,
        allowSecretReads: Bool = false
    ) -> String {
        guard let folder = folderContext else { return "" }

        var lines: [String] = ["## Host workspace (read-only)"]
        lines.append("**Path:** \(folder.rootPath.path)")
        if folder.projectType != .unknown {
            lines.append("**Project Type:** \(folder.projectType.displayName)")
        }
        let topLevel = buildTopLevelSummary(from: folder.tree)
        if !topLevel.isEmpty {
            lines.append("**Root contents:** \(topLevel)")
        }
        var section = "\n" + lines.joined(separator: "\n") + "\n"

        if let status = folder.gitStatus {
            let trimmed = String(status.prefix(300))
            if !trimmed.isEmpty {
                section += "\n**Git status (uncommitted changes):**\n```\n\(trimmed)\n```\n"
            }
        }

        section += """

            \(unifiedFilesBlock(allowSecretReads: allowSecretReads))

            """

        // Same project-context file the folder section surfaces, loaded
        // once at folder-mount time so it lives in the static prefix.
        if let contextFiles = folder.contextFiles, !contextFiles.isEmpty {
            section += """

                ## Project context

                The following project context file has been loaded and should be followed:

                \(contextFiles)

                """
        }

        return section
    }

    /// The load-bearing mental model for combined mode under the unified,
    /// path-routed file tools: ONE reader (`file_read`, which also lists
    /// directories) and ONE search tool (`file_search`) reach two storage
    /// areas by path — the read-only workspace (default) and the
    /// `/workspace/...` sandbox scratch area; one writer
    /// (`sandbox_write_file`, which also edits) targets the sandbox. This
    /// replaces the older `## Two filesystems` framing that asked the model
    /// to pick between `file_*` and `sandbox_*` read families (the
    /// disambiguation weak models kept getting wrong). The final sentence
    /// reflects the per-agent secret-read setting.
    static func unifiedFilesBlock(allowSecretReads: Bool) -> String {
        let secretLine =
            allowSecretReads
            ? "Workspace secret files (`.env`, keys, credentials) are readable because you enabled secret reads — handle them carefully and never copy them into the sandbox or off-host."
            : "Workspace secret files (`.env`, keys, credentials) are refused."
        return """
            ## Files

            One reader and one search tool reach two storage areas by path:
            - **Workspace** (your read-only host folder) — the default. For "what's in my workspace / on my Desktop", use `file_read` (it reads a file or lists a directory) and `file_search`. Relative paths and `/Users/...` paths are the workspace.
            - **Sandbox** scratch area — pass a `/workspace/...` path to the SAME `file_read` / `file_search`.

            The workspace is read-only: create or change files with `sandbox_write_file` (pass `content` to write the whole file, or `old_string`+`new_string` to edit one match — it writes the sandbox), and run commands with `sandbox_exec` (it runs in the sandbox, which has no copy of the workspace — `file_read` a workspace file and pass its content in if a command needs it). Surface results with `share_artifact`. \(secretLine)
            """
    }

    private static func buildTopLevelSummary(from tree: String) -> String {
        let lines = tree.components(separatedBy: .newlines)
        let topLevel = lines.compactMap { line -> String? in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            let treeChars = CharacterSet(charactersIn: "│├└─ \u{00A0}")
            let indentPrefix = line.prefix(while: { char in
                char.unicodeScalars.allSatisfy { treeChars.contains($0) }
            })
            guard indentPrefix.count <= 4 else { return nil }
            return stripped.trimmingCharacters(in: treeChars)
        }
        .filter { !$0.isEmpty }

        if topLevel.count <= 8 {
            return topLevel.joined(separator: ", ")
        }
        let shown = topLevel.prefix(6)
        return shown.joined(separator: ", ") + ", and \(topLevel.count - 6) other items"
    }

}
