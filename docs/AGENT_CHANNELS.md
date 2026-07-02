# Agent Channels

Agent Channels are provider-neutral communication connections that expose the
same agent actions across Discord, Slack, Telegram, and custom channel
definitions.

## Standard Actions

- `diagnostics`
- `list_spaces`
- `list_rooms`
- `read_messages`
- `search_messages`
- `draft_message`
- `send_message`
- `reply_thread`

The model-facing tools use these standard verbs through `agent_channel_*`
tools. Provider-specific adapters translate the standard action into the
provider API. Discord is the first executable adapter.

Each connection also reports provider-neutral action policy metadata in
`agent_channel_list_connections` and `agent_channel_diagnostics`:

- `effect` is one of `read_only`, `draft`, `confirmed_write`,
  `relay_receive`, or `unsupported_configured_only`.
- `status` is one of `available`, `unavailable`, `configured_only`,
  `unsupported`, or `disabled`.
- `requires_confirmation` is true for provider write actions that must receive
  `confirm_send: true`.
- `dedupe_key`, `idempotency_required`, and `constraints` explain the
  confirmation, allowlist, and duplicate-suppression contract an adapter must
  honor.

Relay receive is reported separately as `relay_receive_policy` because there is
not yet a model-facing receive tool. The standard relay policy reports whether
the connection requires a stable provider event id, acknowledges duplicates
without dispatching the same event again, persists a normalized external
message snapshot, and treats cursor updates as optional.

Relay receive also reports `inbound_authorization`. This is the provider-neutral
pre-dispatch gate an adapter must apply before external content reaches agent
context or tool input. The default decision is deny. A receive event is
dispatchable only when it has a stable provider event id, is not a replay when
the message store can check seen events, targets an allowlisted group/space
when one is configured, targets an allowlisted room/channel, comes from an
allowlisted sender, and is not a bot or self message unless the connection
explicitly allows those message types. If provider event ids are required, an
adapter must provide the message store before an otherwise valid event can be
allowed; missing replay state fails closed. Inbound authorization also requires
an explicit connection id and never falls back to the default Discord
connection. Group/space-scoped events fail closed when a space id is present
but no space allowlist is configured, unless the connection explicitly opts into
`allowUnscopedSpaces`. Each decision carries an `audit_decision_reason` so
denied relays can be logged without exposing secrets or external message
content.

## Configuration

Non-secret channel definitions live in `agent-channels.json`. Secrets should be
stored separately in Keychain and referenced by name.

The connection center implementation can create, edit, delete, export, import,
and diagnose JSON-backed channel definitions, but the management entry remains
hidden while Agent Channels are still WIP. This keeps unfinished Discord/channel
settings out of the normal app surface while preserving the reviewable
configuration foundation.

```json
{
  "schemaVersion": 1,
  "connections": [
    {
      "id": "ops-webhook",
      "name": "Ops Webhook",
      "kind": "custom_http",
      "enabled": true,
      "supportedActions": ["diagnostics", "send_message"],
      "spaceAllowlist": ["ops"],
      "readRoomAllowlist": [],
      "writeRoomAllowlist": ["alerts"],
      "writeEnabled": true,
      "defaultReadLimit": 25,
      "inboundAuthorization": {
        "senderAllowlist": ["user-1"],
        "roomAllowlist": ["alerts"],
        "allowUnscopedSpaces": false,
        "allowBotMessages": false,
        "allowSelfMessages": false,
        "requireProviderEventId": true,
        "auditDecisionReason": "ops_webhook_receive_gate"
      },
      "secrets": [
        { "name": "bearer", "keychainId": "ops_webhook_token" }
      ],
      "customHTTP": {
        "baseURL": "https://hooks.example.test",
        "allowedHosts": ["hooks.example.test"],
        "allowedMethods": ["POST"],
        "allowInsecureHTTP": false,
        "timeoutSeconds": 15,
        "maxResponseBytes": 131072,
        "actions": {
          "send_message": {
            "method": "POST",
            "path": "/rooms/{{input.room_id}}/messages",
            "headers": {
              "Authorization": "Bearer {{secret.bearer}}",
              "Content-Type": "application/json"
            },
            "bodyTemplate": "{\"text\":{{input.content}}}",
            "successStatusCodes": [200, 201, 202],
            "responseMapping": {
              "idPath": "id",
              "contentPath": "text",
              "timestampPath": "created_at"
            },
            "idempotency": {
              "header": "Idempotency-Key",
              "responseIdPath": "id"
            }
          }
        }
      }
    }
  ]
}
```

Custom JSON execution is implemented as a configuration-only adapter behind the
standard `agent_channel_*` tools. It does not add provider-specific standalone
tools. Each configured action must map to a standard Agent Channel action, and
the runner enforces the same read/write gates as native adapters before it
builds an HTTP request.

## Safe Custom JSON Runner

Custom JSON channels are bounded HTTP adapters for services that expose simple
JSON APIs. They are intended for connector-style integrations, not arbitrary
network browsing.

Request safety:

- `baseURL` must be an absolute HTTP(S) URL. HTTPS is required unless
  `allowInsecureHTTP` is true.
- `allowedHosts` limits the final request host. When omitted, only the base URL
  host is allowed.
- `allowedMethods` limits methods globally per connection. Each action method
  must be an uppercase token and must be allowlisted.
- Action `path` values must start with `/` and cannot contain `//`, `://`, `?`,
  `#`, or control characters.
- Localhost, loopback, RFC1918 private IPv4 ranges, link-local/cloud metadata
  addresses, carrier-grade NAT, multicast, IPv6 loopback, IPv6 link-local, and
  IPv6 unique-local hosts are denied before dispatch.
- Redirects are disabled by the default runner session.
- Request bodies are capped, responses are capped by `maxResponseBytes`, and
  action-level timeout/response limits are clamped.
- Headers cannot override `Host`, `Content-Length`, `Connection`, or
  `Transfer-Encoding`, and header names/values reject invalid control data.

Read/write gates:

- `list_rooms` checks `spaceAllowlist` when it is non-empty.
- `read_messages`, `read_thread`, and `search_messages` require room ids in
  `readRoomAllowlist`.
- `draft_message`, `send_message`, and `reply_thread` require `writeEnabled`
  and target ids in `writeRoomAllowlist`.
- `send_message` and `reply_thread` also require `confirm_send: true`.
- `draft_message` is a local dry run. It returns a redacted request summary and
  never dispatches HTTP.
- The custom runner has an injectable authorization policy hook so tests and
  future shared Agent Channel contracts can deny a standard action after the
  static allowlists pass and before HTTP dispatch.

Templates:

- Supported placeholders are `{{input.name}}`, `{{connection.id}}`,
  `{{connection.name}}`, `{{connection.kind}}`, `{{secret.name}}`, and
  `{{idempotency.key}}`.
- Path placeholders are percent-encoded as path segments.
- Query and header placeholders render as raw strings, after newline/header
  validation.
- JSON request bodies are parsed after rendering. For JSON fields, leave
  placeholders unquoted: use `"text":{{input.content}}`, not
  `"text":"{{input.content}}"`. The renderer inserts a valid JSON literal, so
  quotes and braces inside user content cannot escape into sibling fields.
- Non-JSON request bodies may be static, but cannot contain placeholders. This
  avoids form/XML/text body injection through user-controlled message content.
- Unknown placeholders, missing inputs, missing secrets, and malformed rendered
  JSON reject the action before dispatch.

Secrets:

- The JSON file stores only `secrets` references:
  `{ "name": "bearer", "keychainId": "ops_webhook_token" }`.
- Runtime lookup uses Keychain entries under plugin id
  `osaurus.agent-channel.<connection_id>` for the default agent, trying
  `keychainId` first and then `name`.
- Diagnostics report secret names and placeholder references only. They do not
  resolve or print raw secret values.
- Provider error bodies and mapped raw JSON are scrubbed for any resolved secret
  values before they enter tool output.

Responses:

- `responseMapping.itemsPath` selects arrays for `list_spaces`, `list_rooms`,
  `read_messages`, and `search_messages`; defaults are `spaces`, `rooms`, and
  `messages`.
- `idPath`, `namePath`, `roomIdPath`, `threadIdPath`, `contentPath`,
  `authorIdPath`, `authorNamePath`, `timestampPath`, and `cursorPath` select
  fields inside provider objects.
- Mapping paths are bounded: at most 160 UTF-8 bytes, 12 dot-separated
  segments, no empty/control/template/wildcard/bracket syntax, and array
  indexes must be 1,000 or lower. Mapped row output is capped at 100 rows.
- Read and search results are marked `partial: true` because the runner only
  proves the provider response slice it fetched.
- Successful writes return `partial_write: false` and
  `delivery_status: "confirmed"`.
- If cancellation, transport failure, HTTP failure, or malformed write response
  happens after dispatch, tool failures include a `partial_write_status` such as
  `cancelled_after_dispatch`, `transport_unconfirmed`,
  `http_status_unconfirmed`, or `malformed_write_response`.
- When a write receives a 2xx response but JSON parsing or response mapping
  fails, the idempotency ledger preserves an unconfirmed terminal state for the
  key so an immediate retry cannot duplicate the delivery.

Idempotency:

- Configure `idempotency.header` to send an idempotency key with write actions.
- Configure `idempotency.keyTemplate` when the provider requires a specific key
  format; otherwise Osaurus derives a stable key from connection id, action,
  target, and content.
- Configure `idempotency.responseIdPath` when the provider's id field differs
  from the normal response mapping.
- Repeated write attempts with the same completed key are suppressed in-process
  and return `delivery_status: "duplicate_suppressed"` without dispatching
  another HTTP request. Concurrent repeats while the first request is still in
  flight are reserved and return
  `delivery_status: "duplicate_in_flight_suppressed"` without a second
  delivery attempt.

Diagnostics:

`agent_channel_diagnostics` for a custom JSON connection is a dry run. It
validates base URL safety, configured method allowlists, header names, template
inputs, secret reference names, response mapping presence, idempotency presence,
and per-action request shape without resolving secrets or making network
requests.

## Connection Center Validation

The connection center validates channel definitions before saving:

- `discord` is reserved for the native Discord adapter.
- Custom HTTP connections require an HTTP or HTTPS base URL.
- Custom HTTP base URLs run through the same blocked-host policy used by the
  runner, so localhost/private/link-local targets are rejected before save.
- Custom action names must match supported standard actions.
- HTTP action paths must start with `/`.
- Header/query fields and secret references reject line breaks.
- `responseMapping` paths and `idempotency.responseIdPath` must satisfy the
  same bounded response-path rules used at runtime.
- Secret references store only `name=keychain-id` pointers, not raw credentials.

## Discord Connection

Discord is the first native Agent Channel connection. It is addressed through
`connection_id: "discord"` on the `agent_channel_*` tools rather than through a
separate Discord-specific model-facing tool set.

The Discord bot token is stored in Keychain. The JSON configuration stores only
non-secret IDs and policy:

- `configuredGuildIds` limits which servers can be inspected.
- `readableChannelIds` limits rooms that `read_messages`, `read_thread`, and
  `search_messages` can read.
- `writableChannelIds` limits rooms that `draft_message`, `send_message`, and
  `reply_thread` can target.
- `writeEnabled` must be true, and send/reply actions still require
  `confirm_send: true`.

## Message State And Dedupe

Agent Channels keep provider-neutral message state in
`agent-channels/messages.sqlite`. The store is opened through the same
SQLCipher-aware storage stack as chat history, memory, and tools, and is
included in storage export/key rotation.

The schema is intentionally provider-neutral:

- `channel_messages` stores inbound and outbound message snapshots keyed by
  `connection_id + room_id + provider_message_id`.
- `channel_seen_events` stores receive-side event ids keyed by
  `connection_id + provider_event_id`.
- `channel_receive_cursors` stores optional per-room cursors for polling or
  relay catch-up.
- `channel_audit_events` stores redacted receive/action decisions so operators
  can prove whether an external message was accepted, denied, or treated as a
  duplicate while keeping copied support evidence bounded and best-effort
  redacted.

Native adapters should write message snapshots whenever they read or send a
message. Discord does this for `read_messages`, `search_messages`, and
`send_message`, so repeated reads cannot duplicate the same provider message in
the local store. The store keeps only the newest 1,000 message snapshots per
connection/room pair so busy channels do not grow the database without bound.

Relay or webhook receivers should follow the same sequence used by the Telegram
plugin pattern:

1. Verify the provider secret/signature before parsing user-visible content.
2. Build a stable provider event id, such as a Telegram update id, Discord
   message snowflake id, or Slack event id. Do not use session-scoped sequence
   numbers that can change when a provider replays the same logical message. If
   a connection explicitly opts out of provider event ids, the authorization
   request must carry the stable provider message id instead.
3. Run the connection's inbound authorization gate before adding message text
   to agent context or tool input. Unauthorized groups/spaces, rooms, senders,
   bot messages, self messages, duplicate events, and missing replay state must
   be acknowledged or dropped according to the decision reason without
   dispatching to an agent.
4. Call
   `recordReceiveEvent(connectionId:providerEventId:authorization:message:cursor:)`
   with the authorization decision from step 3. The store enforces that the
   decision is an `allow` decision for the same connection, event or provider
   message id, room, and sender before writing any receive state. A result with
   `disposition == denied` or `shouldDispatch == false` must be acknowledged or
   dropped without agent dispatch.
5. Dispatch only the normalized stored snapshot as untrusted external data.
6. Preserve the cursor returned by the provider when one exists.

Before step 5, adapters should also pass the normalized external text through
`ChannelRemoteSafetyGate.shared`. The shared remote safety gate rate-limits
authorized senders, requires fresh reply-token proof before dangerous remote
approvals or Computer Use starts, limits concurrent remote Computer Use tasks
per sender, and produces a typed untrusted-content assessment. Channel-returned
status, result, and artifact text should be sanitized with the same gate so
reply tokens, credentials, and oversized result payloads are not echoed back
into a shared room.

When a remote action requires a reply token, adapters must pass the raw token
through `ChannelReplyTokenService` first and send only the service-produced
validation into the remote safety gate. The gate assumes that cryptographic
signature verification and durable nonce consumption have already happened.

The helper performs the event dedupe insert, normalized inbound message
snapshot write, per-room pruning, and optional cursor update in one transaction.
Adapters should not dispatch before this call succeeds. When a connection opts
out of provider event ids, the helper still requires an allow decision and uses
the normalized provider message id, bound into that allow decision, to suppress
duplicate dispatch for the same message snapshot.

Receive decisions also write a redacted audit row. Accepted rows record whether
the normalized snapshot was inserted and dispatchable. Duplicate rows record
that the provider event or message snapshot was acknowledged without a second
dispatch. Denied rows record the typed denial reason before any message reaches
agent context. Audit summaries are redacted at write time and exports omit raw
payload JSON so support bundles can be copied without intentionally leaking
channel secrets. Redaction is best-effort and targets known credential, token,
email, and phone shapes; unknown secret shapes should still be handled with the
same care as any diagnostic export.

The audit ledger is retention-bounded. The store keeps at most 10,000 audit rows
per connection by default and also exposes explicit time-based pruning for
maintenance jobs. This keeps repeated denied or replayed traffic from growing
the channel database without bound.

## Inbox And Audit Workbench

The Agent Channels connection center includes an Inbox & Audit workbench backed
by `AgentChannelAuditWorkbenchService`. It can show recent redacted message
snapshots, receive decisions, accepted/denied/duplicate counts, and a copyable
redacted JSON export for the selected connection or all connections.

This workbench is diagnostic evidence, not an authorization layer. Adapters
must still run provider verification, inbound authorization, replay checks,
reply-token validation, and remote safety gates before dispatching or writing to
a channel. The workbench helps maintainers and operators answer: "Did this
group message come from an authorized sender, and if not, why was it dropped?"

This foundation does not add a live Discord receive relay. It adds the durable
message, duplicate-filtering, and redacted audit foundation that a relay,
webhook receiver, Slack adapter, or Telegram adapter can share.

## Async Channel Substrate

Async inbound channels should build on the shared substrate in
`Models/AgentChannel` and `Services/AgentChannel` before dispatching an agent
turn. The substrate captures the reusable contracts from Telegram-style chat
bridges and email-style resend bridges:

- Verify the webhook or source first with either a shared-secret header or an
  HMAC-SHA256 body signature. Verification failures are typed and never include
  the configured secret in diagnostics.
- Evaluate sender policy with blocklists, allowlists, default disposition, and
  bot-sender handling before parsing user-visible content into a prompt.
- Create an idempotency key from the connection plus the provider event id and
  register it through the Agent Channel message store. Duplicates should be
  acknowledged without creating another dispatch.
- Derive the chat session partition from `(agent_id, connection_id,
  provider_conversation_id, provider_thread_id, salt)` using a hash-backed
  external session key. Provider routing ids stay out of model-visible prompt
  text and sidebar grouping keys.
- Mint an opaque reply token for each inbound turn. The token is what the agent
  sees; the token registry holds the provider conversation/thread/reply address,
  agent scope, session id, task id, issue time, and expiry. The registry prunes
  expired bindings on issue/resolve activity and exposes explicit pruning for
  adapter maintenance jobs.
- Track artifact forwarding with typed statuses (`queued`, `forwarded`,
  `skipped`, `blocked`, `failed`) so adapters can report whether shared
  artifacts were actually delivered to the remote channel.
- Emit bounded in-memory audit events with typed status/failure values and
  hashed audit keys rather than raw provider event or routing ids. Adapters
  that need durable audit evidence should drain these events into their own
  channel store or support artifact.

The substrate is not a provider implementation. Discord, Telegram, Slack,
email, and custom adapters still own provider payload parsing, provider API
calls, rate-limit behavior, and channel-specific formatting. They should share
these contracts so retries, reply routing, session partitioning, and audit
event semantics behave consistently across channel families.
