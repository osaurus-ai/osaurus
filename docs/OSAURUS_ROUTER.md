# Osaurus Router

Osaurus Router is the hosted inference path used by Osaurus accounts. It is
implemented as an OpenAI-compatible remote provider with a few Router-only
contracts for billing, request deduplication, and upstream compatibility.

This document captures the invariants that keep Router behavior reliable in the
chat UI and agent loop.

## Data Handling

The Router proxies request and response content to the upstream provider that
serves the selected model; it does not persist prompt, response, tool-argument,
or tool-result content on Osaurus servers. Only billing metadata — model,
provider slug, token counts, cost, status, and timestamps — is retained, which
is what the credits system needs (see [Billing Reliability](#billing-reliability)
and [On-Device Billing Ledger](#on-device-billing-ledger)). Chat history stays on
the user's Mac.

Upstream providers receive request content in order to generate a response and
process it under their own privacy policies; the Router neither overrides nor
extends those policies. The in-app and marketing copy must match this posture —
"Osaurus Cloud doesn't store the content of your prompts or responses, only the
usage metadata needed to bill credits" — with upstream providers disclaimed
rather than guaranteed.

## Connection Lifecycle

Router availability depends on the local Osaurus identity. When identity is
available, the Router provider is injected into the remote provider list and is
eligible for the same model picker and chat paths as other remote providers.

Startup and recovery should stay automatic:

- App launch connects auto-connect providers, including Router.
- Identity changes trigger Router reinjection/reconnect instead of waiting for a
  manual Dashboard refresh.
- App activation retries discovery so a wake, sign-in, or delayed network state
  can recover without user action.
- Connect-phase transient failures can retry, but authentication, bad-request,
  and provider contract errors should surface as terminal errors.

## Outbound Request Contract

Router requests use the OpenAI Chat Completions shape, then apply Router-only
normalization in `RemoteProviderService.buildChatRequest`.

Router-specific fields and transforms:

- `idempotency_key` is sent only to Router. Other OpenAI-compatible providers do
  not receive it because some reject unknown fields.
- `clamp_to_balance` is explicitly set to `false` for Router.
- User multimodal content parts are preserved.
- Assistant history is normalized to string `content` because several upstreams
  reject assistant content arrays or omitted assistant content on tool-call
  turns.
- A trailing plain assistant prefill is dropped for Router. Tool-call assistant
  turns are preserved because the following tool result must stay grounded in
  the prior `tool_calls`.
- If chat leaves `max_tokens` implicit, Router receives the chat engine default
  instead of relying on an upstream default. This prevents upstream 1024-token
  caps from turning long agent tasks into billed empty or truncated responses.

The request path should not add prompt coercion, fake model-family behavior, or
provider-specific output filters. If an upstream model has an incompatible
contract, fix the request shape or surface the provider error.

## Streaming Parser

Router streaming goes through the shared OpenAI-compatible parser in
`OpenAICompatibleStreamParser.swift`. Provider-specific behavior stays outside
that parser; the shared layer owns framing, event decoding, and tool-call
accumulation.

Shared parser responsibilities:

- Tokenize SSE bytes on CR, LF, and CRLF only.
- Preserve JSON string content that contains other Unicode newline separators.
- Join compliant multi-line `data:` fields per the SSE spec.
- Optionally recover Router-compatible raw JSON bodies and proxy-split JSON
  payloads when policy allows it.
- Accumulate streaming tool calls by index, including continuation chunks that
  omit an index.
- Validate final tool-call arguments as JSON and classify truncated arguments as
  stream errors.

Router enables the compatibility policy for raw JSON fallback and split-data
repair. Other OpenAI-compatible providers should stay on the strict path unless
they prove they need the same tolerance.

If a stream ends with `finish_reason=length` and no visible text, reasoning, or
tool call was emitted, the parser treats it as an error. That state usually
means the provider spent output tokens without producing usable assistant
content, so it must not silently look like a successful empty answer.

## Billing Reliability

Router billing metadata is carried through the stream separately from visible
assistant text.

- Router summary frames become `RouterBillingSummary`.
- The stream yields a `StreamingBillingHint` sentinel prefixed with `U+FFFE`.
  The UI filters this sentinel out of visible output and token counting.
- The active assistant `ChatTurn` stores `routerBilling` so a billed turn
  survives chat reloads.
- If a billed turn finishes with no visible text, the chat renders an explicit
  empty-response notice instead of deleting the assistant bubble.
- Retry keys use a stable logical step key such as `<runId>:<attempt>`, so
  connect-phase retries can be deduped server-side. A user-initiated Retry starts
  a new logical run and can bill normally.

The billing path is metadata-only. Prompt text, response text, tool arguments,
and tool results must not be written to Router billing records.

## On-Device Billing Ledger

Router charges are also persisted to a local ledger so support can
debug "I was charged but saw nothing" reports without storing transcripts on
Osaurus servers.

Ledger properties:

- File: `~/.osaurus/billing/ledger.sqlite`
- Encryption: follows the app-wide storage posture — plaintext SQLite by default
  (protected by FileVault), or SQLCipher under the shared storage key when
  [encryption is opted in](STORAGE.md#why-encryption-is-opt-in). The ledger is
  metadata-only either way (no prompt/response/tool text).
- Retention: newest 10,000 rows and at most 365 days
- Export: metadata-only diagnostics from the Dashboard
- Correlation: request id, session id, assistant turn id, model, token counts,
  cost, status, app version, and rendered outcome

Outcomes are classified as `rendered`, `toolOnly`, `reasoningOnly`, `empty`,
`error`, or `cancelled`. This mirrors what the user saw in chat and lets support
distinguish a truly empty billed response from a tool-only or reasoning-only
turn.

## Account Usage Center

The Router account usage center composes the hosted account endpoints with the
local billing ledger:

- Account status comes from the Router master switch, local identity presence,
  `/credits/balance`, and the account hold flag.
- Credits activity is based on `/credits/usage`, with local ledger rows matched
  by Router request id when available.
- Transaction summaries come from `/credits/transactions` and separate credits,
  debits, and net movement in micro-USD.
- Ledger summaries are local-only aggregates over recent encrypted
  `RouterBillingEntry` rows, including outcome counts and model totals.
- Signed request diagnostics are generated locally by signing representative
  Router requests without sending them. The UI shows method, path, body hash,
  signed header names, timestamp, public wallet address, and a signature
  fingerprint.

Support export is metadata-only. It may include public wallet address,
redacted signed-request diagnostics, usage rows, transaction rows, and local
ledger metadata. Export never reads the Master Key or triggers biometric
authentication just to derive the wallet address; it uses an existing
non-prompting source such as signed-request diagnostics when available. When no
such source exists, `walletAddressStatus` records that the address was
unavailable without prompting. It must not include prompts, assistant replies,
tool arguments, tool results, private keys, bearer tokens, cookies, or raw
wallet signatures. Wallet signatures are replaced with `<redacted>` and only a
SHA-256 fingerprint of the signature is retained for local/server correlation.

## Empty Stream Diagnostics

Router has a low-volume diagnostic path for terminal streams that produce no
visible text, reasoning, or tool calls. These logs are intentionally sanitized
and do not include request bodies or generated text.

The log prefix is:

```text
[Osaurus][Router][EmptyStream]
```

Useful fields include:

- `kind`: terminal classification such as `raw-empty`, `summary-only`,
  `usage-only`, `unrecognized-events`, or `empty-after-events`
- `finish_reason`: provider finish reason, including `length`
- `inputTokens` / `outputTokens`: usage reported by the provider
- `visibleDeltas`, `reasoningDeltas`, `toolHints`, `billingHints`: what the UI
  actually received
- `idempotency_suffix`: last characters of the idempotency key for local
  correlation without printing the full key
- `routerTransforms`: whether Router-specific outbound transforms were applied

When investigating a billed empty response, pair the `EmptyStream` log with the
local billing diagnostics export. The log explains what the stream did; the
ledger explains what was charged and how the turn rendered.

## Regression Coverage

Keep tests close to the contract:

- `RemoteChatRequestEncodingTests` covers Router-only request fields, message
  normalization, idempotency keys, and implicit `max_tokens`.
- `OpenAICompatibleStreamParserTests` covers shared SSE framing, raw JSON
  fallback, split-data repair, streaming tool-call accumulation, and
  `finish_reason=length` handling.
- `RouterAccountUsageCenterTests` covers account status summaries, credits and
  transaction totals, ledger aggregates, signed-request redaction, and support
  export safety.
- `OsaurusRouterProviderTests` covers Router adapter behavior such as billing
  summary frames and empty-stream diagnostics.
- `RouterBillingDatabaseTests`, `RouterBillingLedgerTests`, and
  `RouterBillingOutcomeTests` cover local metadata persistence and outcome
  classification.

When a regression is shared by multiple OpenAI-compatible providers, add it to
the shared parser tests first. Router-specific tests should only cover Router
adapter behavior: billing, diagnostics, request transforms, and policy
selection.
