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
        "actions": {
          "send_message": {
            "method": "POST",
            "path": "/rooms/{room_id}/messages",
            "headers": {
              "Authorization": "Bearer ${secret:bearer}"
            },
            "bodyTemplate": "{\"text\":\"${content}\"}"
          }
        }
      }
    }
  ]
}
```

Custom HTTP execution is intentionally not enabled until the request templating,
credential substitution, response mapping, and security review are implemented.
Until then, JSON custom channels can be loaded and diagnosed, while executable
actions are provided by native adapters such as Discord.

## Connection Center Validation

The connection center validates channel definitions before saving:

- `discord` is reserved for the native Discord adapter.
- Custom HTTP connections require an HTTP or HTTPS base URL.
- Custom action names must match supported standard actions.
- HTTP action paths must start with `/`.
- Header/query fields and secret references reject line breaks.
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

The helper performs the event dedupe insert, normalized inbound message
snapshot write, per-room pruning, and optional cursor update in one transaction.
Adapters should not dispatch before this call succeeds. When a connection opts
out of provider event ids, the helper still requires an allow decision and uses
the normalized provider message id, bound into that allow decision, to suppress
duplicate dispatch for the same message snapshot.

This PR does not add a live Discord receive relay. It adds the durable message
and duplicate-filtering foundation that a relay, webhook receiver, Slack
adapter, or Telegram adapter can share.
