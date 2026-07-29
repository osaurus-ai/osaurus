# JSON determinism contract

This document describes the byte-level determinism contract Osaurus
honours for any JSON payload that crosses a wire boundary, ends up
embedded in a prompt prefix, or gets hashed for cache lookup. It is the
companion to `Packages/OsaurusCore/Models/API/JSONDeterminism.swift`.

## Why we need this

Modern inference servers compare incoming prompts byte-for-byte against
a cached prefix to decide whether they can reuse the previous KV state.
The cache check is a cheap memcmp, not a structural diff: any byte
shift (whitespace, key order, number formatting) breaks the prefix and
forces a full re-prefill of the conversation.

The user-visible failure mode that motivated this work was reported
against [ds4](https://github.com/antirez/ds4): every tool-using turn
through Osaurus missed ds4's KV cache. The `--trace` output pinpointed
the divergence to the `### Available Tool Schemas` block of the
rendered prompt — keys like `name`, `description`, and `parameters` had
re-shuffled between the first and second turn, so the prompt's hashed
prefix mismatched at token 269.

The same failure mode applies to every prompt-prefix cache the
ecosystem ships:

- vLLM's automatic prefix cache,
- sglang's RadixAttention,
- llama.cpp / llama-server with `--prompt-cache`,
- Anthropic's prompt cache (`cache_control` blocks),
- OpenAI's automatic prompt cache,
- ds4's byte-prefix KV cache,
- Apple MLX's paged KV cache used by `vmlx-swift` locally.

It also applies to anything that hashes JSON for cache keys, manifest
digests, or sync-conflict detection.

## The contract

> Every JSON payload Osaurus emits whose bytes are externally visible
> MUST be encoded with sorted keys and a fixed numeric/whitespace
> format.

In practice that means:

- Use `JSONEncoder.osaurusCanonical(prettyPrinted:)` instead of
  `JSONEncoder()` whenever the bytes are sent over the wire, returned
  to a client, fed back into a prompt, written to a tool result string,
  or hashed for a cache key.
- Use `JSONSerialization.data(withJSONObject: …, options: .osaurusCanonical)`
  whenever you build a payload from a Swift `[String: Any]` that
  crosses one of those same boundaries.
- Treat `JSONValue.object([String: JSONValue])` as a non-deterministic
  container: the determinism guarantee comes from the encoder
  (`.sortedKeys`), not from the type. Code that produces `JSONValue`
  is therefore safe as long as every encoder downstream of it is the
  canonical one.

The single source of truth for the helpers is
`Packages/OsaurusCore/Models/API/JSONDeterminism.swift`. Grep for
`osaurusCanonical` to find every call site.

## Tool-schema stability contract

Canonical encoding only guarantees stable bytes for stable content. Tool
schemas are the other half of the contract: they render into the static
`<tools>` prefix of every composed prompt, ahead of all chat history, so
a schema whose *content* changes between two composes invalidates the
KV-cache prefix for the entire conversation even when every byte is
canonically encoded.

> A baseline (always-loaded) tool's schema MUST NOT depend on mutable or
> background-resolved state — provider configuration, Keychain probes,
> model discovery, locale, or anything else that can differ between two
> composes of the same session.

The canonical example of the failure: `web_search` used to derive its
`category` enum from the user's configured search providers, which
resolve on a background Keychain probe seconds after launch. The first
compose after every app start advertised a different schema than the
next one, forcing a full re-prefill of the tool block and all history
behind it. The schema is now immutable (`category` is an open string;
execution validates against the live provider set and falls back to
`web` with a warning). If a tool needs to react to configuration, do it
at execute time, never in `parameters` / `description`.

Enforcement and backstops:

- `SessionToolStateStore` freezes the first-compose tool payloads
  (`initialToolSpecs`) per session; `SystemPromptComposer.resolveTools`
  restores them for baseline tools on later turns. This is the backstop
  for *dynamically registered* tools (MCP re-registration on reconnect,
  plugin reloads, sandbox tools) — not a license for built-ins to carry
  mutable schemas.
- `canonicalToolOrder` fixes the tool ordering; registry listings are
  name-sorted.
- Regression tests:
  `ToolSerializationStabilityTests.alwaysLoadedTokenizerToolPayload_isByteStableAcrossInvocations`
  (whole ordered baseline payload),
  `SystemPromptComposerToolResolutionTests.baselineToolPayloads_areStableAcrossRepeatedResolves`
  (repeated resolves with and without frozen session state),
  `WebSearchToolTests` immutable-schema contract tests.

### Intentional schema transitions (audited)

These transitions change the rendered tool block on purpose. They are
attributable, bounded events — not drift — and must not be "fixed" by
suppressing the change or weakening live authorization constraints to
preserve cache reuse:

- **Delegation constraints** (`spawn_agent` / `spawn_model` /
  `spawn_batch` target enums and `maxItems`) are request-local
  authorization guidance, reapplied *after* the frozen-spec restore.
  Unchanged settings reproduce identical bytes (see
  `frozenDelegationSchemaIsStableForUnchangedSettings`); an actual
  settings/provider/model-pool edit legitimately changes the prefix.
- **Sandbox provisioning**: sandbox tools enter the tool set when the
  container comes online mid-session (the late-registration carve-out
  in `resolveTools`). One prefix change per provisioning event.
- **`capabilities_load`**: never rewrites the frozen prefix mid-run
  (loaded schemas ride in the tool-result suffix); the loaded tool
  folds into `<tools>` on the *next* user turn, growing the prefix
  predictably. Explicit loads may also upgrade a compact bootstrap
  schema to the full contract.
- **MCP / plugin re-registration** affects tools not pinned by the
  session freeze (newly loaded rows); session-frozen payloads keep the
  first-compose bytes until the session invalidates.
- **Stateless HTTP surfaces** (`/agents/{id}/run` without a
  `session_id`, bare `/chat/completions`) have no cross-request
  schema-freeze guarantee: each request composes fresh, so callers who
  want prefix reuse must pass a `session_id`.
- **Engine reload** (idle unload, app relaunch, model switch) resets
  per-engine cache counters and re-prefills by definition. Diagnostics
  should attribute this to engine lifecycle, not schema divergence.

## Where the contract is enforced

Outbound (Osaurus is the client of an external model provider):

- `RemoteProviderService.buildURLRequest` — encoder for every chat /
  responses / messages request body.
- `OpenResponsesRequest.toCodexOAuthPayloadData` — Codex OAuth
  passthrough body.
- `RemoteProviderService.geminiArgsJSON` — Gemini `functionCall.args`
  serialised back into `tool_calls[].function.arguments`.
- Anthropic-input parse path (`tool_use.input` → assistant
  `tool_calls[].function.arguments`).
- `RemoteToolDetection.extractToolCall(fromJSON:)` — args extracted
  from streamed JSON tool-call envelopes.

Inbound / server (Osaurus is the model provider):

- `GET /mcp/tools`, `POST /mcp/call`, including the `AnyCodable` array
  / dict re-serialisation inside `/mcp/call`.
- `POST /v1/messages` (Anthropic non-stream) `tool_use.input`
  serialisation.
- Ollama NDJSON helpers (`ollamaGenerateJSON`, `ollamaGenerateErrorJSON`,
  and the live `OllamaGenerateNDJSONResponseWriter` / chat NDJSON
  writer).
- `/v1/audio/transcriptions` verbose-JSON dict response.
- Diagnostics / batch / model-residency dict responses.

Local pipeline (Osaurus's own runtime):

- `GenerationEventMapper.serializeArguments` — assistant turn replay
  for the on-device prompt.
- `Tool.canonicalize` and `Tool.canonicalHashPayload` — schema
  canonicalisation handed to the local chat template.
- `DBSchemaTool` — the schema string the model sees as a tool result.

Plugin host:

- `PluginHostAPI.jsonString` and the streaming chunk emitter both use
  the canonical writing options so plugin-side prompt prefixes stay
  byte-stable.

External wire / persistence:

- `RelayTunnelManager` (relay WebSocket frames + sendJSON).
- `MCPOAuthRegistration` (DCR request body).
- `OpenRouterOAuthService` (token exchange body).
- `PluginDatabase` (param JSON for diff/sync stability).
- `ShareArtifactTool`, `MCPProviderTool`, `BuiltinSandboxTools`,
  `SandboxSecretTools`, `SandboxPluginTool` (tool-result and
  configuration JSON).

## Fallback path

`Tool.canonicalize` first round-trips through
`JSONSerialization.data(…, options: .osaurusCanonical)`. If
`isValidJSONObject` rejects the input or serialisation throws (very
rare — typically a non-JSON leaf like a `Date` or a non-finite
`Double`), it falls back to `JSONCanonicalization.normalizeObject`.
The walker recursively validates every leaf without depending on
`JSONSerialization`, so even the fallback path produces a dict whose
canonical bytes are stable. There is no surface that can return an
unsorted dict to downstream encoders.

## Adding new wire / server / tool code

1. Use `JSONEncoder.osaurusCanonical()` (or
   `…(prettyPrinted: true)` if the consumer expects pretty bytes).
2. Use `JSONSerialization.data(withJSONObject: …, options: .osaurusCanonical)`
   for `Any`-shaped dicts.
3. If the new code produces a `JSONValue`, document at the call site
   which downstream encoder will serialise it and confirm that encoder
   is canonical.
4. Add a regression test under `Tests/Networking/JSONDeterminismTests`
   that constructs two semantically-identical inputs with permuted key
   orders and asserts the canonical bytes are equal.

## Pre-existing exemptions

- `IkigaJSONEncoder` is used for streaming SSE writers. SSE event
  payloads are fixed-shape Codable structs (no `[String: Any]` or
  `JSONValue`), and `tool_calls[].function.arguments` deltas flow
  through the wire as opaque pre-serialised strings, so the streaming
  path inherits determinism from the upstream serialisers. The
  encoder is created per-write for thread safety; if Ikiga ever gains
  a sortedKeys option, mirror the canonical contract here.
- Test-only fixtures (`Tests/**/*.swift`) and persistence helpers that
  predate this contract may still call bare `JSONEncoder()` /
  `JSONSerialization.data(withJSONObject:)`. Migrating them is
  encouraged but optional.
- Some UI views format JSON with `[.prettyPrinted, .sortedKeys]`
  inline. They satisfy the contract; consider migrating to
  `JSONEncoder.osaurusCanonical(prettyPrinted: true)` when next
  touched.
