# Agent Channel Security Foundation

This document covers the policy-only foundation for future Discord, Slack,
Telegram, and JSON Agent Channel receive flows. It does not implement adapter
routing, an inbox UI, a remote command center, or computer-use triggers.

## Identity Model

Every inbound channel event must be normalized into a `ChannelIdentity` before
policy evaluation:

- `kind`: provider family, such as Discord, Slack, Telegram, or JSON Agent.
- `installationId`: workspace, guild, bot installation, or equivalent provider
  boundary.
- `groupId` and `threadId`: the room, group, channel, topic, thread, or message
  context where the event originated.
- `sender`: stable sender id plus display metadata for diagnostics.
- `trustLevel`: provider-derived trust signal; policy can require a minimum.

Tokens bind to `ChannelIdentityBinding`, which includes kind, installation,
group, thread, and sender id. A reply token issued for one sender or group is
not valid for another.

## Policy Evaluation

`ChannelSecurityPolicyEvaluator` enforces strictest-wins allowlists:

- Sender allowlists gate which users may receive a response.
- Group and thread allowlists gate which shared spaces may dispatch to the
  agent.
- Write actions require explicit `ChannelWritePermission`.
- Write allowlists are additional restrictions, not replacements for the read
  policy.
- If the global channel write kill switch is supplied and disabled, write
  actions are denied even when channel policy allows them.

Empty allowlists mean that dimension is unrestricted. If multiple dimensions are
configured, all of them must pass.

A default enabled policy with no allowlists permits any sender that satisfies
the minimum trust level. Channel setup should configure sender, group, or thread
allowlists before enabling receive flows in shared spaces.

## Reply Tokens

`ChannelReplyTokenService` issues scoped HMAC-signed reply tokens with:

- purpose and action binding;
- channel identity binding;
- nonce;
- issue and expiry timestamps;
- clock-skew enforcement;
- persisted write-gate generation.

Validation verifies signature, purpose, action, identity, kill-switch state,
clock skew, expiry, and then consumes the nonce. A valid token can be used once.
Manual revocation records the nonce as revoked. If the replay store errors,
validation fails closed.

The service requires a caller-provided signing key of at least 32 bytes. This PR
does not generate, store, or rotate that key; adapter wiring should provision it
through a channel-scoped secret before receive flows are enabled.

Reply tokens are scoped capability grants. Validation does not re-evaluate a
mutable `ChannelSecurityPolicy`; callers should evaluate policy before issuing
or accepting a channel response, and use short TTLs, explicit nonce revocation,
or the global kill switch when policy changes must invalidate outstanding write
tokens immediately.

## Proactive Publishing

Proactive publishing (`agent_channel_publish`) is a separate capability from
reactive replies and deliberately does NOT reuse reply tokens: reply tokens are
sender-bound, one-shot reactive grants issued against a specific inbound
message, while proactive publishing is authorized by an operator-configured
`AgentChannelBinding` and enforced by the serialized
`AgentChannelPublishService` at send time.

Bindings come in two forms with identical enforcement:

- **Stored bindings** — explicit operator configuration in
  `agent-channels.json`.
- **Automatic (derived) bindings** — synthesized by
  `AgentChannelAutoDestinationResolver` from configuration the operator
  already completed on a native connection: a saved credential, write access
  enabled, a room on the write allowlist, and an agent assigned by inbound
  dispatch to answer that room. Derivation grants no new write capability —
  it only names routes every send-time gate would already permit — and a
  derived binding is structurally `confirm`-only: it can never be
  autonomous, so a human approves every send (interactive card on attended
  runs, outbox queue on unattended runs). A stored binding for the same
  (agent, connection, room) suppresses the derived one, so customization —
  including "off" — always wins; escalating a route to autonomous requires
  materializing a stored binding through the same acknowledged opt-in as any
  other autonomous destination. All read points (tool exposure, prompt
  section, contextual permission resolution, publish authorization, and
  approval-time re-checks) evaluate the same effective configuration, so
  removing the room from the allowlist, disabling write access, removing the
  credential, or unassigning the agent makes the derived binding vanish
  everywhere at once — a queued approval for it refuses with
  `binding_removed`.

The authorization matrix, re-evaluated in full on every attempt (including
approval of a queued item):

1. **Surface gate** — external surfaces (HTTP, MCP bridge) and runs triggered
   by an inbound channel message are always denied. Provenance comes from the
   typed `SessionSource` task local, not from surface flags alone; a missing
   source is treated as "not authorized".
2. **Run source** — only `chat`, `schedule`, `watcher`, and `self_schedule`
   runs can publish, and only when the binding's `allowedSources` includes the
   current source. `plugin`, `http`, and `channel` sources have no binding
   vocabulary at all.
3. **Binding ownership and state** — the binding must exist, belong to the
   running agent, be enabled, and have an outbound mode other than `off`.
4. **Outbound mode** — `draft` records a local draft (no provider I/O);
   `confirm` resolves the tool's permission to `ask` on attended runs
   (interactive approval card) and queues a pending outbox item on unattended
   runs; `autonomous` sends without a prompt. A user-configured global `.ask`
   on the publish tool narrows even an autonomous binding on unattended runs
   to queued operator approval — the run proceeds, but the human gate moves
   into the outbox instead of the provider write happening.
5. **Thread contract** — a binding-pinned thread always wins; a model-supplied
   `thread_id` is honored only when the binding leaves the thread open, and a
   conflicting request is refused before any ledger claim.
6. **Send-time policy** — at the moment of a provider write: global write
   kill switch, connection enabled, connection write access, room write
   allowlist (or thread-reply support for thread routes), and the binding's
   rate policy against the durable ledger. Provider `confirmSend` is enforced
   a second time at the provider boundary. The policy check and the provider
   write run inside a per-binding lock, so concurrent sends for one binding
   cannot pass the same rate headroom twice.
7. **Approval-time route pinning** — operator actions on a queued/draft/
   unknown item (approve, send, retry) additionally compare the intent's
   STORED route (connection, room, thread) and the run source that queued it
   against the current binding. A binding repointed or narrowed since the
   item was recorded refuses the send (`binding_route_changed` /
   `run_source_not_allowed`) instead of silently following the edit.

Permission composition is strictest-wins: the registry combines the configured
per-tool policy with the binding-resolved contextual policy via
`ToolPermissionPolicy.strictest` (`deny` > `ask` > `auto`), so a global user
setting can narrow a binding but a permissive binding can never loosen a user
setting.

Idempotency and durability: every attempt claims a row in the
`channel_outbound_intents` ledger keyed by (agent, binding, `intent_key`)
before any policy that could vary over time is consulted, so a replayed key
deterministically reports `duplicate` rather than the current rate/kill-switch
state. Status transitions are compare-and-set, which serializes concurrent
sends of one intent down to a single provider write. Send-time denials release
the claim to `failed` with a typed code; retryable failures (deterministic
provider rejections, rate limits) can be retried under the same key without
double-sending.

Ambiguous provider failures — a timeout after dispatch, a 5xx, or an
undecodable success response, where the message MAY have been accepted — are
never treated as retryable. The intent parks as `delivery_unknown`: replays of
the key report `duplicate`, no automatic retry ever runs, and only an operator
may resolve the row (mark it sent, discard it, or explicitly resend knowing a
duplicate is possible). `sending` rows left behind by a crashed run are
reconciled to `delivery_unknown` at startup for the same reason. Custom HTTP
connections may declare provider-side idempotency in their action config;
Discord/Slack/Telegram bot sends have no server-side dedupe key, which is
exactly why the ambiguous class exists.

The prompt payload is redacted by design: the dynamic "Channel Destinations"
section lists only the current agent's usable bindings for the current run
source — stable binding ids, labels, connection/room display ids, modes, and
operator guidance. It never includes secrets, sender identities, other agents'
destinations, or bindings the current run source cannot use. Every publish
attempt (accepted, denied, duplicate, failed) is recorded in the channel audit
log with a redacted content preview.

## Replay Store

`ChannelReplayNonceStore` persists nonce records under the Agent Channels data
directory. Records are scoped by channel identity so nonces cannot collide
across providers, installations, groups, threads, or senders.

## Write Kill Switch

`ChannelWriteKillSwitch` persists a global remote/channel write gate in
configuration. Disabling writes increments a generation counter. Outstanding
write tokens issued under older generations are rejected while disabled and
remain rejected after writes are re-enabled.

If the kill-switch state file is missing, writes use the default enabled state.
If the state file is corrupt or unreadable, writes fail closed until the state is
explicitly recovered.

## Credential Vault

`ChannelCredentialVault` stores adapter secrets in Keychain under the
`ai.osaurus.channels` service with channel-scoped account ids. Account ids bind
to provider kind, installation, optional group/thread, and credential id. The
vault is intentionally channel-specific and is not a shared credential
framework.

When keychain-disabled test mode is active, writes return `false`, reads return
`nil`, and deletes are no-ops that return `true`.

## Diagnostics

Channel diagnostics must redact raw credentials and reply tokens. Denials use
specific reasons for sender, group, thread, write-disabled, expired, replayed,
revoked, identity mismatch, disabled kill switch, and replay-store failure
cases so operators can fix policy without seeing secrets.

Receive adapters should persist redacted audit evidence through the Agent
Channel message store after policy evaluation. The audit ledger records
accepted, duplicate, denied, and failed outcomes with bounded summaries and
typed reasons. Exported workbench views omit full payload JSON and apply
best-effort redaction for known credential, token, email, and phone shapes.
They should still be treated as diagnostic exports because unknown secret shapes
can exist in external text. This gives operators a durable answer for
group-channel questions such as which sender was allowed, which room was denied,
and whether an event was dropped as a replay before external text reached the
agent loop. The audit ledger is bounded by a per-connection retention cap and
supports explicit time-based pruning for maintenance jobs.

## Remote Action Safety

`ChannelRemoteSafetyGate.shared` adds a provider-neutral helper layer for live
remote receive, reply, and Computer Use handoff flows. It is intentionally
separate from provider adapters so Discord, Slack, Telegram, and JSON channels
can share the same safety vocabulary before they dispatch into an agent loop. A
live adapter is not protected by this helper until it explicitly invokes the
shared gate instance.

The default policy:

- requires a fresh accepted reply token before dangerous approvals or remote
  Computer Use starts, and re-checks that the accepted token payload matches
  the current identity, expected purpose, expected action, write-gate
  generation, and expiry time before consuming the proof for single use;
- rate-limits remote channel actions per normalized channel identity;
- allows only one active remote Computer Use task per identity until the task is
  finished or its in-memory lease expires;
- classifies inbound channel text as untrusted external data and records
  prompt-injection-like signals without treating the text as policy;
- redacts reply tokens and credentials, then truncates long result/status text
  before it is returned to a channel.

Adapters must validate raw reply-token strings with `ChannelReplyTokenService`
before passing the service-produced validation to `ChannelRemoteSafetyGate`.
The remote safety gate re-checks the accepted payload and adds in-memory
rate/task/replay defenses, but it does not replace cryptographic signature
verification or durable nonce consumption.

Inbound message text can still be passed to the model, but adapters should wrap
it with `ChannelRemoteSafetyGate.wrapUntrustedContent` so the source, risk
classification, and non-authoritative data boundary are explicit. A suspicious
classification is diagnostic evidence, not an automatic authorization grant or
denial. Authorization remains controlled by allowlists, reply tokens, rate
limits, task limits, and the global write kill switch.

Remote safety rate windows and task leases are in-memory process state. They
are defense-in-depth limits for active adapters, not durable authorization
records. Durable authorization still belongs to channel allowlists, reply-token
validation, nonce replay protection, message-store dedupe, and the write kill
switch. The helper prunes stale in-memory rate windows and task leases lazily
when authorized channel requests are evaluated.

## Local State Assumption

The nonce table and kill-switch state are local JSON files. They are intended to
fail closed on read, write, or corruption errors, but they are not tamper-proof
against a local actor with write access to Osaurus configuration and data
directories.
