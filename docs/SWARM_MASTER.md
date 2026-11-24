# Osaurus Swarm: the master side

Status: in development (Mac master, Mac nodes). This page describes how the
Osaurus Mac app acts as a Swarm **master**: it pairs the user's own Macs as
inference **nodes**, manages their model libraries, groups them into **pools**,
and routes model requests to them. The node app and the master library live in
a separate, private repository and reach this app only as a vendored Swift
package.

## What Swarm is

- A **node** is another Mac running Osaurus Swarm: an engine host with a model
  library and its owner's limits. It holds no agents, tools, memory,
  conversation data or keys. Pairing grants inference only.
- The **master** (this app) keeps the agent loop, tool execution, memory,
  privacy filter and conversation storage. Only the model request (messages,
  tool schemas, explicit sampling options) goes to a node; the node streams
  structured events back.
- A **pool** is a named group of nodes that serve the same model(s). Callers
  ask the pool, never a node. The master's scheduler grants a time-limited
  **lease** on one node, renews it while the caller keeps sending requests,
  and releases it at expiry when idle.
- Nodes are reached only over direct paths (LAN, Thunderbolt bridge, or a
  direct internet path). Relayed paths are never used; such a node shows as
  Unreachable.

## The seam

```
 Settings UI ──┐                        ┌── RemoteProviderManager (pickers, spawn
 (Providers →  │                        │    targets, /v1/models, routing list)
  Osaurus      ▼                        │
  Swarm)   SwarmManager (@MainActor) ───┼── SwarmModelService (ModelService +
               │  nodes, pools,         │    ToolCapableService)
               │  installs, pairing,    │
               │  leases, activity      │
               ▼                        │
        SwarmMasterBackend (protocol) ◄─┘
          ├─ library adapter  (vendored OsaurusSwarm package, when present)
          └─ SwarmSimulatorBackend (in-process fake nodes: tests, dev builds)
```

`SwarmMasterBackend` (`Services/Swarm/SwarmMasterBackend.swift`) is the only
interface to the library. It mirrors the library's FFI surface:

| Area | Calls |
| --- | --- |
| Lifecycle | `start(masterName:stateDirectory:)`, `shutdown()`, `events()` |
| Nodes | `nodes()`, `beginPairing()` → 12-character code + QR payload + expiry, `cancelPairing()`, `removeNode` (revoke + forget), `renameNode` |
| Library | `installModel(on:source:)` with `.huggingFace(repoOrURL, revision)` (a full `https://huggingface.co/…` link or `org/repo`) or `.peer(modelId, fromNode)`, `cancelInstall`, `deleteModel`, `loadModel`, `unloadModel`, `setPreheat` |
| Pools | `pools()`, `createPool`, `updatePool`, `deletePool` |
| Leases | `acquireLease(poolId, nodeIds, modelId, leaseSeconds, maxWaitSeconds, callerKey)`, `renewLease`, `releaseLease` |
| Inference | `infer(nodeId, request)` → stream of `content`, `reasoning`, `toolCall`, `toolCallProgress`, `prefillProgress`, `completion`; `cancelInference(requestId)` |
| Events | `nodeUpdated`, `nodeRemoved`, `pairingCompleted`, `pairingFailed`, `installProgress`, `leaseRevoked`, `poolsChanged` |

Scheduling (warm-first node choice, one lease per node, FIFO queue with the
pool's max wait, renew, release, expiry while idle, revocation) lives in the
library so every master platform shares one implementation. The app only calls
`acquireLease`. `SwarmLeaseScheduler` implements the same contract in Swift for
the simulator and the unit tests.

### Runs in the app process

The library ships as a dynamic framework (`OsaurusSwarmFFI.framework`, a
package binary target that Xcode embeds and signs in `Contents/Frameworks`
like Sparkle and Sentry; a dynamic image keeps its own Rust runtime apart
from OsaurusSync's static one, which a static link cannot: two Rust static
libraries exceed ld's compact-unwind personality limit). It is loaded into
the app's process, never run as a separate helper binary: macOS Local Network
privacy is granted per app, and only the app's approval covers mDNS
discovery and LAN dials. `Info.plist` declares the `_osaurus-swarm._udp`
Bonjour service beside the existing sync / models services, and
`NSLocalNetworkUsageDescription` mentions Swarm. When the library backend
runs, Settings probes the Bonjour service; if Local Network access is denied
the Nodes tab shows **Allow Local Network to Find Nodes** (with a button to
the Privacy & Security → Local Network pane) instead of an empty node list.

### Vendoring

The Swarm package is private. It is vendored, like OsaurusSync, but **not
committed**:

- `scripts/update-osaurus-swarm.sh <version> [sha256]` or `--local <checkout>`
  places the Swift package (UniFFI bindings + `OsaurusSwarmFFI.xcframework`)
  at `Packages/Vendor/OsaurusSwarm` and records the source in
  `Packages/Vendor/OsaurusSwarm.version`. Both paths are gitignored, and the
  script refuses to leave them tracked.
- `Packages/OsaurusCore/Package.swift` adds the `OsaurusSwarm` dependency only
  when `Packages/Vendor/OsaurusSwarm/Package.swift` exists. Without it the app
  builds unchanged.
- `SwarmLibraryBackend` (behind `#if canImport(OsaurusSwarm)`) adapts the
  library's `SwarmMaster` to `SwarmMasterBackend`: blocking FFI calls run off
  the main actor, library events and inference listeners become async
  streams, typed library errors become `SwarmError`, and the device key lives
  in the Keychain (`ai.osaurus.swarm`; a file in the Swarm state directory
  only in keychain-disabled test launches). Without a backend, Swarm is hidden: no
  Providers row, no picker entries, no routing. Settings search still lands on
  the Osaurus Swarm page, which then says the build doesn't include Swarm.
- Dev and live-proof builds without the library can launch with
  `OSAURUS_SWARM_SIMULATOR=1` to run in-process simulated nodes. The UI marks
  them **Simulator**. Simulated pairing completes a few seconds after a code
  is shown; installs, loads and generation are simulated, and a reply names
  the node and model it "ran" on. A user message containing
  `swarm-sim:call <tool> <json>` makes the simulated node emit that tool call,
  for deterministic tool-loop checks.

## Pool models in every picker

`SwarmManager` publishes one `SwarmCatalogEntry` per pool × model to
`RemoteProviderManager.setSwarmCatalog`. Swarm is then a provider on the
surfaces every remote provider already feeds:

| Surface | How |
| --- | --- |
| Chat picker, agent model, workflow steps, schedules | `cachedAvailableModels()` gains an **Osaurus Swarm** group; `ModelPickerItem.fromSwarmEntry` shows "model · pool" and the live capacity ("2 of 2 nodes available", "No nodes available") |
| `spawn_model` pools, `spawn_agent` model override | `connectedSpawnModelTargets()` / the spawn index include Swarm targets (`remote-provider:<swarm-id>/<pool-slug>/<model>`) |
| HTTP API model ids, `/v1/models` | `osaurus-swarm/<pool-slug>/<model-id>`; listed when exposed in Server → Exposed Models, like other provider models |
| Routing (Chat Completions, Responses, Anthropic, Ollama, plugins, core model, compaction) | `RemoteProviderManager.routableServices()` = connected providers + `SwarmModelService`; every former `connectedServices()` routing call site uses it |

A pool with no available node stays selectable; a send queues. Swarm entries
are not hidden in offline mode, since Swarm never uses the internet path.

Renaming a pool changes its slug and therefore its model ids, as renaming a
provider changes its prefix. Pool names whose slugs collide are refused.

## Request path

`SwarmModelService.streamWithTools` (all other entry points delegate to it):

1. **Lease.** `callerKey` is the chat session id (or the request's activity
   id). The same caller renews its lease on the same node, keeping the node's
   prefix cache warm across an agent loop. If the grant takes longer than
   300 ms, the turn shows **Waiting for a Swarm node in <pool>** (a queued
   prefill hint with a detail line). At the pool's max queue wait the request
   fails with `swarm_pool_busy`. There is no fallback to local or cloud.
2. **Request.** The body is the OpenAI Chat Completions shape the node's
   engine already serves. Sampling fields are sent only when the caller set
   them explicitly (`samplingParametersAreImplicit == false`,
   `maxTokensExplicit`), so the node's bundle `generation_config.json` stays
   the default. Reasoning is turned off only on an explicit user choice.
3. **Events.** `SwarmEventMapper` maps node events onto the existing in-band
   stream: content → text, reasoning → `StreamingReasoningHint`, tool call →
   `StreamingToolHint` preview + a `ServiceToolInvocation(s)` finish (the
   agent loop's dispatch contract), tool-call progress →
   `StreamingToolCallProgressHint`, prefill → `StreamingPrefillProgressHint`,
   completion → `StreamingStatsHint` (token count, token/s, prefill token/s,
   prompt and cached tokens, finish reason). A tool call cut off by the output
   budget is never run (`ServiceToolResponseExhausted`). The engine may not
   emit tool-call or prefill progress; nothing depends on them.
   A node is an untrusted peer, treated like a cloud API: the private
   `U+FFFE` hint sentinels are stripped from every node string (content,
   reasoning, tool-call progress, tool names, arguments, call ids) so node
   text can never forge a tool, stats, billing or progress hint; a tool call
   must name a tool this request offered and carry JSON-object arguments,
   otherwise the request stops on the node and fails with
   `swarm_invalid_tool_call` and nothing runs; the finish reason is reduced
   to a plain token before it rides the stats hint. Node-supplied names,
   model ids and reasons are rendered verbatim in Settings (never as catalog
   keys / Markdown). In error text, which can reach Markdown surfaces such
   as a chat error turn, peer text is quoted as an inline code span
   (`SwarmText.inert`), which renderers never linkify or format. Node display names
   are master-assigned; the node's own name is only a suggestion at pairing.
4. **Stop.** Cancelling the consumer cancels the producer task, which calls
   `cancelInference(requestId)` on the node.
5. **Lost lease.** Before any output reached the caller, a lost lease (node
   paused, offline, over its cap, no direct path) retries on another node of
   the same pool with the **same idempotency key** (`parameters.idempotencyKey`
   or one derived from the activity id). After output started, the request
   fails with a typed `swarm_lease_lost` error instead of duplicating output.

### Typed errors

`SwarmError` carries a stable `code` and HTTP status, used by the HTTP layer
(`openAIErrorType`, `localRuntimeHTTPStatus`):

| Code | HTTP | When |
| --- | --- | --- |
| `swarm_pool_busy` | 503 | no node became free within the pool's max queue wait |
| `swarm_lease_lost` | 503 | the node stopped serving mid-generation |
| `swarm_node_offline`, `swarm_no_direct_path`, `swarm_node_paused`, `swarm_update_required` | 503 | node state |
| `swarm_fit_refused`, `swarm_cap_exceeded` | 400 | install / load / preheat does not fit the node's cap or disk (message names the limit, e.g. "Needs 18 GB, the node's memory cap is 16 GB") |
| `swarm_engine_error` | engine's | the node's engine refused the request; status and message passed through verbatim |
| `swarm_pool_not_found`, `swarm_model_not_installed`, `swarm_node_not_found` | 404 | stale ids |
| `swarm_invalid_tool_call` | 502 | the node called a tool the request did not offer, or sent non-object arguments |

In chat these appear as the turn's error text.

## Subagent fan-out

`SpawnFanOutLimits` counts local workers (GPU/RAM bound) and remote workers
(cloud). Swarm workers are dispatched as remote-provider targets, so they
consume the remote fan-out allowance, and each pool's scheduler admits them:
N `spawn_model` workers on one pool fan out across its free nodes and queue
for the rest within the pool's max wait. No pool-capacity ceiling refuses a
spawn; capacity shows up as queueing, which the user controls with **Max
Queue Wait**. A dedicated `swarm` term in `SpawnFanOutLimits` (so Swarm
workers stop sharing the cloud allowance) is a follow-up once lease-holding
spawns are measured live.

## Settings → Providers → Osaurus Swarm

A child page of Providers (`ManagementTab.swarm`, shown on the Providers page
under **Your Devices** when a backend exists) with three tabs:

- **Nodes**: **Add Node** (pairing code + QR, 5-minute expiry), node list with
  hardware, memory in use against the owner's cap, free disk, connection path,
  status and models. **Manage** opens a node: **Install a Model** from a
  Hugging Face link or `org/repo`, **Copy From Another Node**, the **Model
  Library** (Load / Unload, **Keep Loaded** preheat, **Delete from Node** with
  a warning naming the pools it leaves), rename, **Remove Node**.
- **Pools**: **New Pool** / Edit with **Pool Name**, models, member nodes
  (only nodes with every chosen model), **Lease Duration**, **Max Queue Wait**,
  optional **Context Length**; delete from the row's ⋯ menu.
- **Activity**: active leases (node, pool, model, time left, requests served,
  Release), waiting requests, per-node token/s, recent events and errors.

Every control has a `SettingsSearchIndex` row (`providers.swarm.*`), a
matching landing anchor, a `guide-settings.md` entry and a
`SettingsSearchSelfFindProbe` label.

## Proof plan

Unit tests (`Tests/Swarm/`) cover the scheduler (warm-first choice, one lease
per node, caller affinity, queue and `swarm_pool_busy`, expiry while idle, no
expiry mid-request, revocation), the event mapper, the request body (no
implicit sampling defaults), identity parsing, the catalog, routing through
`ModelServiceRouter`, Stop → node cancel, and lost-lease retry with the same
idempotency key.

Live proof is through the real app only (Settings and Chat UI, driven with
System Events; never curl or the CLI). Until the library is vendored, rows
proven against the simulator are labeled **simulated**; every row that needs a
real node (pairing a second Mac, Hugging Face installs on it, token/s from a
real engine, memory footprint within the node's cap, direct-path checks) is
`BLOCKED` on the library and reported as such.

## Later

- **Windows master** (`osaurus-win`): later. It consumes the same master
  library through C# bindings; scheduling already lives in the library, so
  the Windows app needs the provider entries, pickers and settings pages, not
  a second scheduler.
- Pool-capacity term in `SpawnFanOutLimits`; per-agent lease-duration
  override; explicit lease release when an agent run ends (today leases end
  at expiry while idle).
