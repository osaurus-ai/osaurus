# Agent Collaboration Protocol

This document defines the prerequisite protocol contract for future Osaurus
agent teams. It is not the final team UI, scheduler, channel integration, or
remote execution policy. The goal is a stable local contract that local and
paired remote agents can share before product surfaces coordinate multiple
agents.

## Scope

The protocol lives in `Packages/OsaurusCore/Models/AgentCollaboration` and
`Packages/OsaurusCore/Services/AgentCollaboration`.

It provides:

- A stable `Codable` / `Sendable` envelope with schema, event id, correlation
  id, timestamp, sender, optional recipient, provenance, and typed event
  payload.
- Participant identity for local and remote agents without changing the
  persisted `Agent` or `RemoteAgent` schemas.
- Capability offers and negotiation helpers for local/remote compatibility.
- Request, handoff request, reply, and failure diagnostic events.
- An in-memory transport/service that proves lifecycle behavior without
  changing default chat, agent-loop, channel, or UI behavior.

## Non-Goals

This protocol does not:

- Choose a team layout or multi-agent UI.
- Route through Slack, Discord, Agent Channels, or custom runners.
- Grant workspace, memory, access-key, or data-location permissions.
- Change model prompting, tool routing, sampler defaults, or agent-loop
  behavior.
- Persist collaboration runs.

Those layers can consume this contract later, but they should not redefine the
wire envelope or negotiation semantics.

## Envelope

The wire schema is `osaurus.agent-collaboration.v1`.

Each envelope contains:

- `id`: UUID for the envelope.
- `correlationId`: stable id shared by request, handoff, reply, and failure
  events in one collaboration exchange.
- `createdAt`: ISO-8601 timestamp when encoded with
  `AgentCollaborationWireFormat`.
- `sender`: `AgentCollaborationParticipant`.
- `recipient`: optional `AgentCollaborationParticipant`.
- `provenance`: origin participant, optional session id, optional parent
  envelope id, transport label, and hop ids.
- `event`: typed payload with an explicit event `type`.

Use `AgentCollaborationWireFormat.encoder()` and `.decoder()` for canonical
JSON. The encoder sorts keys and writes ISO-8601 dates.

## Participants

Participants have a stable protocol id and type:

- Local agents use `local:<agent-uuid>`.
- Remote agents use `remote:<remote-agent-record-uuid>`.

Computed adapters on `Agent` and `RemoteAgent` expose participants and default
capabilities. These adapters are intentionally non-persistent; they do not add
fields to existing JSON records.

## Capabilities

Baseline collaboration requires both participants to share:

- `collaboration.correlation`
- `collaboration.provenance`
- `collaboration.request`
- `collaboration.handoff`
- `collaboration.reply`

Both local and remote defaults also advertise
`collaboration.failure-diagnostics`. Type-specific capabilities
(`agent.local`, `agent.remote`) describe the participant but are not required
for a baseline handoff.

Use `AgentCollaborationNegotiator.negotiate(...)` or
`AgentCollaborationService.negotiate(...)` before creating a handoff. A result
is compatible only when the protocol version matches and no required
capability is missing.

## Lifecycle

A minimal handoff flow is:

1. Register or derive local and remote participants plus capabilities.
2. Negotiate shared baseline capabilities.
3. Send `handoff.request` with a correlation id, reason, summary, artifacts,
   and required capabilities.
4. Send `reply` with the same correlation id and an `accepted`, `rejected`, or
   `completed` status.
5. If a participant or transport cannot continue, send `failure` with a typed
   diagnostic code, severity, retryability, related envelope id, and details.

The in-memory service exists to prove this contract in unit tests. Production
team orchestration should keep the same envelope semantics when it adds
persistence, UI, or network transport.
