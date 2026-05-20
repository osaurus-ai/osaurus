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
