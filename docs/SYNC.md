# Sync

Osaurus keeps chats in [osaurus-sync](https://github.com/osaurus-ai/osaurus-sync), a Rust core
that stores conversations as signed, end-to-end encrypted event logs and syncs them directly
between a user's devices. It is the only conversation store: there is no second copy that has to
be kept in step.

User-facing operation is in the in-app guide
(`Packages/OsaurusCore/Resources/Guide/guide-sync.md`, Settings → Sharing → Devices). This
document is for developers changing the integration.

## Layout

| Piece | Role |
| --- | --- |
| `Packages/Vendor/OsaurusSync` | The vendored Swift package and xcframework (Git LFS). Update it with `scripts/update-osaurus-sync.sh`. |
| `SyncService` | Owns the one `SyncCore`: open, close, network settings, sleep and wake, core events, the device list. `observeCore(attach:detach:)` hands a consumer the open core after every open or identity replacement and tells it when the core closes; the core consumers below use it instead of their own open and close observers. |
| `SyncConversationStore` | `ConversationStore` backed by the core. `ChatSessionStore` is the facade every caller uses. |
| `SyncConversationMapper` | Session and turn to conversation and message, with app data, tags and blobs. |
| `SyncInboundApplier` | Applies other devices' changes to the sidebar and to open chats. |
| `SyncTurnStreamer` | Streams the reply being generated to other devices. |
| `SyncLegacyImporter` | Copies chats from the read-only `chat-history` database (SQLCipher when storage encryption is on), once, rebuilding chats whose turns were lost from their Memory transcript. |
| `SyncStatusModel`, `SyncSettingsView` | Settings → Devices. |
| `SyncNetworkDirectory` | The relay and discovery servers **Anywhere (Beta)** uses, fetched from `https://osaurus.ai/sync/network.json` (`OSAURUS_SYNC_NETWORK_URL` overrides it with an `https` URL, or `http` on localhost). A launch fetches at each open and network change until one fetch succeeds, at most every 15 minutes. |
| `SyncAgentDirectory` | Publishes this Mac's agents for the user's other devices and reads theirs. |
| `SyncHostRunner` | Runs chats another device asked this Mac to host. |
| `SyncHostedRunMonitor`, `ChatSession+HostedRun` | The caller's side of a hosted chat. |
| `SyncHostedRunContract` | The hosted-run app data records. |
| `SyncServedChats`, `SyncServedChatsContract` | Served chats: delivering owner turns from other devices, publishing and answering owner approvals. |
| `SyncSecretPromptQueue`, `HostedSecretCard` | Secrets a hosted run asks for, answered sealed by the device the user chats on. |
| `SyncAttentionFeed`, `SyncManageFeed`, `SyncDeviceFeedContract` | The iPhone's attention feed and agent management, with each iPhone's answers and requests in its own namespace (`docs/SYNC_MOBILE_CONTRACT.md`). |
| `SyncManageDetail` | The manage conversation's models message and one detail message per agent (system prompt, avatar, tools), with blobs. |
| `SyncRunProgress`, `SyncContextUsage` | `ai.osaurus.run-progress/1` while a synced turn runs, and `ai.osaurus.context-usage/1` after a hosted run. |
| `SyncPhoneDevices` | Names device platforms; keeps the Mac awake while an iPhone is in the account. |
| `SyncReachabilityPrompt` | Asks once, when the first iPhone joins, whether to turn on **Anywhere (Beta)**. |
| `MobileConnectMigration` | Retires the 6-digit iPhone pairing once an iPhone joins over Sync. |

On disk:

| Path | Contents |
| --- | --- |
| `~/.osaurus/sync/` | The core's data directory: its database and encrypted attachments. |
| `~/.osaurus/sync-local/` | Per-session state that never syncs (`SyncLocalSessionState`): the folder bookmark, tool step logs, turn fields over the app-data cap. Also `legacy-import.json`, the importer's ledger; `host-runs.json`, the host runner's; `served-deliveries.json`, the owner turns from other devices this Mac delivered; and `served-promoted.json`, set once served chats from before they synced were promoted. |
| `~/.osaurus/config/sync.json` | `SyncConfiguration`: `networkEnabled`, `networkMode`, `hostAgentsForOtherDevices`. |
| `~/.osaurus/config/sync-network.json` | The last good server list from `SyncNetworkDirectory`. |
| `~/.osaurus/file-history/` | File history (`FileChangeJournal`) in its own database (SQLCipher when storage encryption is on). It never syncs: snapshots are of files on this Mac. |
| Keychain service `OsaurusKeychainServices.sync` | The device key, user secret and database key. Under `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS` a file store in `~/.osaurus/sync-keys/`; unit tests use an in-memory store. |

## What syncs

`SessionSource.syncsAcrossDevices` is the single routing rule, applied when a session's scope is
created. Chats the user starts (`.chat`, `.imported`) and chats a Mac served for someone else
(`.workspace`, see Served chats) are synced scopes. Everything headless (`.plugin`, `.http`,
`.channel`, `.schedule`, `.watcher`, `.webhook`, `.email`, `.automation`, `.selfSchedule`,
`.delegation`) is a device-local scope: same store, never offered to peers. The sidebar marks
those rows **This Mac only**.

## Data contract

The mapping is specified upstream in `docs/app-data.md`, with fixtures under
`tests/fixtures/app-data/` that are vendored into `Tests/Sync/SyncFixtures` and read by
`SyncAppDataFixtureTests`. Other clients (Windows, iOS) read and write the same shape.

- A session is a conversation. Title, pinned and archived are native fields; the rest of
  `ChatSessionData` is conversation app data under `ai.osaurus.session/1`. Session id, source,
  agent, project and external key are also tags, so lists can filter without decoding app data.
- A turn is one message. Role, content and attachments are native; the rest of `ChatTurnData`
  is message app data under `ai.osaurus.turn/1`. Tool results use the `toolResult` role.
- Timestamps are integer milliseconds and UUIDs are lowercase.
- Values over 16 KiB move into app-data blobs (`{"$blob": i, "size": n}`), fetched on demand. A
  turn's app data is capped at 64 KiB; past that, fields are dropped in the order
  `injectedContextPrefix`, `responsesOutputItems`, `reasoningEncrypted`, `thinking` and kept in
  `sync-local/` on the device that wrote them.
- Keys and tags Osaurus doesn't know are preserved on rewrite. A field another client wrote in a
  shape Osaurus can't decode is dropped on read without losing the rest of the object.

## Writes

Saves are diffs: the store reads the scope's message index, sends new turns, edits changed
ones, and deletes removed ones. A save made from a copy older than what's stored must not undo
another device's work, so the store remembers which turns each session has seen:

- A stored turn this copy never saw arrived from another device; the save keeps it.
- A turn this copy saw that is no longer stored was removed elsewhere; the save doesn't resend it.
- A turn this device removed itself can be added back.

Busy chats (a run in flight or unsaved edits) don't take remote changes until they are idle, so
they never mark turns seen early.

Deleting a device-local chat deletes its scope; deleting a synced chat leaves it, which removes
it from this user's other devices too. A deleted chat is also removed from the legacy database,
and the importer's ledger keeps it from coming back.

## Inbound and streaming

`SyncInboundApplier` subscribes to the conversation list and to each open chat's scope. List
changes are debounced (250 ms) and skip scopes this device wrote in the last 2 s, so a local save
doesn't reload itself. Scope changes authored by this device are ignored the same way, by device
key.

While a reply is being generated, `SyncTurnStreamer` opens a stream on the chat's scope (synced
scopes only, and only when another device exists), pushes text deltas every 150 ms, and finishes
the stream with the final turn when the run ends. The finished stream commits the message under
the stream's id, so the run's own save finds it in the index and doesn't send it again. Other
devices show the text in a read-only bubble ("Replying on …"), lock that chat's composer, and
swap the bubble for the committed message when it arrives. The bubble is never saved. If the
message hasn't arrived 10 s after the stream finished, the bubble goes, unless the writing device
is still connected: then it waits up to 2 minutes, since a slow link is still delivering it.

Messages still in the outbox show "Waiting to reach your other devices" under the composer.

## Migration

On first launch with sync, `SyncLegacyImporter` copies every session from the SQLCipher
`chat-history` database in batches of 20, newest first, and records each imported id in
`sync-local/legacy-import.json`. It is resumable and idempotent: a session already in the store
or in the ledger is skipped, so a chat deleted after import stays deleted. The importer waits for
the storage key if it isn't available yet. Settings → Devices shows progress under **Earlier Chats**.

`ChatHistoryDatabase` is now a read-only import source. Nothing writes chats to it: it keeps its
migrations so an old file still opens, the reads the importer and file history need, and delete,
so deleting a chat also removes its old copy. The file is otherwise left as it was, as a backup.

A session with no turn rows (lost to #1737) is rebuilt at import from its Memory transcript.
The importer opens Memory only when such a session exists and Memory's database file does. If
Memory can't open, those sessions wait and the import finishes on a later launch. A session with
no transcript either is skipped. Ledger version 2 added this: a ledger finished by an earlier
build re-checks only the sessions it skipped as empty. Loading a chat no longer queries Memory.

The plaintext backup (Privacy & Security → Data & Storage) exports each conversation with
`exportConversation` into `conversations/` alongside the databases.

## Failures

An open failure is recorded as a `sync` store issue ("Synced conversations") in
`PersistenceHealth`, so the storage recovery UI shows it. Retry reopens the core. A launch open
that fails for a reason that can clear by itself (`isTransientOpenFailure`: a locked Keychain,
another copy still holding the database, the disk, the network) retries after 5 s, 30 s, 2 min
and 10 min. Reset asks first, then starts this Mac over with an empty sync identity: an open core
signs out and removes its copy, and one that can't open has its directory moved to quarantine and
its keys deleted. Sign-out and reset hold the open lock throughout, so no other open lands
between them and the fresh core. Other devices keep their chats. Settings → Devices shows the
failure too.

The core syncs again on every network change while online (Wi-Fi to Ethernet, a VPN, a hotspot),
not only when the network comes back.
`SyncError+Osaurus.swift` maps error codes to user copy, including a database from a newer build
and a damaged one; logs use `logDetail`.

Core events surface as toasts from `SyncStatusModel`: a paired device, an incompatible peer, this
Mac being revoked, and a restored backup waiting for its recovery phrase.

## Removing a device

Sharing → Devices has one **Remove Device…** in each other device's … menu. It asks for Touch ID
or the login password, and its confirmation offers two choices:

- **Remove and Change Phrase**, the default (`revokeAndRotate`). It replaces the account
  identity, so the old secret no longer admits anyone. Other devices pick up the new identity
  the next time they connect, and a wallet-linked account gets its own phrase again.
- **Remove Only** (`revokeDevice`), for a device that was wiped. Other devices turn away its
  sessions, so nothing new reaches it and nothing it writes afterwards arrives. It still holds
  the account secret, so it isn't enough for a device someone else may be holding.

What a device wrote before it was removed can still reach this Mac through another device.
The Mac's iPhone feeds are written to limit that: management requests and attention answers
older than 24 hours are ignored, an answer only settles an item that is still pending, and a
secret answer only opens for the prompt that is still waiting.

Showing the recovery phrase or a pairing code, restoring from a phrase, switching to the Osaurus
recovery phrase and signing out ask for Touch ID or the login password too
(`CredentialReveal.confirmOwner`). A Mac with no login password skips the prompt.

## What the core guarantees

The app relies on these properties of osaurus-sync 0.1.0-beta.6 (upstream
`docs/threat-model.md`, `sync/engine.rs`, `auth.rs`) instead of checking them again:

- **Revoked devices.** Conversation app data and tags are Loro updates, which are control-layer
  events. A revocation's cutoff, the newest event the revoking device had seen from the revoked
  one, rejects anything later from it, whichever device relays it. A removed device can't publish
  new requests or answers. What the revoking device had already seen stays applied; the 24-hour
  and pending-only rules above cover that.
- **Pairing offers.** One offer is open at a time. The code is 12 characters from a 32-character
  alphabet (60 bits). The offer admits one device and closes, closes after five wrong attempts,
  and expires after `pairingTTL` (5 minutes). Both sides prove the code with a keyed BLAKE3 hash
  over both device keys, so a device that doesn't know the code can't answer a typed one. It isn't
  a PAKE.
- **Pairing failures.** `PairingFailed` carries the core's reason: `invalid or expired code` from
  the host, or a proof or grant mismatch on the joiner. `pairWithOffer` returns once it connects;
  a host that never answers sends nothing, so the app times the join out itself.
- **Sign out, keeping conversations.** The device key stays. The user identity is replaced, the
  other devices are revoked here, and every conversation this device owned becomes device-local,
  the Mac's own feeds (agent directory, attention, management) included. Feed lookups ask for
  synced conversations only, so pairing again creates new synced feeds.
- **Servers.** Osaurus runs relays at `relay-us`, `relay-eu` and `relay-ap.sync.osaurus.ai`
  and a discovery server at `dns.sync.osaurus.ai` (upstream `docs/deployment.md`, "Running on
  Fly.io"). They are this Mac's bundled default, and the iPhone and Windows apps ship the same
  list. Devices on different discovery servers can't find each other over the internet (they
  still sync on one network). Osaurus 1.0.0 and 1.0.1 bundled number0's servers, so they move
  only when `osaurus.ai/sync/network.json` publishes the Osaurus list. Publish it before or
  with the build that changes the default. Until Fly delivers UDP replies reliably, fewer
  connections go direct and more show as "Connected through a relay server".

From osaurus-sync 0.1.0-beta.6:

- **Pairing confirmation.** After the code checks out, both devices show the same six digits
  (`pairingConfirmation`) next to the other device's name, and the account is handed over only
  after the user confirms on both (`confirmPairing`). "They're Different" calls `rejectPairing`.
  On the Mac showing the code, a new device that leaves before confirming puts the code back on
  screen, since the core keeps the offer open. A confirmation that arrives with no pairing in
  progress is ignored, which hands over nothing. A beta.6 Mac doesn't add a device running an
  older core, so the iPhone and Windows apps must ship beta.6 before pairing with this build.
  Links are `osaurus-pair:2:`; a `:1:` link from an older Mac still pairs, without the number.
- **Signed app data.** Conversation app data reports the device that signed each value.
  `SyncHostedRunContract.readFromOwnDevice` reads run control (Stop), tool approval answers and
  secret prompt answers only when the signer is this Mac or another current device of the
  account. Per-device namespaces (attention answers, manage requests, served-chat answers) drop
  a value signed by any device other than the one the namespace names. A value with no signer
  still counts: older builds don't sign, and the core also reports no signer when a signature
  doesn't match, so refusing unsigned values has to wait until every client is on beta.6.
- **Live state** (`setLiveState`) isn't used yet. Run progress is still stored app data, so the
  iPhone app reads it unchanged. Moving progress to live state needs the iPhone app to read it
  first, since devices before beta.6 neither send nor receive it.

## Recovery phrase

The sync identity's 24-word phrase can come from the Osaurus wallet, so the Osaurus recovery
phrase restores sync too. `SyncWalletLink` derives a 32-byte user secret with HKDF-SHA256 over the
wallet master key (info `osaurus-sync/user-secret/v1`) and encodes it as BIP39 English with
`MasterKeyMnemonic`, the same encoding the core's `UserSecret::from_phrase` reads. Linking calls
`recoverFromPhrase`, which adopts that identity and keeps this Mac's chats.

- **When.** Creating or restoring the wallet links automatically, unless the sync account already
  has other devices: switching identity would split this Mac from them. Settings → Devices →
  Recovery → **Use My Osaurus Recovery Phrase** links on request and warns about that split.
- **Record.** `SyncConfiguration.walletLinked` and `walletUserKey`. Once linked, Settings points to
  the wallet phrase instead of showing a second one, and a restored backup waiting for its phrase
  offers to unlock with the wallet.
- **Unlinked.** Rotation (`revokeAndRotate`) retires the derived identity, and the core then
  rejects the wallet phrase, so the Mac shows its own phrase again. Joining another device's
  account, or any identity change to a user key other than `walletUserKey`, clears the link too.
  Wiping the wallet clears it. A Mac with no wallet keeps its own phrase.

## Hosted runs

A chat can run its agent on another of the user's Macs: Mac B chats, Mac A runs the agent with
A's models, tools, memory and files. The contract is "Hosted runs" in upstream
`docs/app-data.md`; fixture `hosted.json`.

- **Directory.** Each Mac with **Run Agents for My Other Devices** on (the default) writes its
  agents, plus its Default agent marked `isDefault` (other Macs skip it; the iPhone offers it),
  into its own conversation, tagged `ai.osaurus.kind=agent-directory` and
  `device`, under `ai.osaurus.directory/1`. A Mac writes only its own, so writes never conflict.
  Readers skip revoked devices and their own. The store hides these conversations from chats.
  The chat sidebar lists each other Mac's agents under **On <Mac>**.
- **Request.** Picking one opens a tab whose session carries `hostDevice` (also a tag) and the
  host's agent id; the window agent stays the default one. Each user turn sent there carries
  `hostRun {device, requestedMs}`, and nothing runs on B. B sends only while A is connected; the
  composer says when A is offline. The directory also carries `features` (what A's build
  supports), `build` and `presence` (`awake`, `sleeping` or `quitting`, with A's network mode),
  written best effort as A sleeps, quits and wakes.
- **Run options.** `hostRun` MAY also carry these fields:
  - `model`, `options {reasoningEffort, thinking}`;
  - `voiceCall {instructions}`, applied to that run only;
  - `privacy` (`auto` or `off`);
  - `image`, the composer's settings for an image model.

  A honours them only from its own device or another of the user's devices that isn't revoked.
  A missing model or an option the model doesn't take is declined. The iPhone sends these;
  Mac B doesn't yet.
- **Run.** `SyncHostRunner` on A watches conversations tagged `hostDevice=A`. It runs the latest
  `hostRun` turn addressed to A once: the turn goes into `host-runs.json` before the run starts,
  then `BackgroundTaskManager` continues the stored chat (`DispatchRequest.continueSessionId`,
  reusing an open copy when one is idle) on the agent's model, not the one the chat saved on B
  (`ExecutionContext.followsAgentModel`). It assigns the agent to the conversation with the key
  from `AgentKey` (30 days, renewed in the last 7) and sends and streams the reply as the agent;
  if that fails the reply goes out as A. A writes `ai.osaurus.host-run/1` (`running`, then `done`).
  It declines with a short reply (`terminalStopReason` `host_declined`) when the setting is off,
  the agent isn't on A, or the chat is busy there. A request first seen more than an hour after
  it was made (the later of `requestedMs` and the message's HLC) is declined the same way. A run a quit or crash cut off gets an `interrupted` reply at the
  next launch; it isn't retried.
- **Stop.** B writes `ai.osaurus.run/1 {stop: <turn>}`; A cancels the task when it names the
  running turn. If A doesn't confirm within 15 seconds, B unlocks the composer anyway.
- **Approvals.** A hosted run's tool prompts don't show a panel on A. `ToolPermissionPromptService`
  holds them for the requester `.syncedDevice(scope)` (bound by the `syncReviewerScope`
  task-local), A publishes them as `ai.osaurus.approval/1`, and B renders cards (Deny, Allow,
  Allow for This Conversation, Always Allow) and writes `ai.osaurus.approval-answer/1`. Always
  Allow saves the policy on A. Prompts still waiting when the run ends are denied. A cloud image
  run's spend asks through the same card (`tool: "image"`).
- **Other prompts.** Computer Use and config prompts aren't routed to the chat yet. They show on
  A, and the iPhone answers them from its attention feed, with their detail. A hosted run's
  Privacy Filter review doesn't open a sheet on A: it is a `privacy_review` attention item,
  which the iPhone answers with the detections to redact.
- **Progress and detail.**
  - While the run goes, A writes `ai.osaurus.run-progress/1`: phase, prefill, tool steps,
    image steps and files, coalesced to 500 ms (2 s when every connected device is relayed).
  - The committed reply carries `ai.osaurus.turn-detail/1`: each tool call's label and its
    generated images and shared files as blobs.
  - After the run A writes `ai.osaurus.context-usage/1`.
  - Contract and fixtures: `SYNC_MOBILE_CONTRACT.md` §3 and `mobile-hosted.json`.
- **Secrets.** `sandbox_secret_set` without a value parks the request in
  `SyncSecretPromptQueue`. A publishes it as `ai.osaurus.prompt/1` with a one-use X25519 key;
  B seals the value to it (`PairingKeyEnvelope`, info `osaurus-sync-secret-v1:<id>`) and writes
  `ai.osaurus.prompt-answer/1`. Only A can open it, and it goes straight into A's Keychain.
- **Notice on A.** While A runs a chat for another device, A's window for it shows **Answering
  for <device>…** and Inbox → Live Now lists it.
- **Files.** A chat bound to a folder on B can't be hosted: picking a hosted agent clears it,
  and the folder picker is hidden there. Attachments travel as blobs.
- **Workspace agents.** A hosted session with `workspace {workspaceId, agentAddress}` and no
  agent id runs toward that teammate's shared agent with A's identity, while it is still shared
  into one of the user's workspaces. This is how the iPhone, which has no wallet, chats with
  them.
- **Edit and resend.** Deleting a turn and those after it, then sending a new `hostRun` turn,
  gets one reply to the new turn.

## Served chats

A `.workspace` session is a chat a Mac served with one of the user's agents for a workspace
teammate or an invite-link caller (or, before the move to Sync, the paired iPhone). It syncs to the user's devices; the caller
is never one of them, so it never enters the caller's sync. Only the serving Mac talks to the
caller. The contract is "Served chats" in upstream `docs/app-data.md`; fixture `served.json`.

- **Tag.** `SyncConversationStore` stamps `servedBy` (this device's key) when it creates the
  conversation, and `SyncServedChats` stamps it when it promotes the device-local `.workspace`
  chats from before this change, once (`served-promoted.json`). It isn't an owned tag, so other
  devices' saves keep it, and `ChatSessionData.servedBy` is never encoded.
- **Listing.** On another device, `ChatSessionsManager.sessions(forHost:agentId:)` lists the chat
  under the serving Mac's agent (**On <Mac>**) and `sessions(for:)` leaves it out of the local
  agents. `ChatTabScope` opens it as `.hosted`. It has no `hostDevice`, so `SyncHostRunner`
  never runs it.
- **Owner turns.** `HostedOwnerComposer` on another device appends a user turn authored
  `.ownerDevice(<device name>)` and saves it (`SyncServedChats.postOwnerMessage`). The serving
  Mac picks up user turns another of the user's non-revoked devices wrote as the user, authored
  `.owner` or `.ownerDevice`, from the latest 50 messages, and hands each to
  `InboundSharedRunBridge.deliverOwnerTurn` (the run, the caller's stream or mailbox, Insights,
  the audit) once. It records the turn in `served-deliveries.json` (30 days) before acting and in
  `ai.osaurus.served-delivery/1`, which the other devices read to show **Waiting for <Mac>**.
  Turns more than 7 days old when the Mac first sees them aren't delivered. Chats from the
  iPhone take no owner turns (`acceptsOwnerMessages`).
- **Approvals.** The serving Mac publishes the owner approvals a chat is waiting on
  (`OwnerApprovalService`, kind `.ownerApproval`) as `ai.osaurus.owner-approval/1` whenever
  `AttentionCenter` raises or settles one. Each other device raises a mirror: an Approvals entry,
  a notification and, when the chat is open, the inline card. Its answer goes to
  `ai.osaurus.owner-approval-answer/1/<its device key>`, one namespace per device, so answers
  never overwrite each other. The serving Mac resolves the item with the earliest answer from a
  known device, `decidedBy: .ownerDevice(<name>)`, which Insights and the audit record; the first
  answer anywhere wins and later ones are ignored. Timeouts and cancellation happen on the
  serving Mac only; the other devices withdraw their mirror when the approval leaves `pending`.
- **Streaming.** The serving Mac streams the reply to its other devices with `SyncTurnStreamer`
  pinned to the streamed turn, and leaves that turn out of saves (`syncStreamingTurnId`) until
  the stream commits it, so the reply isn't written twice.

## Deprecated

Hosted runs replace reaching your own agents on another Mac over the relay. When the agent's host
is one of the user's sync devices, `ChatWindowState.switchToWorkspaceAgent` opens a hosted chat
instead. The iPhone is a sync device too (`docs/SYNC_MOBILE_CONTRACT.md`). Kept for Macs on older
builds, and to be removed once those are gone:

- `OwnerDeviceAccessHost` (owner redeem on `POST /pair-invite`) and its access keys.
- The owned-elsewhere relay route behind `SharedAgentIdentity.isOwnedElsewhere`.
- Resumable owner runs (`osaurus_run_id`, `GET /runs/{id}/events`, `POST /runs/{id}/stop`,
  `DetachedPhoneRuns`). They were built for the iPhone's HTTP client, which Sync replaced; they
  stay while other owner HTTP clients may name runs.
- The iPhone's 6-digit pairing and its HTTP routes (**Devices → Mobile**,
  `docs/MOBILE_PROTOCOL.md`), for the App Store iPhone 1.0(11). They are kept for one release
  at parity with upstream `main` (`PhoneLegacyRouteParityTests`). `MobileConnectMigration`
  retires them once an iPhone joins over Sync (`SYNC_MOBILE_CONTRACT.md` §8).

## FAQ

The user-facing version is the in-app guide topic `guide-sync.md`.

1. **Pairing my device shares all my agents?** Yes, every custom agent while **Run Agents
   for My Other Devices** is on (the default); there is no per-agent choice. The Default agent
   is published too, marked `isDefault`: the iPhone offers it and other Macs skip it. Agent settings,
   memory, tools and files don't copy: the other device sends hosted runs to the Mac that runs
   the agent. Chats the user starts sync; headless chats don't. Pairing covers the user's own
   devices only.
2. **A device on my network finds my agents automatically?** Only devices paired into the same
   sync account, through **Same Network** (the default) or **Anywhere (Beta)**. Per-agent Bonjour
   (`_osaurus._tcp`) is gone. The iPhone joins with a Sync pairing code like any device; the
   Mac's `_osaurus-mobile._tcp` advertiser for the 6-digit flow stays up only until an iPhone
   joins Sync.
3. **Workspaces let me choose which agents to share?** Yes, one agent at a time
   (`WorkspacesService.shareAgent`), with other people through the router and relay. Sync never
   shares an agent with a workspace.
4. **Losing my Keychain bricks my chats?** Not with a way back: the sync phrase (or the wallet's
   once linked, see Recovery phrase), another paired device that still has the chats, or a linked
   wallet still in iCloud Keychain (**Unlock With My Osaurus Recovery Phrase**). Without one, the
   store stays sealed: unreadable, not deleted. Other local data (memory, file history, tool and
   automation databases, the legacy chat backup) uses the separate per-device storage key
   (`StorageKeyManager`), which no phrase recovers.
5. **How do Workspaces and the relay fit with sync?** Sync never carries a run to someone else's
   Mac.
   - The member's side of a chat with a teammate's agent is an ordinary `.chat` session with a
     `WorkspaceSessionContext`, so it syncs. Each of the member's Macs connects to the agent
     itself (`WorkspaceAgentConnectService`). Invite-link agents are paired per device: another
     Mac shows the history but needs the link redeemed there to continue.
   - The owner's side (`InboundSharedRunBridge`) is a `.workspace` session. It syncs to the
     owner's devices with a `servedBy` tag; any of them can speak in it and answer its
     approvals, and the serving Mac delivers them (see Served chats). It never enters the
     teammate's sync.
   - Agent traffic uses the agent relay (`*.agent.osaurus.ai`) and the router. **Anywhere
     (Beta)** uses the sync relays from `SyncNetworkDirectory`. Neither carries the other's
     traffic.
6. **Is it backwards compatible?**
   - Workspaces, invite links and relay chats are unchanged (`/pair-invite`, Secure Channel and
     the router are untouched).
   - The user's Macs on pre-sync builds don't sync; they still reach the user's agents through
     owner redeem, which stays until pre-sync builds are no longer supported.
   - A synced Mac on an older sync build receives promoted `.workspace` chats without knowing
     `servedBy`: it lists them under the local agents, its composer may still append an owner
     turn (which the host delivers, as an owner turn from one of the user's devices), and it
     shows no approval cards or waiting state.
   - Older builds can no longer pair over the LAN: `/pair` and `/pair/challenge` return an
     error. Agents they already paired that way stay as providers and keep working until the
     key expires (90 days by default) or is revoked. The relay still works. The iPhone's
     `/pair/code` and its phone-only routes keep working for iPhone apps without Sync until an
     iPhone joins Sync; from then on they answer `410` and the iPhone pairs through Sync.
   - A downgrade to a pre-sync build shows the pre-sync chats from the untouched `chat-history`
     backup. Chats started after sync exist only in the sync store.

## Tests

| Suite | Covers |
| --- | --- |
| `SyncConversationStoreTests` | Round trips, diffs, metadata, delete, search, routing. |
| `SyncAppDataFixtureTests` | Upstream fixtures, tolerant decode, unknown-field preservation. |
| `SyncInboundTests` | Stale-copy saves, remote changes into open chats, streaming. |
| `SyncLegacyImporterTests` | Import once, resume, skip deleted chats, device-local headless chats, transcript recovery, the version 2 re-check. |
| `SyncCoreObserverTests` | `observeCore`, and the four core consumers dropping and regaining their subscriptions across close and reopen. |
| `SyncLoopbackTests` | Two cores paired over loopback: a chat and its live reply reach the other device. |
| `SyncAppDataFixtureTests` (`mobile-*.json`) | The iPhone's v2 records read against the Mac's own encoders: run options, progress, turn detail, context usage, the image spend card, workspace chats, the directory's features and presence, attention detail and per-iPhone answers, the new manage ops and detail messages. |
| `SyncMobileProtocolTests` | Sealed secrets, attention answers, management requests, the Default agent in the directory. |
| `SyncMobileV2Tests` | Per-iPhone namespaces, presence, run options and their gate, progress cadence, turn detail and blobs, the manage ops, attention detail, image settings, workspace agents, the Anywhere prompt. |
| `MobileToSyncMigrationTests` | Retiring the 6-digit pairing once an iPhone joins over Sync, and only then. |
| `PhoneLegacyRouteParityTests` | Every iPhone 1.0(11) route and SSE event answers as on upstream `main` (`PhoneLegacyFixtures/`). |
| `PhoneLegacyCrossSurfaceTests` | A card answered over HTTP settles the Sync attention item and the reverse. |
| `SyncNetworkDirectoryTests` | Server list fetch, validation, cache and fallback. |
| `SyncRecoveryTests` | Store issue, reset and reopen. |
| `SyncWalletLinkTests` | The wallet-derived phrase, BIP39 vectors and core compatibility, one identity across Macs, unlink on rotation and handoff. |
| `SyncHostedRunTests` | Directory over loopback, the host's run, declines and stop, held approvals, the caller's waiting state, edit and resend. |
| `SyncServedChatsTests` | The `servedBy` tag and promotion, authors, which owner turns are delivered, delivery once across a restart and approvals answered from another device over loopback, mirrors on the other device. |

Run them with the targeted filter from `.cursor/rules/testing-workflow.mdc`.
