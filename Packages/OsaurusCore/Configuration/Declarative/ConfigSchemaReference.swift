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
        - Entities (agents, mcp_servers, providers, schedules, watchers) match
          existing ones by `name` (case-insensitive): unmatched entries are
          created, matched ones are patched.
        - `models` and `plugins` are plain desired-state lists of ids.
        - apply with `prune: true` additionally DELETES entries not listed in
          the sections the document declares. Never prunes undeclared sections.
        - Secrets NEVER appear in the document. Write-only `*_ref` keys
          (api_key_ref, token_ref, secret_env_refs, bot_token_ref,
          app_token_ref) accept `env:VAR_NAME` or `keychain:SERVICE/ACCOUNT`;
          the credential is read from there during apply and stored in the
          Keychain, and refs are never exported. Without a ref, creating a
          cloud provider opens the native credential sheet during apply, and
          keyed MCP/search providers are registered for the user to finish
          auth in Settings.
        """

    static let footer = """
        Not configurable here (Settings UI only, by design): server runtime
        (port, network exposure, generation defaults, caches, concurrency,
        memory safety, model exposure), chat behavior (core model, context
        length, titles), app shell (login item, dock icon), themes/appearance/
        font size, toast notifications, voice/dictation/TTS, computer-use
        autonomy policy, sandbox resources, the privacy filter, image/video
        generation model selection, tool auto-approval grants, telemetry/crash
        toggles, identity/pairing keys, storage encryption, custom channel
        connections/per-room routes, WhatsApp/iMessage pairing, hotkeys,
        endpoint changes on existing providers (create-only), skills, custom
        search definitions. Per-agent capability toggles (including
        computer_use_enabled and browser_use_enabled) stay under
        `agents[].capabilities`.
        """
}
