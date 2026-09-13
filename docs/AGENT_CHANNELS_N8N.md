# n8n Agent Channel

The `n8n` channel kind lets an n8n workflow talk to an Osaurus agent with
nothing but stock HTTP Request nodes. It is the first Agent Channel kind that
accepts the generic inbound webhook route on the Async Channel Substrate:

```
POST http://<osaurus-host>:<port>/channels/n8n/<connection_id>/inbound
GET  http://<osaurus-host>:<port>/channels/n8n/<connection_id>/tasks/<task_id>
```

Replies are **pull-based**: the inbound call is acknowledged with `202` and a
`poll_url`, and the workflow polls that URL until the task reaches a terminal
status. An optional HMAC-signed push to an n8n Webhook trigger is available on
top of polling, but it runs through the custom JSON runner and is subject to
the same public-HTTPS host policy as every other outbound channel action.

Everything channel-specific lives in:

- `Models/AgentChannel/AgentChannelN8nModels.swift` — connection block and
  envelope v1 contract.
- `Services/AgentChannel/AgentChannelWebhookIngress.swift` — the NIO-free
  actor that verifies, parses, authorizes, stores, dispatches and serves
  polls.
- `Services/AgentChannel/AgentChannelN8nPreset.swift` — projects the optional
  outbound webhook onto ordinary custom HTTP actions.
- `Views/Settings/N8nSettingsView.swift` — the Connection Center setup sheet.
- `Networking/HTTPHandler.swift` — the `/channels/` shim (bearer-exempt).

## Authentication Model

The `/channels/` prefix is exempt from the server bearer/`osk-v1` gate. The
connection secret is the only authentication, so the ingress **verifies the
secret before it reads a single byte of the body**. A caller with the wrong
secret gets `401 unauthorized` whether or not the body is valid JSON, and
nothing is stored or logged beyond a signature-failure counter.

Two verification methods are supported (`AgentChannelSourceVerificationMethod`,
enforced by `AgentChannelAsyncSubstrate.verifyWebhookSource`):

| Method | Header (default) | Value |
| --- | --- | --- |
| `hmac_sha256` (default) | `X-Osaurus-Channel-Signature` | `sha256=<hex HMAC-SHA256 of the exact raw body>`; bare hex is also accepted. Polls carry an empty body, so sign the empty string. |
| `shared_secret_header` | `X-Osaurus-Channel-Secret` | The secret verbatim. |

`none` is never valid for n8n; a connection that decodes with `none` is
normalized back to `hmac_sha256`. Header name and signature prefix are
configurable per connection. Comparison is constant-time.

The secret is stored in Keychain (`ToolSecretsKeychain`, plugin id
`osaurus.agent-channel.<connection_id>`, name `webhook` by default). It never
appears in `agent-channels.json`, responses, activity rows, audit rows or the
Insights request log; the HTTP shim only logs a redacted header twin.

## Connection Block

```json
{
  "id": "n8n-local",
  "name": "n8n (Docker)",
  "kind": "n8n",
  "enabled": true,
  "spaceAllowlist": ["n8n"],
  "inboundAuthorization": {
    "senderAllowlist": ["tpae"],
    "roomAllowlist": ["n8n-test"],
    "allowBotMessages": false,
    "requireProviderEventId": true
  },
  "secrets": [{ "name": "webhook", "keychainId": "webhook" }],
  "n8n": {
    "inboundVerification": { "method": "hmac_sha256" },
    "secretName": "webhook",
    "remoteTransportPolicy": "plaintext_allowed",
    "inboundDispatch": {
      "enabled": true,
      "target": { "kind": "local", "id": "<agent-uuid>" },
      "autoReplyEnabled": false
    },
    "outbound": { "webhookURL": null, "signBodies": true }
  }
}
```

Notes:

- `spaceAllowlist` must contain `n8n` (the fixed provider space id); the save
  path adds it automatically.
- `inboundAuthorization.senderAllowlist` and `roomAllowlist` are **fail-closed**:
  both must be non-empty and match `sender.id` / `conversation_id` or the
  event is recorded as `rejected` and never dispatched.
- `requireMention` is forced `false`; n8n has no mention concept.
- `remoteTransportPolicy` defaults to `secure_channel_required`. Loopback
  callers and Secure Channel (`/secure/call`) callers are always accepted.
- Save-time validation (`AgentChannelConnectionManager`) requires the `n8n`
  block, a non-empty verification header name, and — when `outbound.webhookURL`
  is set — a URL that passes the custom runner's blocked-host policy.

## Envelope v1 (inbound)

```json
{
  "v": 1,
  "event_id": "n8n:exec-4821",
  "conversation_id": "n8n-test",
  "thread_id": "optional-thread",
  "sender": { "id": "tpae", "display": "Terence", "is_bot": false },
  "content": "Reply with the single word PONG",
  "attachments": [
    { "id": "att-1", "filename": "a.png", "content_type": "image/png", "size_bytes": 1234, "url": "https://..." }
  ],
  "reply_token": "optional"
}
```

Rules (`AgentChannelN8nEnvelope.parse`):

- `v` must equal `1` → otherwise `400 unsupported_envelope_version`.
- `event_id`, `conversation_id`, `sender.id`, `content` are required non-empty
  strings → otherwise `400 invalid_payload`.
- `content` is trimmed and capped at 32,000 characters; bodies over 256 KiB are
  refused with `413 payload_too_large` before verification.
- `attachments` are metadata only (first 20 kept); Osaurus never fetches
  `url`.
- `event_id` is the idempotency key: the store dedupes on
  `(connection_id, event_id)`. Use the n8n execution id.

## Inbound Response Shapes

| Status | Body | Meaning |
| --- | --- | --- |
| `202` | `{"status":"accepted","event_id","dispatch":"dispatched","task_id","session_id","poll_url"}` | Stored and dispatched. `task_id == session_id` (deterministic from the session partition). |
| `202` | `{"status":"accepted","dispatch":"suppressed:<reason>", ...}` | Stored but not dispatched (inbound dispatch disabled, no target, etc.). Polling returns `404` until a dispatch exists. |
| `202` | `{"status":"rejected","event_id","reason":"sender_not_allowlisted"}` | Authorization denied; audit row written, no dispatch. Also `room_not_allowlisted`, `space_not_allowlisted`, `bot_message_denied`. |
| `200` | `{"status":"duplicate","event_id","task_id","session_id","poll_url"}` | Replayed `event_id`; no new task or store row. |
| `400` | `unsupported_envelope_version` / `invalid_payload` / `unsupported_kind` / `invalid_task_id` | Contract errors. |
| `401` | `unauthorized` | Secret/signature did not verify. Penalizes the source for rate limiting. |
| `403` | `connection_disabled` | Connection `enabled: false`. |
| `404` | `connection_not_found` / `task_not_found` | Unknown connection, or a task not owned by this connection. |
| `405` | `method_not_allowed` | Wrong verb for the route. |
| `413` | `payload_too_large` | Body over 256 KiB. |
| `426` | `secure_channel_required` | Non-loopback plaintext caller while the policy is `secure_channel_required`. |
| `429` | `rate_limited` | Per-source limit (120 requests/min, 10 s cooldown after a denial). |

Errors use the standard envelope
`{"error":{"code":"...","message":"...","type":"..."}}`.

## Poll Contract

`GET /channels/n8n/<connection_id>/tasks/<task_id>` with the same verification
header (HMAC callers sign the empty body).

```json
{
  "id": "<task uuid>",
  "task_id": "<task uuid>",
  "session_id": "<task uuid>",
  "connection_id": "n8n-local",
  "status": "queued" | "running" | "completed" | "failed" | "cancelled",
  "output": "…latest assistant reply…",
  "output_redacted": false,
  "output_truncated": false,
  "summary": "…",
  "success": true
}
```

- `output` is the latest assistant turn, passed through
  `ChannelRemoteSafetyGate.sanitizeResult` (credential/reply-token redaction
  and truncation).
- `success` is present only for terminal statuses.
- Ownership: a task is readable only by the connection that dispatched it
  (in-memory owner map, or `externalSessionKey` prefix
  `agent-channel:<connection_id>:`). Unknown and foreign tasks both return
  `404 task_not_found` and penalize the source.

## Session Continuity

The session partition is derived from
`(agent_id, connection_id, conversation_id, thread_id)`. Repeated events with
the same `conversation_id` (and `thread_id` when `continueThreads` is on)
reattach to the same chat session, so follow-up questions have context and the
`task_id` stays stable across turns. Use a new `conversation_id` for a fresh
session.

## Topology Matrix

| Caller location | Loopback? | Default policy result | Recommended setting |
| --- | --- | --- | --- |
| n8n on the same Mac (native process) | yes | accepted | `secure_channel_required` (loopback bypasses it) |
| n8n in Docker on the same Mac (`host.docker.internal`) | **no** — traffic arrives from the bridge network | `426` | `plaintext_allowed`; the secret still authenticates every request |
| n8n on the LAN | no | `426` | Secure Channel via the Osaurus relay, or `plaintext_allowed` behind a trusted network |
| n8n anywhere via Osaurus relay + Secure Channel (`/secure/call`) | n/a | accepted | default; requires an agent-scoped `osk-v1` key from the Share Agent flow |

Docker is the important row: the Osaurus server does **not** treat
`host.docker.internal` as loopback, so authenticated routes such as `/models`
return `401` from inside the container, and the channel route returns `426`
until the connection opts into `plaintext_allowed`. The setup sheet surfaces
the Docker URL and this toggle.

## Outbound Push (optional)

If `outbound.webhookURL` is set, save-time projection
(`AgentChannelN8nPreset.applyingOutbound`) writes `send_message` and
`reply_thread` custom HTTP actions onto `connection.customHTTP`, enables
writes, and mirrors the inbound `roomAllowlist` into `writeRoomAllowlist`. The
runner then posts:

```json
{
  "v": 1,
  "event_id": "<runner idempotency key>",
  "connection_id": "n8n-local",
  "conversation_id": "n8n-test",
  "thread_id": "…(reply_thread only)",
  "sender": { "id": "osaurus", "display": "Osaurus", "is_bot": true },
  "content": "…"
}
```

with headers `Content-Type: application/json`, `Idempotency-Key`,
`X-Osaurus-Channel-Kind: n8n`, `X-Osaurus-Connection-Id`, and — when
`signBodies` is true — `X-Osaurus-Channel-Signature: sha256=<hex HMAC-SHA256>`
computed over the exact body bytes with the same connection secret. Verify it
in n8n with `crypto.createHmac('sha256', secret).update(rawBody).digest('hex')`.

The relay reply handler pushes the agent's reply automatically only when
`outbound.webhookURL` is set **and** `inboundDispatch.autoReplyEnabled` is on;
otherwise replies stay poll-only.

**C2 note:** the custom runner's blocked-host policy applies unchanged.
`http://localhost:5678/...`, `127.0.0.1`, RFC1918 and `host.docker.internal`
targets are refused at save time with the blocked-host message. Outbound push
to a local n8n therefore requires a public HTTPS URL (e.g. a tunnel). Pull
mode has no such constraint because n8n is the caller. The channel write kill
switch gates the push path only; polling is read-only and unaffected.

## n8n Workflow Recipe (stock nodes)

1. **Webhook** — `POST /webhook/osaurus-bridge`, respond "Using 'Respond to
   Webhook' node".
2. **Code** — build envelope v1 and the signature:

   ```js
   const crypto = require('crypto');
   const secret = $env.OSAURUS_CHANNEL_SECRET; // or a credential
   const body = JSON.stringify({
     v: 1,
     event_id: `n8n:${$execution.id}`,
     conversation_id: 'n8n-test',
     sender: { id: 'tpae', display: 'Terence', is_bot: false },
     content: $json.body.text,
   });
   const signature = 'sha256=' + crypto.createHmac('sha256', secret).update(body).digest('hex');
   const emptySignature = 'sha256=' + crypto.createHmac('sha256', secret).update('').digest('hex');
   return [{ json: { body, signature, emptySignature } }];
   ```

   Send `body` as a raw string so the signed bytes are the transmitted bytes.
3. **HTTP Request** — `POST http://host.docker.internal:1337/channels/n8n/n8n-local/inbound`,
   body = `{{ $json.body }}` (raw JSON), header
   `X-Osaurus-Channel-Signature: {{ $json.signature }}`.
4. **Wait** — 2 seconds.
5. **HTTP Request** — `GET http://host.docker.internal:1337{{ poll_url }}`
   with `X-Osaurus-Channel-Signature: {{ emptySignature }}`.
6. **IF** — `status` in `queued`/`running` → loop back to **Wait** (bounded by
   the workflow execution timeout); else continue.
7. **Respond to Webhook** — `{ task_id, status, output }`.

With `shared_secret_header` the two signature headers become a single
`X-Osaurus-Channel-Secret: <secret>` header on both requests.

A dedicated `n8n-nodes-osaurus` community node (operations: *Send message and
wait*, *Poll task*, *Verify inbound push*) is planned to replace steps 2–6; it
will speak exactly this contract.

## Observability

- **Connection Center** → n8n card: inbound/poll URLs with copy buttons,
  verification mode, transport policy badge, ingress counters
  (`inbound_accepted`, `inbound_duplicates`, `inbound_rejected`,
  `signature_failures`, `rate_limited`, `poll_requests`, `outbound_sent`,
  `outbound_failed`, last inbound/accepted/outbound timestamps, last failure
  reason).
- **Verify incoming event** waits for the next terminal activity event for
  the connection, identical to the Telegram/Slack flow.
- **Activity / Audit workbench** — stages `received → stored → dispatched`
  (then `agent_replied` when auto-reply is off) or `rejected` /
  `dispatch_suppressed` / `failed`, keyed by `event_id`.
- `agent_channel_diagnostics` includes the ingress health snapshot under
  `inbound_ingress`.

## Tests and Evals

- `AgentChannelWebhookIngressTests` — verify-before-parse, both verification
  methods, fail-closed allowlists, dedupe, envelope errors, transport policy,
  poll ownership, redaction, route parsing, connection validation.
- `HTTPChannelInboundRouteTests` — real NIO server: bearer exemption, 401,
  404, 202 shape, 426, 429.
- `CustomJSONAgentChannelRunnerTests` — body signature known-answer, preset
  shape, loopback outbound still refused.
- `N8nConnectionDraftTests` — setup-sheet draft round-trip and badges.
- Eval `agent_channels.n8n-inbound-contract`
  (`Packages/OsaurusEvals/Suites/AgentChannels/n8n-inbound-contract.json`).

See `docs/CHANNEL_RELEASE_RUNBOOK_N8N.md` for the live-proof matrix.
