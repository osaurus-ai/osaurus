# iPhone over Sync: iOS handoff

What the Mac side now does for each item in the iOSaurus gap list ("iPhone over Sync: gaps in
SYNC_MOBILE_CONTRACT.md"), and what the iPhone app has to build. The wire contract is
[`SYNC_MOBILE_CONTRACT.md`](SYNC_MOBILE_CONTRACT.md) v2. This document is the work plan around
it.

- **Mac branch:** `iphone-sync-gaps`, on `workflows`.
- **Compatibility baseline:** upstream `osaurus-ai/osaurus` `main` at
  `eb0e968c35657472826062d707b5e27a74ca69f9`, the build the App Store iPhone 1.0(11) was made
  against.
- **iOS checkout read:** `iOSaurus` `main` at `c7df6b2`, version 1.0 (12).
- **Test vectors:** `Packages/OsaurusCore/Tests/Sync/SyncFixtures/mobile-*.json`, read by
  `SyncAppDataFixtureTests` against the Mac's own encoders. The iPhone's decoder tests SHOULD
  read the same files.

## 1. Decisions per item

None of the iPhone's features are dropped. Three pieces wait on osaurus-sync (live thinking,
image preview frames and push), and one is replaced (the cloud-spend flag becomes an approval
card).

| # | Item | Decision | Contract |
| --- | --- | --- | --- |
| 1 | Per-turn run options | New `hostRun` fields | §3.1 |
| 2 | Live run detail | New record; live thinking deferred | §3.2, §3.3, §7 |
| 3 | Model picker | Models message and three ops | §5.1, §5.2 |
| 4 | Image models | Image hosted runs; spend through an approval card; preview frames deferred | §3.4, §7 |
| 5 | Agent details and features | Detail messages, `setTool`, `features` and `build` | §0, §5.3 |
| 6 | Privacy, Computer Use and config detail | `detail` per kind, new `privacy_review` kind | §4 |
| 7 | Warm-up | `warm` op | §5.1 |
| 8 | Context usage | New record and `contextUsage` op | §3.6 |
| 9 | Workspace agents | The Mac runs them for the iPhone | §3.5, §5 |
| 10 | Reachability | Directory `presence`; the Mac asks once about Anywhere (Beta) | §1, §2 |
| 11 | Smaller points | Per-iPhone namespaces; the rest needs nothing new | §4.1, §5.1 |

What changed against the gap list, per item:

1. **Run options.** `hostRun` gains `model`, `options {reasoningEffort, thinking}`,
   `voiceCall {instructions}` and `privacy` (`auto`/`off`).
   - The gap list assumed the Mac adds a spoken-answer note. It doesn't any more: the iPhone
     sends its own call note (`ChatViewModel.callInstructions`) in `voiceCall.instructions`.
     The Mac applies it to that run only, without saving it.
   - The fields count only from the user's own devices that aren't revoked.
   - A model the Mac doesn't have, or a value the model doesn't take, comes back as a typed
     `host_declined` reply.
2. **Live run detail.** The core stream is text-only, so the host writes
   `ai.osaurus.run-progress/1` with these parts, coalesced to 500 ms because every app-data
   write is durable:
   - the phase;
   - the prefill stage and counts;
   - tool steps with the Mac's labels and icons;
   - image steps;
   - shared files.

   Committed turns now keep everything:
   - medium values go to blobs before any field is dropped;
   - `turn-detail/1` carries each tool call's label;
   - generated images and shared files arrive as blobs.

   **Live thinking is PARTIAL:** the reasoning arrives with the committed turn, and streaming it
   needs a typed stream channel in osaurus-sync (§4 of this document).
3. **Model picker.** A `models` message in the manage conversation carries `/models/picker`'s
   rows and `favorites`. The ops are `setFavorite`, `getModelOptions` and `setModelOption`.
4. **Image models.** An image request is a hosted run whose `hostRun.model` is an image model and
   whose `hostRun.image` holds the composer settings.
   - Stop works as for chat.
   - The images arrive as blobs on the reply.
   - Cloud spend goes through the run's `approval/1` card, `tool: "image"`, with price, notice,
     privacy and options. This replaces `allow_remote_media_spend`.
   - Rejoining after backgrounding needs nothing: the run continues on the Mac.
   - **Preview frames are PARTIAL** (deferred).
5. **Agent details.**
   - One `agent` message per agent, carrying the system prompt (a blob when over 16 KiB), the
     custom avatar (blob, ≤ 2 MiB) and the `/agents/{id}/tools` rows.
   - The new op is `setTool`.
   - The directory gains `features` and `build`.
6. **Privacy, Computer Use, config.**
   - `computer_use` items carry `ActionPreview` detail and a new `approve_rest` action.
   - `config_approval` carries `ConfigPlan.payload`.
   - A hosted run's Privacy Filter review no longer opens a sheet on the Mac. It is a
     `privacy_review` attention item with the detections. The answer is
     `{action: "approve", redact: [ids]}` or `deny`.
   - Detail is capped, and says `truncated` when cut.
7. **Warm-up.** The `warm {agentId, model?}` op makes the same call as `/agents/{id}/warm`.
   Prefill shows in `run-progress`.
8. **Context usage.** After each hosted run, the Mac writes `ai.osaurus.context-usage/1`
   (`/sessions/{id}/context`'s body). The `contextUsage {scope, agentId, model?}` op prices it on
   demand.
9. **Workspace agents.** The iPhone has no wallet, so it can't join workspaces.
   - The manage state lists teammates' shared agents in `workspaceAgents`.
   - A chat with one is a hosted run whose session carries
     `workspace {workspaceId, agentAddress}` and no `agentId`.
   - The Mac runs it toward that agent with the user's identity.
   - The gap list's `workspaceAgent` field is this existing `workspace` field.
10. **Reachability.** The directory carries `presence {state: awake|sleeping|quitting,
    networkMode, updatedMs}`. When the first iPhone joins a Mac that finds devices only on the
    same network, the Mac asks once whether to turn on **Anywhere (Beta)**. §2 of the contract
    has the wording for each state.
11. **Smaller points.**
    - **Several iPhones:** each writes `attention-answer/1/<its key>` and
      `manage-request/1/<its key>`, and results come back in `manage-result/1/<its key>`. Answers
      carry that iPhone's name. The shared namespaces are still read for one release.
    - **App Intents:** "needs you" is a pending `approval/1` or `prompt/1` entry, or a pending
      attention item, not 30 seconds of quiet.
    - **Background:** call `syncNow` and subscribe again.
    - **Connection warm-up:** over a live connection a manage request came back in 0.25 s; the
      first write before any connection was up took 30 s (the retry interval). Call
      `syncNow()` on foreground and before a write the user waits on (send, stop, approval or
      attention answer, manage request, secret), and show progress rather than a hang for the
      first one.
    - **Lowercase ids:** write `uuid.uuidString.lowercased()` in tags and records, and compare
      ids as `UUID`s. The Mac's `host-run/1.turn` is lowercase. An older Mac ignores a chat
      tagged in uppercase; in the live proof that left a chat with no reply.
    - **Recovery phrase:** never typed into the iPhone; it joins only through a pairing offer.
    - **History filters** (`/projects`, not in the gap list): the manage state carries
      `projects`, `plugins` and `workspaces`.
    - **Edit and resend** (`/truncate`): delete the later messages, then send a new `hostRun`
      turn.

## 2. Gating on features

Each Mac says what its build supports in its directory's `features`. A user can have Macs on
different builds, so the iPhone checks per Mac:

- No directory, or no `features`: a v1 Mac.
  - Basic hosted runs, approvals and secrets work.
  - Answers and requests go to the shared namespaces (read, merge, write).
  - The manage state is the only management record.
  - Say "Update Osaurus on <Mac> for …" where a v2 feature is missing.
- `features` listed: use exactly what's listed. Write per-device namespaces only with
  `per_device_answers`.
- Never infer support from `build`.

## 3. iOS phases

Each phase ends with checks the iPhone team can run against a Mac built from this branch. The
"Mac side" rows are what the Mac's tests prove now.

### Phase 1: Join and find agents

- Link OsaurusSync (`Packages/Vendor/OsaurusSync`: the same xcframework, iOS slice), and open a
  `SyncCore` with platform `ios`.
- Join with a pairing offer: scan the QR code, or paste the `osaurus-pair:` link.
- Read the directories: agents, the Default agent as "Osaurus on <Mac>", `features`, `build`,
  `presence`.
- Show reachability from peer state and `presence` (contract §2).

Acceptance:

- The Mac's Devices list shows the iPhone as **iPhone**.
- On a Mac set to Same Network, the Mac shows **Reach this Mac from anywhere?** once.
- Putting the Mac to sleep changes the iPhone's line to "asleep" once it disconnects; quitting
  Osaurus shows "isn't running".
- `mobile-directory.json` decodes, with every flag known to the app.
- Mac side: `SyncHostedRunTests` (directory), `SyncMobileV2Tests` (presence, features,
  reachability prompt), `SyncAppDataFixtureTests.mobileDirectoryFixtureListsWhatThisBuildSupports`.

### Phase 2: Chat

- Create hosted conversations (contract §3).
- Send `hostRun` with `model`, `options`, `voiceCall.instructions` and `privacy` (§3.1).
- Render the stream and `run-progress/1` (§3.2). On commit, render `turn-detail/1`: tool
  labels and files from blobs (§3.3).
- Stop, the declines, edit and resend (§3.9), and context usage (§3.6).
- Tool approvals (§3.7) and secrets sealed with HPKE (§3.8).

Acceptance:

- A chat with thinking and two tool calls shows each tool's label while it runs, then the
  committed reasoning.
- A voice call's turns carry the call note, and the Mac's saved chat doesn't contain it.
- Picking a model the Mac lacks gets "… isn't on this Mac".
- A resent edit gets exactly one reply.
- The context ring matches the Mac's chip after a run.
- `mobile-hosted.json` decodes.
- Mac side: `SyncMobileV2Tests` (options, own-device gate, declines, progress cadence, turn
  detail, blobs before dropped fields), `SyncHostedRunTests` (including
  `anEditedAndResentTurnIsAnsweredOnce`), `SyncAppDataFixtureTests`.

### Phase 3: Attention

- Read `attention/1`, and render `detail` for `computer_use`, `config_approval` and
  `privacy_review` (§4).
- Write answers to the iPhone's own namespace (§4.1), with `approve_rest` and `redact`.

Acceptance:

- With two iPhones, both answer different items, and the Mac's Insights shows each iPhone's
  name.
- A privacy review that unticks one detection sends that one as written and the other redacted.
- An item answered on the Mac first moves to `recent` on the iPhone, and the iPhone's late
  answer does nothing.
- `mobile-attention.json` decodes.
- Mac side: `SyncMobileProtocolTests`, `SyncMobileV2Tests` (detail, budget, `approve_rest`,
  `redact`), `PhoneLegacyCrossSurfaceTests`.

### Phase 4: Manage

- Read the manage state: `workspaceAgents` and the history filters (§5).
- Write requests to the iPhone's own namespace with the new ops, and read its results (§5.1).
- Read the models message (§5.2) and the agent detail messages (§5.3).

Acceptance:

- Hearting a model on the iPhone shows on the Mac's picker.
- Changing a model option on the iPhone changes the Mac's composer for that model.
- `setTool` with `policy: ask` makes the next run ask.
- `warm` before a call turns the Mac's model indicator to loaded.
- An unknown op gets `unsupported_op`.
- `mobile-manage.json` decodes.
- Mac side: `SyncMobileV2Tests` (manage ops, detail payloads, workspace agents),
  `SyncMobileProtocolTests`, `SyncAppDataFixtureTests.mobileManageFixtureReadsTheNewOpsResultsAndDetailMessages`.

### Phase 5: Images and workspace agents

- Image hosted runs with `hostRun.image`, step progress, the `image` approval card, and outputs
  from blobs (§3.4).
- Workspace-agent chats (§3.5).

Acceptance:

- A local image run shows its steps and the image.
- A cloud image run shows the price card first, and denying it bills nothing.
- Backgrounding during a run and coming back shows the finished image.
- A chat with a teammate's shared agent answers through the Mac. After the teammate unshares
  it, the next turn is declined.
- `mobile-workspace.json` decodes.
- Mac side: `SyncMobileV2Tests` (image settings, workspace targets),
  `SyncAppDataFixtureTests.mobileWorkspaceFixtureRunsTowardTheSharedAgent`.

### Phase 6: Drop the HTTP client

- After one release, remove the 6-digit pairing and the HTTP client. The Mac retires its side
  when the iPhone joins over Sync (contract §8).

## 4. Upstream notes (osaurus-sync)

To file against osaurus-sync:

- **`docs/app-data.md`.** Add the v2 records under "Hosted runs":
  - the new `hostRun` fields;
  - `ai.osaurus.run-progress/1`, `ai.osaurus.turn-detail/1` and `ai.osaurus.context-usage/1`;
  - the directory's `features`, `build` and `presence`.

  Then add the device feeds: `attention/1` and the per-device `attention-answer/1/<device>`,
  `manage-state/1`, the per-device `manage-request/1/<device>` and `manage-result/1/<device>`,
  and `manage-models/1` and `agent-detail/1`. Copy `mobile-*.json` into
  `tests/fixtures/app-data`.
- **Typed stream channel.** `StreamUpdate {text, state}` carries text only. Live reasoning, and
  image preview frames, need a second channel on the same stream, for example
  `StreamUpdate {channel: text|reasoning|preview, …}`, that isn't written as durable events.
  Until then both rows stay PARTIAL.

## 5. HTTP route inventory and compatibility

The phone routes are kept for one release and compared with upstream `main` `eb0e968c3`
(`Tests/Networking/PhoneLegacyRouteParityTests.swift`).

- **Fixtures:** `Tests/Networking/PhoneLegacyFixtures/upstream-routes.json` and
  `upstream-sse.json`. They were recorded from an upstream `main` build with
  `OSAURUS_PHONE_PARITY_RECORD`.
- **How the probes run:** on a loopback owner, which is the same handler the Secure Channel
  reaches.
- **What a probe compares:** status, whether the body is JSON, and the error code. Upstream's
  top-level keys and first-element keys must be a subset of this branch's.
- **Self-check:** `theComparisonCatchesADifference` proves a doctored response is caught.

The 47 probes, with upstream `main`'s status:

| Probe | Route | Upstream |
| --- | --- | --- |
| `health` | `GET /health` | 200 |
| `agents.list` | `GET /agents` | 200 |
| `agents.create.badBody` | `POST /agents` | 400 |
| `agents.get.unknown` | `GET /agents/{agent}` | 404 |
| `agents.patch.unknown` | `PATCH /agents/{agent}` | 403 |
| `agents.delete.unknown` | `DELETE /agents/{agent}` | 403 |
| `agents.avatar.unknown` | `GET /agents/{agent}/avatar` | 404 |
| `agents.model.unknown` | `PUT /agents/{agent}/model` | 404 |
| `agents.tools.unknown` | `GET /agents/{agent}/tools` | 200 |
| `agents.tool.patch.unknown` | `PATCH /agents/{agent}/tools/web_fetch` | 404 |
| `agents.tools.preset.unknown` | `POST /agents/{agent}/tools/preset` | 400 |
| `agents.warm.unknown` | `POST /agents/{agent}/warm` | 404 |
| `agents.run.badBody` | `POST /agents/{agent}/run` | 400 |
| `models.picker` | `GET /models/picker` | 200 |
| `models.favorites.badBody` | `PUT /models/favorites` | 400 |
| `models.options.badBody` | `POST /models/options` | 400 |
| `sessions.list` | `GET /sessions` | 200 |
| `sessions.get.unknown` | `GET /sessions/{session}` | 404 |
| `sessions.patch.unknown` | `PATCH /sessions/{session}` | 404 |
| `sessions.delete.unknown` | `DELETE /sessions/{session}` | 404 |
| `sessions.truncate.unknown` | `POST /sessions/{session}/truncate` | 404 |
| `sessions.context.unknown` | `GET /sessions/{session}/context?agent_id={agent}` | 200 |
| `sessions.image.unknown` | `GET /sessions/{session}/turns/{turn}/images/0` | 404 |
| `runs.events.unknown` | `GET /runs/{id}/events?after=0` | 404 |
| `runs.stop.unknown` | `POST /runs/{id}/stop` | 404 |
| `projects` | `GET /projects` | 200 |
| `privacy.reviews` | `GET /privacy/reviews` | 200 |
| `privacy.answer.unknown` | `POST /privacy/reviews/{id}` | 404 |
| `config.approvals` | `GET /config/approvals` | 200 |
| `config.answer.unknown` | `POST /config/approvals/{id}` | 404 |
| `computerUse.prompts` | `GET /computer-use/prompts` | 200 |
| `computerUse.answer.unknown` | `POST /computer-use/prompts/{id}` | 404 |
| `computerUse.answer.notUUID` | `POST /computer-use/prompts/nope` | 400 |
| `secrets.prompts` | `GET /secrets/prompts` | 200 |
| `secrets.answer.unknown` | `POST /secrets/prompts/{id}` | 404 |
| `approvals` | `GET /approvals` | 200 |
| `approvals.answer.unknown` | `POST /approvals/{id}` | 404 |
| `approvals.answer.typo` | `POST /approvals/{id}` | 400 |
| `workspaces.agents` | `GET /workspaces/agents` | 200 |
| `workspaceAgent.run.badBody` | `POST /workspace-agents/w/0xabc/run` | 400 |
| `images.events.unknown` | `GET /images/jobs/nope/events?after=0` | 404 |
| `images.cancel.badBody` | `POST /images/cancel` | 400 |
| `artifacts.unknown` | `GET /artifacts/nope/nope.txt` | 404 |
| `pair.hello` | `GET /pair/hello` (iOSaurus `SubnetProbe`) | 200 |
| `pair.code.empty` | `POST /pair/code` | 400 |
| `pair.confirm.empty` | `POST /pair/confirm` | 400 |
| `pair.unpair.owner` | `POST /pair/unpair` | 403 |

Also covered:

- **SSE extension events** (`upstream-sse.json`):
  - `osaurus_agent_tool` (`agentTool.started.plain`, `agentTool.completed.detail`);
  - `osaurus_prefill`;
  - `osaurus_artifacts`.
- **Secure Channel:** `/secure/session` and `/secure/call` are covered by
  `SecureChannelE2ETests`. Its reads include `/secrets/prompts`, `/approvals` and
  `/config/approvals`.
- **Not probed:** `POST /images/generations` and `/images/edits`. A probe would start a real
  job; their request and response shapes are unchanged from upstream.

Notes for the iOS team:

- **No `/attention*` routes upstream.** Upstream `main` has none, and 1.0(11) doesn't call any.
  The attention feed exists only over Sync.
- **Pairing routes.** Upstream's agent pairing (`/pair`, `/pair/challenge`, the Bonjour
  advertiser) stays retired here. iOSaurus uses only `/pair/hello`, `/pair/code`,
  `/pair/confirm` and `/pair/unpair`, which are all kept.
- **Macs that already ran the v1 migration.** A Mac on an earlier `workflows` build ran the
  launch-time migration and revoked the phone's key. On such a Mac the phone has to pair again
  with a new code. The migration now waits for an iPhone to join over Sync (key
  `mobileConnectRetiredToSync.v2`), and the earlier v1 key is ignored.
- **`omitted_reason: "too_many"`.** It can appear on `osaurus_artifacts` rows from this build.
  iOSaurus decodes `omitted_reason` as `String?`, so it is safe.
- **Changed message.** The `POST /pair/unpair` message is now "Only the iPhone that paired can
  unpair itself." The error code, `not_paired_device`, is unchanged.
- **Answers settle everywhere.** An approval, Computer Use step, privacy review or secret
  answered over HTTP settles the Sync attention item and the Mac's card, and the reverse.
  `PhoneLegacyCrossSurfaceTests` covers this.
- **Retirement.** Once an `ios` device joins over Sync, the `/pair/*` routes answer
  `410 update_required`, and the HTTP phone's key is revoked (contract §8).

## 6. Status

Status of each row, per the release-proof rules:

| Row | Status |
| --- | --- |
| Mac-side Sync records and ops (this branch) | Unit-tested. Full suite (`make ci-test`): 14,228 of 14,229 run passed, 64 skipped; the one failure, `MessageTableHeightNoteCascadeTests` (5 height notes, bound 4), predates this branch and passes alone 3 of 3 |
| Fixtures against the Mac's encoders | Proven (`SyncAppDataFixtureTests`) |
| Release app against an iOS-platform OsaurusSync peer over loopback | Proven for: pairing, directory `features`/`build`/`presence`, manage state and `getModelOptions`, hosted runs with the Default agent and a user agent, `hostRun` model and thinking off, `run-progress/1` (waiting, prefill, tool, done), `turn-detail/1` tool display, `context-usage/1`, an `osaurus_config` approval answered `allowOnce`, three follow-up turns with cached input, uppercase and lowercase ids. Qwen3-4B-4bit, 63.7–76.6 tok/s. Anywhere prompt shown in Settings once; Turn On Anywhere, away and back, relaunch, and back to Same Network all hold |
| Found by that proof and fixed | A chat tagged with an uppercase session id got no reply; a Default-agent chat was declined as "busy" |
| Voice-call note, privacy `off` | PARTIAL: accepted and run (one-sentence answer); the composed prompt wasn't inspected live |
| Attention answers, stop, images, workspace agents | PARTIAL: unit and loopback tests only; not run against the Release app (no image model or workspace in the proof root) |
| Find Devices over mDNS or relays | BLOCKED: the proof didn't grant the proof app macOS Local Network access, so the peer used a direct loopback address |
| Kept HTTP routes against upstream `main` | Proven at the handler level (`PhoneLegacyRouteParityTests`, 47 probes plus 4 SSE events) |
| Live 1.0(11) phone over HTTP against a Release build | BLOCKED: needs the physical phone |
| Downgrade (upstream `main` build serving the same paired phone) | BLOCKED: needs the physical phone |
| Live iPhone over Sync | BLOCKED: no iOS Sync build yet |
| Live thinking, image preview frames | PARTIAL: wait on the osaurus-sync stream channel |
| Push | Not started: no transport, no Sync record |
