# Sync Mobile Contract (v2)

How the Osaurus iPhone app (iOSaurus) works with the user's Macs. The iPhone is an ordinary
osaurus-sync device in the user's account. Everything it does with a Mac goes through synced
conversations and their app data: no HTTP route, relay tunnel or Secure Channel is involved.

Nothing in the records is specific to iOS. "The iPhone" below means any companion client: a
device whose `Device.platform` isn't macOS. A Mac publishes its attention, manage and detail
feeds while any such device is in the account. It reads `windows` (or `win`) as a Windows PC
and anything else unknown as a generic device; both get the same feeds as an iPhone. Only the
Mac's keep-awake and reachability prompts are iPhone-specific. A Windows client SHOULD report
`Device.platform` as `windows`, read the same fixtures, and use the same feature flags.

Every client MUST open with the Osaurus relays and discovery server: relays
`https://relay-us.sync.osaurus.ai`, `https://relay-eu.sync.osaurus.ai` and
`https://relay-ap.sync.osaurus.ai`, discovery server `https://dns.sync.osaurus.ai/pkarr`, origin
`dns.sync.osaurus.ai`, and `publish` left at `relayOnly`. A client on another discovery server
can't find the Mac over the internet. Clients SHOULD read `https://osaurus.ai/sync/network.json`
(the same shape as `SyncNetworkDirectory`) and apply a new list at the next open.

Read [`SYNC.md`](SYNC.md) first: it covers the store, hosted runs and served chats this contract
builds on. The record types are in `Packages/OsaurusCore/Services/Sync/`:
`SyncHostedRunContract.swift`, `SyncDeviceFeedContract.swift`, `SyncRunProgress.swift`,
`SyncContextUsage.swift`, `SyncManageDetail.swift` and `Models/Chat/HostRunRequest.swift`. Test
vectors for every v2 record are in `Packages/OsaurusCore/Tests/Sync/SyncFixtures/mobile-*.json`.
`SyncAppDataFixtureTests` reads them against the Mac's own encoders. The iPhone SHOULD test
against the same bytes. Normative words: **MUST**, **SHOULD**, **MAY**.

The old 6-digit pairing over HTTP ([`MOBILE_PROTOCOL.md`](MOBILE_PROTOCOL.md)) still works for one
release, beside this contract (§8). The iOS work plan is
[`SYNC_MOBILE_IOS_HANDOFF.md`](SYNC_MOBILE_IOS_HANDOFF.md).

## 0. Versions and feature flags

v1 was the first Sync contract: the directory, hosted runs with `hostRun {device, requestedMs}`,
approvals, secrets, the attention feed and the five agent ops. v2 adds the rest of what the
iPhone did over HTTP. A Mac's build says what it supports in its directory's `features` (§2):

| Flag | What it adds |
| --- | --- |
| `per_device_answers` | `attention-answer/1/<device>`, `manage-request/1/<device>`, `manage-result/1/<device>` (§4, §5) |
| `presence` | `presence` in the directory (§2) |
| `host_run_options` | `hostRun.model`, `options`, `voiceCall`, `privacy` (§3.1) |
| `run_progress` | `ai.osaurus.run-progress/1` (§3.2) |
| `artifact_blobs` | `ai.osaurus.turn-detail/1`: tool labels, generated images and shared files as blobs (§3.3) |
| `image_runs` | `hostRun.image` and image models in hosted runs (§3.4) |
| `workspace_agents` | `workspaceAgents` in the manage state, hosted workspace-agent chats (§3.5) |
| `context_usage` | `ai.osaurus.context-usage/1` and the `contextUsage` op (§3.6) |
| `attention_detail` | `detail` on `computer_use` and `config_approval` items, the `approve_rest` answer (§4) |
| `privacy_review` | the `privacy_review` attention kind and the `redact` answer (§4) |
| `manage_models` | the models message, `setFavorite`, `getModelOptions`, `setModelOption` (§5.2) |
| `agent_detail` | one detail message per agent: system prompt, avatar, tools (§5.3) |
| `set_tool` | the `setTool` op (§5.1) |
| `warm` | the `warm` op (§5.1) |
| `history_filters` | `projects`, `plugins` and `workspaces` in the manage state (§5) |
| `continue_own_chats` | Answering `hostRun` turns in the Mac's own chats, which carry no `hostDevice` (§3.10) |

- The iPhone MUST check a flag before it writes a record or op that the flag covers, and MUST
  NOT expect a v2 record from a Mac whose directory doesn't list its flag. A directory without
  `features` is a v1 Mac.
- A Mac ignores fields and records it doesn't know. An op it doesn't know gets
  `unsupported_op` (§5.1).
- `build` is the Mac's version, as `0.25.31 (1234)`, for the iPhone's "Update Osaurus on your
  Mac" wording. The iPhone MUST NOT gate on it: flags are the contract.
- Over a live connection a write reaches the Mac at once: over loopback a manage request was
  answered in 0.25 s. With no connection up, a write waits for the next dial, up to the
  30-second retry interval; over loopback the first write from a just-opened core took 30 s.
  The iPhone SHOULD call `syncNow()` ("dial known devices now") when it comes to the foreground
  and before a write the user waits on: a message with `hostRun`, a stop, an approval or
  attention answer, a manage request, a secret. Whether `syncNow()` shortens that first dial
  over mDNS or relays is unproven; to a manually added peer address it didn't.
- Ids (sessions, turns, agents, approvals) are UUID strings. The Mac writes them lowercase, and
  the iPhone SHOULD too: Swift's `uuidString` is uppercase, so lowercase it. Compare ids as
  UUIDs or case-insensitively, never as raw strings. A Mac from before this note finds a chat
  only by its lowercase `osaurus.session` tag and ignores an uppercase one without a reply.

## 1. Joining the account

- On a Mac, the user opens **Sharing → Devices → Add a Device**. The Mac shows a pairing offer
  (`SyncCore.pairingOffer(ttlMs:)`) as a QR code and an `osaurus-pair:` link.
- The iPhone scans or pastes it and calls `SyncCore.pairWithOffer(payload:)`. When pairing
  finishes, the iPhone is a device of the same user, and the Mac's Devices list shows it as
  **iPhone**.
- Every client MUST use osaurus-sync 0.1.0-beta.6 or later: a current Mac doesn't add a device
  on an older core. Offers are `osaurus-pair:2:`; a client that builds one from a typed code
  MUST use `PairingOffer.payload(device:code:)`.
- After the code checks out, both devices get `CoreEvent.pairingConfirmation(device, name,
  platform, code)`. The client MUST show the six digits next to the Mac's name, ask whether the
  Mac shows the same number, and call `confirmPairing(device:)` only when the user says yes;
  otherwise `rejectPairing(device:)`. It MUST dismiss the prompt on `pairingFailed`. The Mac
  asks the same question, and hands over the account only after both confirmed.
- Conversation app data a client writes is signed by its device. The Mac counts run control,
  tool approval answers and secret prompt answers only when signed by one of the user's current
  devices, and drops a value in a per-device namespace (`…/<device>`) signed by any other
  device, so a client MUST write only its own namespaces.
- The iPhone MUST join only through a pairing offer. It MUST NOT offer to type the recovery
  phrase: on Macs linked to the user's wallet, that phrase is derived from the wallet and
  restores the whole identity.
- The iPhone MUST open its core with `platform: .ios`, which other devices read as `iOS` in
  `Device.platform` (the Mac compares case-insensitively). The Mac uses it to name the
  device, keep itself awake (**Keep Mac Awake for iPhone**), say "Your iPhone" in notices and in
  the Inbox, and create the attention and management conversations (§4, §5).
- **Reachability.** When the first iPhone joins and the Mac finds devices only on the same
  network, the Mac asks once: **Reach this Mac from anywhere?** **Turn On Anywhere** switches
  Sync to **Anywhere (Beta)** (`SyncReachabilityPrompt`). The Mac never asks again, whatever the
  answer.
- Removing the iPhone on the Mac revokes it like any device. Once revoked, it can't read
  anything new, and the Mac's other devices turn away what it writes. A revoked device keeps the
  account secret, so **Remove Device…** defaults to **Remove and Change Phrase**, which replaces
  the account identity (`docs/SYNC.md` → Removing a device).
- When an `ios` device first joins, the Mac retires the old pairing (§8).

## 2. Finding agents

Each Mac with **Run Agents for My Other Devices** on writes its directory: one conversation
tagged `ai.osaurus.kind=agent-directory` and `ai.osaurus.device=<mac device key>`, with app data
`ai.osaurus.directory/1` (fixture `mobile-directory.json`):

```json
{ "v": 1, "device": "<mac key>", "updatedMs": 1767571000000,
  "agents": [
    { "id": "00000000-0000-0000-0000-000000000001", "name": "Osaurus", "isDefault": true },
    { "id": "a1b2…", "address": "0x5a8d…", "name": "Writer", "description": "…", "avatar": "✍️" } ],
  "features": ["per_device_answers", "presence", "…"],
  "build": "0.25.31 (1234)",
  "presence": { "state": "sleeping", "networkMode": "anywhere", "updatedMs": 1767574600000 } }
```

- `isDefault: true` marks the Mac's **Default agent**. Every Mac has its own, so other Macs skip
  it. The iPhone has no agents of its own and SHOULD offer it, labelled with the Mac's name
  ("Osaurus on Studio").
- The iPhone MUST skip directories from revoked devices, and MUST ignore any directory whose
  `device` doesn't match its tag.
- A Mac with the setting off writes an empty list.
- `presence.state` is `awake` (written with the directory at launch and wake), `sleeping` (as the
  Mac goes to sleep) or `quitting` (as Osaurus quits). The writes are best effort, so a crash or
  power loss leaves the last one. `networkMode` is the Mac's **Find Devices** setting:
  `localNetworkOnly` (Same Network) or `anywhere`.
- How the iPhone words a Mac (SHOULD):
  - connected (`SyncCore` peer state): ready;
  - not connected, last presence `sleeping`: "Studio is asleep";
  - not connected, last presence `quitting`: "Osaurus isn't running on Studio";
  - not connected, `networkMode` `localNetworkOnly`: "Studio is reachable on the same network
    only", with a hint to turn on **Anywhere (Beta)** on the Mac;
  - otherwise: "Studio is out of reach".

## 3. Chatting: hosted runs

A chat with a Mac's agent is a hosted run, exactly as between two Macs (SYNC.md, "Hosted
runs"; fixtures `hosted.json`, `mobile-hosted.json`):

1. The iPhone creates a synced conversation whose `ai.osaurus.session/1` carries
   `hostDevice=<mac key>` and the agent id, and tags it `hostDevice`.
2. Each user message carries `hostRun` in its turn app data. The Mac runs the latest unanswered
   one once and streams the reply as the agent.
3. The Mac writes `ai.osaurus.host-run/1 {turn, state: running|done, updatedMs}`.
4. **Stop:** the iPhone writes `ai.osaurus.run/1 {stop: <turn id>, stopMs}`. If `host-run`
   isn't `done` within 15 seconds, the iPhone SHOULD unlock its composer anyway and say the stop
   isn't confirmed.
5. **Declines** come back as an assistant turn with `terminalStopReason` `host_declined`, or
   `interrupted` (Osaurus quit during the run). The iPhone shows the text as is. The Mac
   declines when:
   - the setting is off;
   - the agent is gone, or a workspace agent is no longer shared (§3.5);
   - the chat is busy;
   - the requested model isn't on the Mac;
   - an option is one the model doesn't take (§3.1).

A request first seen more than an hour after it was made gets a `host_declined` reply instead of a
run. Its time is the later of `requestedMs` and the message's HLC, so a phone clock running
behind doesn't make a fresh request look late. The iPhone SHOULD only
send while the Mac is connected (`SyncCore` peer state), and otherwise word it as in §2.

While a run is going, the Mac's own window for that chat shows **Answering for your iPhone…**,
and Inbox → Live Now lists it. After backgrounding, the iPhone calls `syncNow` and subscribes
again. The run goes on on the Mac, and committed turns, `host-run/1` and `approval/1` are
durable, so nothing else is needed to rejoin.

### 3.1 Run options (`host_run_options`)

```json
"hostRun": { "device": "<mac key>", "requestedMs": 1767571200000,
  "model": "OsaurusAI/gemma-4-qat-mxfp4",
  "options": { "reasoningEffort": "low", "thinking": false },
  "voiceCall": { "instructions": "Answer in two short spoken sentences." },
  "privacy": "auto" }
```

- `model`: the model to run this turn on, as the Mac's picker names it (`id` in the models
  message, §5.2). Missing or empty runs the agent's model. A model the Mac doesn't have is
  declined: "<model> isn't on this Mac. Pick another model to continue."
- `options.reasoningEffort` is one of the model's effort segments (`getModelOptions`).
  `options.thinking` turns reasoning on or off. A value the model doesn't take is declined with
  the reason.
- `voiceCall` marks a turn of a voice call. `instructions` is the call's note for spoken replies
  (`ChatViewModel.callInstructions`), at most 8,000 characters, applied to this run only and
  never saved into the chat. The Mac adds no note of its own.
- `privacy`: `auto` redacts every Privacy Filter detection without a review, `off` sends the
  message as written. Missing follows the Mac's settings, which may raise a `privacy_review`
  (§4).
- The Mac honours these fields only when the turn's author is the Mac itself or another of the
  user's devices that isn't revoked. Otherwise the turn runs the agent as set up on the Mac.
- A Mac without the flag ignores them, so the iPhone MUST NOT send them to such a Mac. It
  SHOULD say the choice isn't available until the Mac updates.

### 3.2 Live progress (`run_progress`)

The device running a synced turn writes `ai.osaurus.run-progress/1` on the conversation:

```json
{ "v": 1, "turn": "<user turn id>", "phase": "tool",
  "prefill": { "stage": "prefill", "done": 2048, "total": 2048 },
  "tools": [ { "id": "call_7", "name": "web_fetch", "label": "Fetched osaurus.ai", "icon": "globe",
               "state": "done", "durationMs": 840 },
             { "id": "preparing", "name": "file_write", "label": "Writing a file", "icon": "doc",
               "state": "preparing", "argumentBytes": 312 } ],
  "image": { "step": 3, "total": 4 },
  "artifacts": [ { "id": "…", "filename": "outline.md", "mimeType": "text/markdown", "fileSize": 1180 } ],
  "thinkingChars": 1420, "startedMs": 1767571260000, "updatedMs": 1767571262500 }
```

- `phase`: `waiting` (queued or loading the model), `prefill`, `thinking`, `answering`, `tool`,
  `image` or `done`.
- `prefill.stage`: `queued`, `cacheLookup`, `cacheRestore` or `prefill`.
- `tools[].state`: `preparing` (the call is still being written; `id` is `preparing`),
  `running`, `done` or `failed`. `label` is the Mac chat's text for the call, in its current
  tense, and `icon` is an SF Symbol name.
- Every app data write is a durable event, so this record is coarse:
  - a new shape (phase, tool, step, file) is written at most every 500 ms;
  - a change only to counters (`thinkingChars`, prefill `done`, `argumentBytes`) is written at
    most every 2 seconds;
  - when the run starts with every connected device reached only through a relay, both intervals
    are four times longer (2 s and 8 s). Clients MUST NOT read a slow update as a stalled run.
- At the end the Mac writes `phase: done` with `prefill` and `image` removed and the finished tool
  list kept. The committed messages are then the source of truth.
- The reply's text streams through the core's stream as before. Its reasoning text does not
  stream: it arrives with the committed turn (§7).

### 3.3 What a committed turn holds (`artifact_blobs`)

The reply is one message per turn. Its `ai.osaurus.turn/1` carries `thinking`, `toolCalls`,
`toolResults`, `toolCallDurations` and `sharedArtifacts` metadata, and each tool result is also
its own `tool_result` message.

- Values over 16 KiB move to blobs (`{"$blob": i, "size": n}`). If the turn is still over
  64 KiB, the largest remaining values move until it fits. A field is dropped only when that
  isn't enough, in this order: `injectedContextPrefix`, `responsesOutputItems`,
  `reasoningEncrypted`, `thinking`. Then `truncated: true` is set.
- Assistant and tool messages written by the device that ran them also carry
  `ai.osaurus.turn-detail/1`:

```json
{ "v": 1,
  "toolCallDisplay": { "call_7": { "label": "Fetched osaurus.ai", "category": "web", "icon": "globe" } },
  "files": [
    { "kind": "generatedImage", "link": "file:///…/generated-images/hero.png", "filename": "hero.png",
      "mimeType": "image/png", "fileSize": 48213, "blob": 0 },
    { "kind": "artifact", "id": "…", "filename": "launch.mov", "mimeType": "video/quicktime",
      "fileSize": 52428800, "skipped": "tooLarge" } ] }
```

- `toolCallDisplay` gives each call's label, category and icon, plus `failed: true` when it
  failed, so the iPhone needs none of the Mac's tables.
- `files` are the generated images, shared artifacts and images in tool results that the turn
  made on the Mac:
  - `blob` is the index into the namespace's blobs;
  - a file over 10 MiB, or past 32 MiB for the turn, is listed with `skipped: "tooLarge"` and
    no bytes.
- The iPhone SHOULD replace a `generatedImage`'s `link` in the reply's markdown with the blob.
  The `file://` path is only meaningful on the Mac.
- Only the device that ran the turn writes turn detail. Other devices never rewrite it.

### 3.4 Images (`image_runs`)

An image request is a hosted run whose `hostRun.model` is an image model (`kind: "image"` in
the models message) and whose `hostRun.image` holds the composer's settings:

```json
"image": { "width": 1024, "height": 1024, "steps": 4, "guidance": 3.5, "seed": 7, "strength": 0.6,
           "negativePrompt": "text, watermark", "aspectRatio": "16:9", "resolution": "1K",
           "quality": "high", "count": 1 }
```

- Every field is optional. Each one set replaces the model's default, and the Mac clamps it the
  way its composer does. Which fields apply depends on the model: the models message carries
  each image model's `image` (local) or `cloud` controls.
- An edit attaches the source image to the user turn. Models with `edits: true` take one.
- **Progress:** `phase: image` with `image {step, total}` (§3.2). Preview frames aren't sent
  (§7).
- **Output:** the images arrive as `generatedImage` files on the reply (§3.3).
- **Stop:** `ai.osaurus.run/1 {stop}`, as for chat.
- **Cloud spend:** a cloud image model asks first through the run's `approval/1` card, with
  `tool: "image"` (§3.7). Its `arguments` JSON carries:
  - `prompt`, `resolved_model`, `backend`
  - `billing_notice`, `estimated_minimum_usd`, `privacy`
  - `aspect_ratio`, `resolution`, `quality`

  This card replaces HTTP's `allow_remote_media_spend`. The iPhone MUST show the price and
  notice with the buttons. Denying replies "Remote image generation cancelled before billing."

### 3.5 Workspace agents (`workspace_agents`)

The iPhone has no wallet identity, so it can't join workspaces. The Mac runs a teammate's
shared agent for it instead. The manage state lists those agents in `workspaceAgents` (§5). A
chat with one is a hosted run whose `session/1` has no `agentId` and carries:

```json
"workspace": { "workspaceId": "ws_3f2a", "agentAddress": "0xabab…" }
```

The Mac sends the run to that agent with the user's identity. Fixture `mobile-workspace.json`.

- The teammate's Mac picks the model, so `hostRun.model` and `hostRun.image` are ignored.
  `voiceCall` and `privacy` still apply. `options` is declined: "Per-turn controls are not
  supported for shared workspace agents. The remote agent owns its generation settings."
- If the agent is no longer shared into one of the user's workspaces, the turn is declined:
  "This agent is no longer shared with you in that workspace. Pick another agent to continue."
- `callerWallet` MUST NOT be set. That field marks the chats this Mac served for a teammate,
  which aren't run toward anyone.

### 3.6 Context usage (`context_usage`)

After each hosted run, the Mac writes `ai.osaurus.context-usage/1` on the conversation:

```json
{ "v": 1, "agentId": "a1b2…", "model": "OsaurusAI/gemma-4-qat-mxfp4", "updatedMs": 1767571250000,
  "usage": { "tokens": 5310, "usable_tokens": 104857, "max_tokens": 131072, "ratio": 0.0506,
             "near_limit": false, "hard_overflow": false, "window_source": "model",
             "context":  [ { "id": "system", "label": "System prompt", "tokens": 1210, "tint": "purple" } ],
             "messages": [ { "id": "conversation", "label": "Conversation", "tokens": 1210, "tint": "green" } ] } }
```

- `usage` has the same fields as HTTP's `GET /sessions/{id}/context`:
  - `near_limit` is at or past 85% of `usable_tokens`;
  - `auto_disabled` says when the window is too small for tools or memory.
- To price it for another agent or model before sending (after a model change, say), the iPhone
  sends the `contextUsage` op (§5.1). The Mac rewrites this record and answers with it.

### 3.7 Tool approvals

The Mac publishes the tool calls the run is waiting on in `ai.osaurus.approval/1`:

```json
{ "v": 1, "pending": [
  { "id": "…", "turnId": "…", "tool": "sandbox_exec", "description": "…",
    "arguments": "{\"cmd\":\"ls\"}", "surface": "sandbox", "offersRunLease": true,
    "requestedMs": 1761400000000 } ] }
```

The iPhone answers in `ai.osaurus.approval-answer/1`:

```json
{ "v": 1, "answers": { "<approval id>": "allowOnce" } }
```

- The answers are `denied`, `allowOnce`, `allowForRun` (only when `offersRunLease`) and
  `alwaysAllow`. Show them as **Deny**, **Allow**, **Allow for This Conversation** and **Always
  Allow**.
- The iPhone MUST keep answers only for ids still pending, and MUST NOT turn an unknown value
  into an allow.
- The Mac denies whatever is still waiting when the run ends.
- `surface` is missing when the call doesn't run on a named surface.

### 3.8 Secrets

When the agent asks for a secret (`sandbox_secret_set` without a value), the Mac publishes it in
`ai.osaurus.prompt/1`:

```json
{ "v": 1, "pending": [
  { "id": "…", "turnId": "…", "kind": "secret", "key": "OPENAI_API_KEY",
    "description": "…", "instructions": "…",
    "sealKey": "<base64url X25519 public key>", "requestedMs": 1761400000000 } ] }
```

- `sealKey` is a one-use key. Its private half exists only in the Mac's memory, for this prompt.
- The iPhone seals the value with HPKE (X25519, HKDF-SHA256, ChaCha20-Poly1305: base mode, the
  `PairingKeyEnvelope` suite) to `sealKey`, with info `osaurus-sync-secret-v1:<prompt id>`
  (id lowercased). It writes `ai.osaurus.prompt-answer/1`:

```json
{ "v": 1, "answers": { "<prompt id>": { "sealed": { "enc": "<base64url>", "ct": "<base64url>" } } } }
```

- To decline: `{ "cancel": true }`.
- The value MUST NOT be written in any other form, logged or kept on the iPhone. The Mac
  stores it in its Keychain for that agent and records only that it was sent.
- An answer that doesn't open with the prompt's key is ignored. The prompt stays until it times
  out (5 minutes) or the run ends.
- The prompt's attention item settles as answered from the iPhone, on every surface.

A Mac chatting with another Mac's agent answers the same way (`HostedSecretCard`).

### 3.9 Editing and resending

To edit a sent message, the iPhone:

1. deletes that message and every later one (`SyncCore.deleteMessage`);
2. sends the edited text as a new user turn with a new id and a new `hostRun`.

The host answers the new turn once (`SyncHostedRunTests.anEditedAndResentTurnIsAnsweredOnce`).
This replaces `POST /sessions/{id}/truncate`.

### 3.10 Continuing a Mac's own chats (`continue_own_chats`)

A chat started on a Mac syncs to the iPhone like any other, but carries no `hostDevice`: the Mac
runs it itself. Over HTTP the iPhone could continue any of the Mac's chats, so a Mac with this
flag also answers its own chats:

- The iPhone sends a user turn with `hostRun`, as in §3, whose `device` is the Mac that ran the
  chat. That is the `authorDevice` of its assistant messages. The iPhone doesn't tag the
  conversation or write `session/1`: a Mac rewrites both from its own session on every save.
- The Mac answers when all of these hold:
  - the conversation has no `hostDevice` tag and no `ai.osaurus.kind`, and its `source` is `chat`;
  - the latest user message was written on another device of the user that isn't revoked;
  - its turn's `hostRun.device` is this Mac.
- Everything else in §3 applies as for a hosted chat: one run per turn, `host-run/1`,
  `run-progress/1`, stop, approvals, secrets, declines and the hour-old cutoff. A chat with the
  Default agent may have no `agentId`; it runs the Default agent.
- The chat stays the Mac's own. It keeps no `hostDevice`, and the Mac's window for it shows
  **Answering for your iPhone…** while the run goes.
- A Mac without the flag ignores the turn. The iPhone MUST check the flag on the chat's Mac
  before sending to one of its own chats.
- On launch the Mac reads only chats active within the hour-old cutoff, since older requests
  aren't started. While running, it reads only the latest message of a changed chat.

Tests: `SyncOwnChatTests`.

## 4. Attention feed

While an iPhone is in the account, each Mac keeps one conversation tagged
`ai.osaurus.kind=attention` and `ai.osaurus.device=<mac key>`. The Mac writes
`ai.osaurus.attention/1` whenever something needs the user or is settled (fixture
`mobile-attention.json`):

```json
{ "v": 1,
  "items": [ { "id": "…", "kind": "owner_approval", "title": "…", "body": "…",
               "actions": ["approve", "allow_for_conversation", "deny", "open"],
               "priority": 1, "blocking": true, "created_at": "2026-10-26T17:00:00Z",
               "session_id": "…", "agent_id": "…", "tool": "web_fetch",
               "requester": { "kind": "teammate", "label": "@alice · 0x9c3e…11aa" },
               "state": "pending" } ],
  "recent": [ { "…": "…", "state": "resolved", "outcome": "approved", "surface": "phone",
                "decided_by": { "kind": "owner_device", "label": "You · Sam's iPhone" },
                "insights_id": "…", "settled_at": "…" } ] }
```

- `items` are the pending items the user routed to the iPhone under **General → Notifications**,
  oldest first. `recent` holds up to 20 settled items, newest first.
- Kinds:
  - `tool_approval`, `owner_approval`, `clarification`, `workflow_dialog`;
  - `config_approval`, `computer_use`, `secret_request`, `elicitation`, `privacy_review`;
  - `inbound_message`, `inbound_shared_run`, `agent_notice`.

  An unknown kind SHOULD be shown with its title, body and `open`.
- Labels in `requester`, `agent` and `decided_by` are already formatted. Show them as they are.
- A pending `tool_approval` carries `arguments_preview`: the call's JSON arguments, cut to 512
  characters. Show it with the Allow buttons, so the user sees what they allow. It may not be
  valid JSON once cut.
- **Detail** (`attention_detail`, `privacy_review`). A pending item MAY carry `detail`:
  - `computer_use`: `{action, effect: read|navigate|edit|consequential, app?, target?, note?,
    typedText?, script?}`.
  - `config_approval`: `ConfigPlan.payload`, which is `{change_count, actions: [{section, target,
    kind: create|update|delete|needsUserInput, changes?, risks?, long_running?}], notes?,
    high_risk?}`, plus `prune`.
  - `privacy_review`: `{items: [{id, category, original, placeholder}]}`, the detections the
    Privacy Filter found in a hosted run's message, before it goes to the provider.

  Detail size limits:
  - one item's `detail` is at most 8 KiB, and the feed's is at most 32 KiB, oldest item first;
  - a cut list keeps `truncated: true` and `total`;
  - a cut text says `truncated: true`;
  - an item past the feed budget carries only `{"truncated": true}`, and the iPhone opens the
    chat for the rest.

  Settled items carry neither `detail` nor `arguments_preview`.

### 4.1 Answers

Each iPhone answers in its own namespace, `ai.osaurus.attention-answer/1/<its device key>`
(`per_device_answers`):

```json
{ "v": 1, "answers": {
  "<item id>": { "action": "approve", "redact": ["<detection id>"], "answeredMs": 1767572530000 } } }
```

- `action` MUST be one the item lists:
  - `approve`, `deny` or `allow_for_conversation`;
  - `approve_rest` (Computer Use: approve this step and the rest of the task in that app);
  - `reply`, with non-empty `text`, at most 16,384 characters;
  - `dismiss`.

  `open` is local: open the chat (`session_id`) or the Mac.
- `redact` is only for `privacy_review` with `approve`. It lists the detections to replace with
  their placeholders; the rest go as written, as when the user unticks a row in the Mac's sheet.
  If `redact` is missing, every detection is redacted. So are detections the item couldn't list
  because the detail was cut.
- The Mac applies each answer once, if the item is still pending and offers that action:
  - it records the answer on the `phone` surface, from that iPhone's name;
  - it ignores answers older than 24 hours, and answers from devices that aren't in the
    account.
- The first answer anywhere wins. If the item was answered on the Mac, or by another iPhone,
  first, a later answer is ignored, and the iPhone sees the item move to `recent`.
- A `secret_request` item is answered through §3.8, not here, because its value has to be
  sealed.
- An iPhone writes only its own namespace, so answers never overwrite each other. It SHOULD drop
  answers to ids no longer listed.
- **Older Macs.** A Mac without `per_device_answers` reads only the shared namespace,
  `ai.osaurus.attention-answer/1`. There the iPhone MUST read the current answers, add its own
  and write the merge. New Macs still read the shared namespace for one release and label its
  answers with the iPhone's name when the account has one iPhone, or **Your iPhone** when it
  has several.

## 5. Managing agents

While an iPhone is in the account, each Mac keeps one conversation tagged
`ai.osaurus.kind=manage` and `ai.osaurus.device=<mac key>` (fixture `mobile-manage.json`). The Mac
writes `ai.osaurus.manage-state/1` when its agents, models, workspaces or filters change:

```json
{ "v": 1, "device": "<mac key>", "updatedMs": 1767573000000,
  "agents": [
    { "id": "00000000-…-000000000001", "name": "Osaurus", "isDefault": true, "model": "qwen3-8b" },
    { "id": "a1b2…", "name": "Writer", "description": "…", "avatar": "✍️", "model": "gpt-5.1",
      "settings": { "tools_enabled": true, "memory_enabled": true, "web_search_enabled": false,
                    "autonomous_exec_enabled": false, "autonomous_exec_available": true } } ],
  "models": [ { "id": "qwen3-8b", "name": "Qwen3 8B", "provider": "Local" } ],
  "workspaceAgents": [ { "workspaceId": "ws_3f2a", "workspaceName": "Studio", "address": "0xabab…",
                         "name": "Researcher", "ownerName": "Sam" } ],
  "projects": [ { "id": "D4C3…", "name": "Launch" } ],
  "plugins": [ { "id": "osaurus.time", "name": "Time" } ],
  "workspaces": [ { "id": "ws_3f2a", "name": "Studio" } ] }
```

- `models` lists chat models only. The models message (§5.2) has the full picker.
- `settings.temperature` and `max_tokens` are present only when set.
- `workspaceAgents` lists teammates' agents shared into the user's workspaces, not the user's
  own (§3.5).
- `projects`, `plugins` and `workspaces` are the history's filters (`history_filters`), matched
  against a chat's `projectId`, `sourcePluginId` and `workspace.workspaceId`, as HTTP's
  `GET /projects` lists them.

### 5.1 Requests

Each iPhone asks for changes in `ai.osaurus.manage-request/1/<its device key>`. It keeps a list
and appends to it, and each request has a unique `id`:

```json
{ "v": 1, "requests": [
  { "id": "r1", "op": "updateAgent", "agentId": "a1b2…", "name": "Scout",
    "memoryEnabled": false, "clearTemperature": true, "requestedMs": 1767573100000 } ] }
```

| `op` | Fields | Answer (`data`) |
| --- | --- | --- |
| `createAgent` | `name`, `description?`, `systemPrompt?`, `model?` | — (`agentId`) |
| `updateAgent` | any of `name`, `description`, `systemPrompt`, `toolsEnabled`, `memoryEnabled`, `webSearchEnabled`, `autonomousExecEnabled`, `temperature` (0–2) or `clearTemperature`, `maxTokens` (1–1,000,000) or `clearMaxTokens` | — |
| `setModel` | `agentId`, `model` (empty or missing: the default) | — |
| `setToolPreset` | `agentId`, `preset`: `all`, `essential` or `none` | — |
| `deleteAgent` | `agentId` | — |
| `setTool` | `agentId`, `name` (the tool), any of `enabled`, `agentEnabled`, `policy` (`auto`, `ask`, `deny`) | the tool's row (§5.3) |
| `warm` | `agentId`, `model?` (default: the agent's) | `{loaded, already?}` |
| `contextUsage` | `scope` (the chat's conversation), `agentId?`, `model?` | the `usage` of §3.6 |
| `setFavorite` | `key` (a model's `favorite_key`), `favorite` | `{favorites}` |
| `getModelOptions` | `model` | the model's options |
| `setModelOption` | `model`, `option`, `value` (a segment id or a bool) or `clearValue: true` | the model's options |

Op notes:

- `createAgent` starts with tools, memory, web search and the sandbox off. `name` is cut to
  80 characters.
- `updateAgent` works on user agents only. `setModel` also works for the Default agent.
- `setToolPreset` applies the Tools window's presets.
- `deleteAgent` is refused while the agent is shared to a workspace.
- `warm` loads the model ahead of a voice call, as the Mac's call does. `loaded: false` means
  the model is remote or there was nothing to load.
- `contextUsage` also rewrites the chat's `context-usage/1`.
- `getModelOptions` and `setModelOption` answer with the model's options:

  ```json
  { "model": "…", "thinking": { "enabled": true, "explicit": false, "tristate": false },
    "options": [ { "id": "reasoningEffort", "label": "Reasoning", "kind": "segmented",
                   "segments": [ { "id": "low", "label": "Low" } ], "selected": "low",
                   "explicit": true } ] }
  ```

  The same per-model options apply to the Mac's own runs. The option id `thinking` sets the
  Thinking row.

The Mac applies each request once, through the same calls its own editor makes, and writes
`ai.osaurus.manage-result/1/<that device key>`:

```json
{ "v": 1, "results": { "r1": { "ok": true, "agentId": "a1b2…", "doneMs": 1767573100500 } } }
```

- Errors: `agent_not_found`, `agent_not_editable` (the Default agent, except for `setModel`),
  `bad_request`, `sandbox_unavailable`, `agent_shared`, `tools_loading`, `tool_not_found`,
  `chat_not_found`, `unknown_option`, `invalid_value`, `load_failed`, `too_large`,
  `unsupported_op`, `interrupted`, `failed`.
- `message` is readable text. Show it as is.
- `unsupported_op` means the Mac's build doesn't know the op. Check `features` first.
- `interrupted` means the Mac stopped while applying the request. It may or may not have taken
  effect, so the iPhone SHOULD refresh `manage-state` before asking again.
- `data` is at most 16 KiB. A larger answer fails with `too_large`, and the iPhone reads the
  record the op writes, or the detail messages, instead.
- `name` is at most 200 characters, `description` 2,000 and `systemPrompt` 100,000. A longer one
  is refused with `bad_request`.
- Each applied request is recorded in the Mac's Insights (method `SYNC`, path `/manage/<op>`),
  attributed to that iPhone by name, without the values it set.
- Requests older than 24 hours are ignored. The Mac keeps a result for every request still in
  the list, and drops results for requests the iPhone removed. The iPhone MUST remove requests
  from its list once their result is in, and MUST NOT reuse an `id`.
- Each request runs at most once. The Mac records a request id in a local file before applying
  it, so a request never runs twice: not after the results are lost or trimmed, not after a
  relaunch, and not if the Mac quits mid-request.
- **Older Macs.** A Mac without `per_device_answers` reads only `ai.osaurus.manage-request/1`
  and answers in `ai.osaurus.manage-result/1`. New Macs still read those for one release.

### 5.2 The models message (`manage_models`)

Conversation app data can't hold blobs and is capped at 64 KiB, so the picker goes on a message.
The manage conversation has one `system` message with content `models` and app data
`ai.osaurus.manage-models/1`:

```json
{ "v": 1, "favorites": ["local:OsaurusAI/gemma-4-qat-mxfp4"],
  "models": [ { "id": "OsaurusAI/gemma-4-qat-mxfp4", "name": "Gemma 4 QAT", "provider": "Local",
                "source": "local", "vision": true, "thinking": true, "available": true,
                "tab": "local", "tab_title": "Local", "favorite_key": "local:…",
                "context_length": 131072, "kind": "chat", "edits": false } ],
  "digest": "…", "updatedMs": 1767573000100 }
```

- Each row has HTTP's `GET /models/picker` fields (MOBILE_PROTOCOL.md §12): chat models, the
  image models the iPhone can run, and cloud image models with their `image` or `cloud`
  controls and `privacy`.
- A value over 16 KiB (a long model list) is a blob reference, `{"$blob": i, "size": n}`, into
  this namespace's blobs.
- The Mac rewrites the message only when `digest` changes. The iPhone SHOULD keep its copy until
  then.

### 5.3 Agent detail messages (`agent_detail`)

One `system` message per agent the iPhone can manage, with content `agent` and app data
`ai.osaurus.agent-detail/1`:

```json
{ "v": 1, "agentId": "a1b2…", "name": "Writer", "isDefault": false, "toolsEnabled": true,
  "systemPrompt": { "$blob": 0, "size": 18 },
  "tools": [ { "name": "web_fetch", "description": "…", "enabled": true, "policy": "ask",
               "remote_safe": false, "built_in": false, "agent_enabled": true },
             { "name": "computer_use", "…": "…", "blocked_by": ["accessibility"] } ],
  "avatarImage": { "$blob": 1, "size": 48213, "mimeType": "image/png" },
  "digest": "…", "updatedMs": 1767573000200 }
```

- `systemPrompt` is inline up to 16 KiB and a JSON-string blob above that.
- `chatQuickActions` is the agent's Action Bar (`{id, icon, text, prompt}` rows), as `GET /agents`
  sends `chat_quick_actions`. It's missing for an agent on the built-in chat defaults, and the
  iPhone then shows its own copy of them. An older Mac never writes it, so the iPhone needs no flag.
- `avatarImage` is the agent's custom avatar, up to 2 MiB, as a raw blob with `mimeType`.
- `tools` has HTTP's `GET /agents/{id}/tools` rows:
  - `enabled` is on for this Mac;
  - `agent_enabled` is on for this agent;
  - `policy` is `auto`, `ask` or `deny`;
  - `remote_safe` is false when running the tool raises an approval card, or its surface blocks
    it outright;
  - `blocked_by` lists missing permissions;
  - `built_in` tools follow the agent's own switches.
- A deleted agent's message is removed. As with the models message, `digest` says when it
  changed.

## 6. HTTP routes and their Sync replacements

Every route the iPhone 1.0(11) calls (`SYNC_MOBILE_IOS_HANDOFF.md` has the full inventory),
and what replaces it:

| HTTP (MOBILE_PROTOCOL.md) | Sync |
| --- | --- |
| `POST /pair/code`, `/pair/confirm` | A pairing offer (§1) |
| `POST /pair/unpair` | **Remove** on the Mac's Devices list. The iPhone leaves the account locally. |
| `GET /health` | `SyncCore` peer state, plus `presence` (§2) |
| `GET /agents`, `GET /agents/{id}` | The directory (§2), the manage state and agent detail (§5) |
| `GET /agents/{id}/avatar` | `avatarImage` in agent detail (§5.3), or `avatar` (emoji) in the directory |
| `POST /agents`, `PATCH`/`DELETE /agents/{id}` | `createAgent`, `updateAgent`, `deleteAgent` |
| `PUT /agents/{id}/model` | `setModel` |
| `GET /agents/{id}/tools`, `PATCH …/tools/{name}`, `POST …/tools/preset` | Agent detail `tools`, `setTool`, `setToolPreset` |
| `POST /agents/{id}/warm` | `warm` |
| `POST /agents/{id}/run` (SSE) | A user turn with `hostRun` (§3), the core's stream, `host-run/1`, `run-progress/1` |
| SSE `osaurus_agent_tool`, `osaurus_prefill`, `osaurus_artifacts` | `run-progress/1` live, then `turn-detail/1` on the committed turn |
| `osaurus_voice_call`, `osaurus_privacy`, reasoning options in the run body | `hostRun.voiceCall`, `hostRun.privacy`, `hostRun.options` (§3.1) |
| `GET /runs/{id}/events`, `POST /runs/{id}/stop` | Not needed: committed turns are durable. Stop with `run/1` |
| `GET /models/picker` | The models message (§5.2) |
| `PUT /models/favorites` | `setFavorite` |
| `POST /models/options` | `getModelOptions`, `setModelOption` |
| `GET /sessions`, `GET /sessions/{id}` | The synced conversations and their messages |
| `PATCH /sessions/{id}`, `DELETE /sessions/{id}` | The core's title, pin, archive and delete calls on the conversation |
| `POST /sessions/{id}/truncate` | Delete the later messages, then send a new `hostRun` turn (§3.9) |
| `GET /sessions/{id}/context` | `context-usage/1` and `contextUsage` (§3.6) |
| `GET /sessions/{id}/turns/{t}/images/{n}` | The message's attachments, and `turn-detail/1` blobs (§3.3) |
| `GET /artifacts/{context}/{file}` | `turn-detail/1` blobs (§3.3) |
| `GET /projects` | `projects`, `plugins`, `workspaces` in the manage state (§5) |
| `POST /images/generations`, `/images/edits`, `GET /images/jobs/{id}/events`, `POST /images/cancel` | An image hosted run (§3.4), its progress, and `run/1` stop |
| `allow_remote_media_spend` | The `image` approval card (§3.4) |
| `GET /workspaces/agents`, `POST /workspace-agents/{ws}/{address}/run` | `workspaceAgents` (§5), a hosted chat with `workspace` (§3.5) |
| `GET /approvals`, `POST /approvals/{id}` | `approval/1` and `approval-answer/1` for runs the iPhone started (§3.7). Everything else is in the attention feed (§4) |
| `GET`/`POST /computer-use/prompts`, `GET`/`POST /config/approvals` | `computer_use` and `config_approval` attention items with `detail` (§4) |
| `GET`/`POST /privacy/reviews` | `privacy_review` attention items (§4) |
| `GET`/`POST /secrets/prompts` | `prompt/1` and `prompt-answer/1` (§3.8) |
| `GET /attention`, `/attention/events`, `POST /attention/{id}` | The attention feed (§4) |
| `POST`/`DELETE /devices/push-token` | None yet (§7) |

## 7. What isn't here yet

- **Live thinking.** The core's stream carries text only (`StreamUpdate {text, state}`). A
  reply's reasoning arrives with the committed turn, and `run-progress/1` counts its characters.
  Streaming it needs a typed stream channel in osaurus-sync.
- **Image preview frames.** Step progress is in `run-progress/1`, but the frames aren't sent:
  each one would be a durable blob write. This also waits for that channel.
- **Push.** The Mac stores push registrations, but no transport sends anything
  (`NoopPushTransport`), and there is no Sync record to register a token yet. Until both exist,
  the iPhone learns about new items when Sync delivers them.

## 8. The 6-digit pairing, kept for one release

The App Store iPhone 1.0(11) pairs over HTTP with a 6-digit code (MOBILE_PROTOCOL.md). This
release keeps that path working beside Sync, at parity with upstream `main` `eb0e968c3`
(`PhoneLegacyRouteParityTests`, fixtures in `Tests/Networking/PhoneLegacyFixtures/`):

- **Sharing → Devices → Mobile** generates the code and shows the paired iPhone, with **Remote
  Access for This iPhone** (the relay tunnels) and **Keep Mac Awake for This iPhone**.
- The phone's routes read the same queues as the Mac and the Sync feed. An item answered on
  one surface settles on the others, and the first answer wins.
- **Retirement.** When the first `ios` device joins over Sync, the Mac runs
  `MobileConnectMigration` once:
  - it turns off the relay tunnels **Remote Access** opened, revokes the "Mobile" access keys and
    clears the old settings;
  - from then on, `/pair/hello`, `/pair/code`, `/pair/confirm` and `/pair/unpair` answer
    `410 {"error":"update_required","message":"…"}` without a key, so an old build can tell the
    user to update;
  - the Mobile page says **Your iPhone Uses Sync Now**.

  On a Mac that never pairs an iPhone over Sync, nothing is retired.
- A Mac that ran the earlier, launch-time migration had already revoked the phone's key, so
  that phone pairs again with a new code.
- The owner HTTP API that other clients use (`/agents` list and runs, `/sessions`, `/models`,
  `/config/approvals`, resumable runs with `osaurus_run_id`) is unchanged and still requires the
  Secure Channel from relay origins.
