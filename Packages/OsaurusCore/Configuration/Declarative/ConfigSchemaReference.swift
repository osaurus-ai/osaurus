//
//  ConfigSchemaReference.swift
//  osaurus
//
//  The model-facing YAML reference returned by
//  `osaurus_config({action: "schema"})`. The YAML body is GENERATED from
//  `ConfigManifest` — the single source of truth for the schema — so the
//  reference can never drift from the enforced validation. Only the
//  semantics preamble and the "not configurable here" footer are prose.
//

import Foundation

enum ConfigSchemaReference {

    static var text: String {
        text(sections: nil)
    }

    /// Reference limited to `sections` (all sections when nil). Small-window
    /// models ask for one section at a time; the full multi-section blob
    /// costs them most of their budget and they re-request it in a loop.
    static func text(sections: Set<ConfigSectionID>?) -> String {
        preamble + "\n\n" + ConfigManifest.renderedSchemaSections(only: sections) + "\n\n" + footer
    }

    private static let preamble = """
        Osaurus declarative configuration (YAML), schema version \(ConfigManifest.version).

        Semantics
        - Merge-by-default: a key ABSENT from the document is left unchanged.
        - Explicit `null` clears an optional override back to its default.
        - Entities (agents, harness_runtimes, mcp_servers, providers,
          automations) match existing ones by `name` (case-insensitive):
          unmatched entries are created, matched ones are patched.
        - `models` and `plugins` are plain desired-state lists of ids.
        - apply with `prune: true` additionally DELETES entries not listed in
          the sections the document declares. Never prunes undeclared sections.
        - Secrets NEVER appear in the document. Write-only `*_ref` keys
          (api_key_ref, token_ref, secret_env_refs, secret_header_refs,
          bot_token_ref, app_token_ref) accept `env:VAR_NAME` or `keychain:SERVICE/ACCOUNT`;
          the credential is read from there during apply and stored in the
          Keychain, and refs are never exported. Without a ref, creating a
          cloud provider opens the native credential sheet during apply, and
          keyed MCP/search providers are registered for the user to finish
          auth in Settings.
        - Two surfaces, matching the app:
          * `channels` = messages people send to agents. Per platform:
            receiving (`read_allowlist`, `sender_allowlist`), routing
            (`routing`: one rule per agent or workflow that answers, scoped
            to `rooms` or any room; `replies: automatic` is HIGH RISK) and
            sending (`write_enabled`, `write_allowlist`, `posting`: agents
            that post on their own, `without_asking` is HIGH RISK). n8n and
            custom HTTP connections take `routing` under `channels.connections`.
            `channels.<platform>` edits the platform's first account; every
            other bot, Slack workspace or email account is an entry in
            `channels.<platform>.accounts` with its connection `id` and the
            same keys. Bots and workspaces are added in Settings (no token
            refs in `accounts`); an Email entry `email-<mail account id>`
            adds an account for a mail account no other entry watches.
            `channels.email` reads mail accounts added in Settings: rooms are
            `<mail account id>/<mailbox>`, senders are addresses or
            `@domain`, and with `write_enabled` agents reply in the thread
            of mail they received (no `write_allowlist`, no `posting`).
          * `automations` = triggers that run a CUSTOM agent or an installed
            workflow: `source` (schedule | folder | webhook) + optional
            `filter` + `agent` OR `workflow` (+ `input`) + `delivery`.
            Every `required` workflow input must be bound in `input` to a
            trigger value (`{{schedule.scheduled_for}}`, `{{folder.changed_paths}}`,
            `{{webhook.body.<field>}}`, `{{text}}`) or fixed text.
            A webhook's `sample_body` lists the fields its sender posts.
            Webhook URL tokens and secrets are created by Osaurus and never
            appear here.
        - Routing rules and automations share one name space (names are
          unique across both). With `prune: true`, a declared
          `channels.<platform>.routing` / `posting` list only prunes that
          platform; `automations` never prunes channel rules.
        - Legacy input, accepted and translated (never exported): top-level
          `events:`, `schedules:` and `watchers:` lists become `automations`;
          `automations` entries with `source.kind: channel_message` and
          `channels.<platform>` keys `inbound_enabled:`, `inbound_agent:`,
          `auto_reply_enabled:` become `channels.<platform>.routing` rules.
          `automations` entries with `source.kind: email` are retired: they
          are ignored with a note (write `channels.email` instead).
        - harness_runtimes apply before agents, so `runtime:` may name a
          runtime the same document adds. An unknown runtime name is an error,
          never a fallback to `builtin`.
        """

    static let footer = """
        Not configurable here (Settings UI only, by design): server runtime
        (port, network exposure, generation defaults, caches, concurrency,
        memory safety, model exposure), Chat page sampling (Top P, Max Tool
        Attempts) and Context Window Cap, the dock icon, beta updates, factory
        reset, themes/appearance/font size, voice/dictation/TTS, computer-use
        autonomy policy, sandbox resources, the privacy filter, image/video
        generation model selection, tool auto-approval grants, telemetry/crash
        toggles, identity/pairing keys, storage encryption, creating n8n /
        custom HTTP channel connections, WhatsApp/iMessage pairing, mail
        accounts and their passwords (Settings → Channels → Email),
        endpoint changes on existing providers (create-only), skill content
        (installing skills; an agent's allow-list is `agents[].skills`),
        custom search definitions. Per-agent capability toggles (including
        computer_use_enabled, browser_use_enabled and the built-in Apple app
        tools under `apple_apps`) stay under `agents[].capabilities`. Apple
        app access (Calendar, Reminders, Contacts, Notes, Mail, Messages,
        Maps, Music, Shortcuts) is a custom-agent capability: the
        Orchestrator never calls those tools itself — it enables them on an
        agent (or creates one with them) and dispatches that work there.
        `agents[].workflows` lists installed workflow names the agent may
        call as tools; installing and setting up workflows is Settings UI only.
        """
}
