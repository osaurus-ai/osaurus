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
