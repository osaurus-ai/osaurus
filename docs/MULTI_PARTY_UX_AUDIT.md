# Multi-party UX audit: Workspaces, Sync, Relay, Sharing, Multi-party

Date: 2026-10-26. Base SHA: `c40a4916b`. Scope: UI, UX and information
architecture (IA) of every surface where more than one person, device or
agent takes part: Workspaces, Sync, the agent relay, Mobile, agent sharing,
approvals and attribution.

Severity: **P0** the UI says one thing and the app does another (trust or
safety); **P1** inconsistent or hard to find; **P2** polish.

## 1. Summary

Four separate systems share the words *relay*, *pair*, *invite*, *share*,
*device*, *workspace* and *pool*, and they live in unrelated corners of the
management window:

| Surface | Before |
|---|---|
| Sync | General → Sync |
| Mobile (iPhone) | Capabilities → Mobile |
| Workspaces | General → Osaurus ID → Workspaces (child page) |
| Agent relays, Shared Inference | Developer Tools → Server → Overview |
| Per-agent relay, invites, keys | Agents → agent → Sharing & Channels |
| Approvals | Home → Approvals (one of seven approval surfaces) |

Several controls change other screens without saying so, and approvals
appear in seven differently styled places with different verbs.

## 2. P0 findings

| # | Finding | Evidence | Fix |
|---|---|---|---|
| P0-1 | Share Agent turns the internet relay on when the sheet opens, without the "Expose Agent to Internet?" warning the agent page uses for the same action. | `Views/Agent/ShareAgentSheet.swift` 108-114; `Views/Agent/AgentsView.swift` 2036-2046 | Shared `RemoteAccessConsent` step |
| P0-2 | Mobile "Reach From Anywhere" (default on) opens a public relay tunnel for every agent once a phone is paired. One WebSocket per agent does not scale and is undisclosed. | `Services/MobileConnect/MobilePairingService.swift` 594-614 | Mobile moves to Sync; per-agent relay path deleted |
| P0-3 | Workspace share sheet says "Its billing stays yours unless you enable workspace billing" while **Bill the Workspace Pool** is on by default after share. | `Views/Workspaces/WorkspaceSheets.swift` 917-919; `WorkspaceDetailView.swift` 1693-1701; `WorkspacesService.swift` 947-955 | Inline billing toggle that reflects the default |
| P0-4 | A guest whose invite-link access is revoked is never told; invite-link chats have no workspace id so they cannot reach *Unavailable*, and **Shared with you** rows have no presence dot. | `Models/Agent/SharedAgentIdentity.swift` ~286; `ChatSessionSidebar.swift` 1840-1844 | `SharedAgentStatus.accessRevoked` + dots |
| P0-5 | `ask_owner` from someone else's run never shows in the open chat (`hasInlineCard: false`), and toast + desktop notification are suppressed when that chat is frontmost, so the question exists only on Approvals. | `Services/Attention/OwnerApprovalService.swift` 422-436 | Inline card when `hostedSessionId` is set |
| P0-6 | Hosted chat says "Read-only" while `HostedOwnerComposer` sits under it and is meant to inject. | `SharedAgentIdentity.swift` 491-494; `ChatEmptyState.swift` 463-464; `HostedRunNotice.swift` 150-178 | Honest copy per chat kind |
| P0-7 | Hosted Stop unlocks after 15 s with no line saying the stop was unconfirmed. | `Views/Chat/ChatSession+HostedRun.swift` 17-20, 79-86 | "Stop not confirmed" notice |
| P0-8 | Recovery and error copy points at screens that do not exist: "Reset Synced Conversations in Settings → Storage", "Save a support report from Settings", "Osaurus ID → Identity & Recovery", "Open the Sandbox tab" / "Enable relay in the Sandbox tab". | `Services/Sync/SyncError+Osaurus.swift` 40-43; `SyncSettingsView.swift` 344; `ShareAgentSheet.swift` 213; `AgentsView.swift` 5481 | Point at real controls |
| P0-9 | Sync's pairing panel says "Scan the code with a phone", but the phone used a separate 6-digit code under Mobile. | `SyncSettingsView.swift` 297-298; `OsaurusConnectView.swift` 82-108 | One **Add a Device** flow for Macs and iPhones |
| P0-10 | Sidebar **Turn On Relay** enables an internet tunnel with no confirmation. | `ChatSessionSidebar.swift` 1684-1687 | Shared consent |

## 3. P1 findings

### Vocabulary collisions

| Word | Meanings found |
|---|---|
| Relay | agent tunnel (`*.agent.osaurus.ai`), Sync Anywhere servers, harness runtime ("Osaurus relays your messages") |
| Tunnel | body copy and the confirm button **Enable Tunnel** (`ServerView.swift` 943, 978) |
| Pool | workspace credits; Orchestrator allowed subagents (`WorkspaceDetailView.swift` 1344-1348) |
| Invite link | workspace membership; single-person agent link (**Send Invite Link…**) |
| Workspace | the team feature; Slack **Add Workspace**; sandbox folder `/workspace` |
| Pair | sync device; iPhone code; agent invite (`?pair=`); n8n credential |
| Recovery | "Recovery Phrase", "Your Recovery Code", "Recover Master Key" |
| Device | "This Mac", "(this device)", "your other Mac", "host", "peer" |
| Approve / Allow | Approve, Allow, Allow once; Deny, Decline, Dismiss; "This Task" vs "This Conversation" |

### Discoverability and consistency

- One relay flag had five editors with three status vocabularies: Server →
  Relays, agent Sharing tab, Share Agent sheet, sidebar **Turn On Relay**,
  Mobile bulk enable. Server's list showed *served elsewhere* as a bare
  yellow dot.
- Seven approval surfaces (scrim overlay, floating tool window, hosted
  composer card, Approvals page, toast, macOS notification, phone/Computer
  Use cards) with different buttons, scopes and argument visibility. No
  attention indicator in the chat window.
- Attribution ignores the `Participant` contract: free-text owner names in
  sidebar/notice copy, no human avatars, every channel origin "via channel".
- Two access lists (Issued Invites, Remote Connections) can show a key as
  Accepted and Revoked at once; neither names the person.
- Workspaces is a child of Osaurus ID; guides say "Settings → Workspaces";
  search rows for invites and shared agents do not open the inner page.
- `WorkspaceCard` says "You're a member" next to an **Admin** / **Viewer**
  badge (`WorkspacesView.swift` 641-644).
- Workspace Audit subtitle "Who changed what, and when" while the log is
  per-Mac (`WorkspaceAuditView.swift` 91-94).
- Prerequisite dead ends: "Open Credits" (tab is Wallet & Credits),
  "Turn on Router in Settings" navigates to General, "Open Identity" (tab is
  Osaurus ID), Server relay help "Identity tab".
- Catalog/guides vs UI: "Invites & Members", "Identity & Recovery",
  "Sign In with Osaurus" (UI: "Sign in with Osaurus"), "API Authentication",
  "Port & Network", no rows for Relays; `guide-getting-started.md` sidebar
  list stale.

## 4. Canonical vocabulary (glossary)

| Use | Means | Never |
|---|---|---|
| **Devices** | your own Macs and iPhones in one Sync account ("This Mac", "{device name}", "your iPhone") | host, peer, paired phone |
| **Add a Device** | the single join flow (QR or link), Mac or iPhone | 6-digit phone code, Reach From Anywhere |
| **Anywhere** | Sync network mode, "through Osaurus servers" | relay (in Sync copy) |
| **Workspace** | the team feature | for Slack say "Slack workspace"; sandbox → "sandbox folder" |
| **Teammate** | workspace member | |
| **Guest** | a person given a guest link to one agent | "Invite link" as a role |
| **Share** | live access to an agent (workspace or guest link) | |
| **Invite link** | workspace membership link | for a single agent |
| **Guest link** | single-agent link | "pairing link" |
| **Publish / Export** | store page / file | |
| **Remote access** | the agent relay; states On, Off, Connecting, On another Mac, Couldn't connect | tunnel |
| **Workspace credits** | the shared balance | pool (for Orchestrator) |
| **Allowed subagents** | Orchestrator spawn list | pool |
| **Allow / Deny** with **Once / For this conversation / Always** | the only approval language | Approve, Decline, "This Task" |
| **Recovery phrase** | the 24 words | recovery code, master key (in UI) |
| **Runs on {Mac}** | where a run executes | served by, host |

`MultiPartyVocabularyLintTests` fails on banned user-facing strings.

## 5. Information architecture

Before:

```
Home:       Agents, Workflows, Automations, Approvals
General:    General, Chat, Sync, Vault, Osaurus ID (Wallet & Credits, Workspaces), Privacy
Capabilities: …, Mobile
Developer:  Server (Relays, Shared Inference), Sandbox, Insights, Tasks
```

After:

```
Home:       Agents, Workflows, Automations, Inbox
General:    General, Chat, Vault, Osaurus ID (Wallet & Credits), Privacy
Sharing:    Workspaces, Access, Devices
Capabilities: … (Mobile removed)
Developer:  Server (Relays and Shared Inference moved to Access), Sandbox, Insights, Tasks
```

- **Devices** replaces Sync and Mobile: one list of Macs and iPhones with
  platform icons, one **Add a Device** QR/link flow, Recovery, Storage.
- **Access**: per-agent remote access, one Guests ledger, Shared With You,
  Model Sharing.
- **Workspaces** is a sidebar category; search opens its drill-ins.
- **Inbox** (raw value `approvals` kept): Needs you, Waiting on others,
  Live now.

Legacy ids resolve: `sync`, `connect`, `mobile` → Devices; `relays`,
`remote-access` → Access; `teams` → Workspaces; `needsYou`, `inbox` → Inbox.

## 6. Mobile transport decision

The iPhone becomes an ordinary Sync device (`Device.platform == .ios`). It
reaches agents through runs hosted on the Mac over Sync (Same Network or
Anywhere), never through per-agent `*.agent.osaurus.ai` tunnels. The HTTP
mobile surface (6-digit pairing, `/pair/*`, Bonjour `_osaurus-mobile._tcp`)
is removed in a hard cut. See `docs/SYNC_MOBILE_CONTRACT.md`.

## 7. Decision log

| Decision | Choice | Why |
|---|---|---|
| Deliverable | Report + phased fixes | User choice |
| Depth | Full IA restructure now | User choice |
| Mobile transport | Fully onto Sync | Per-agent relay does not scale |
| Mobile feature parity | Extend Sync app data for every phone feature | User choice |
| Cutover | Hard cut of HTTP mobile surface | User choice; ship with the matching iOSaurus build |
| iOSaurus | Mac changes + written contract | iOS app lives in another repo |
| Approvals tab name | "Inbox", raw value kept | It holds questions and waits, not only approvals |
| Agent relay name | "Remote access" | "Relay" collided with Sync and runtimes |
| Secret prompts over Sync | Sealed to the requesting device's X25519 key | Synced app data is visible to every device in the account |

## 8. Proof status

Overall: **PARTIAL**. Every row below ran on uncommitted changes on top of
`c40a4916bb05fd090ee90461798d79a17d1dff5b`. The live app was built from
working tree `e854b981b66b64d26bd82cde89236a44b18cac41` (`git write-tree` of
the full change, before this section was written). The full suite ran
before the last two edits: the stale "Device Added" fix in
`SyncStatusModel` and catalog translations.

### Automated

| Row | Result | Evidence |
|---|---|---|
| Targeted suites for the changed areas (Sync iPhone protocol, phone agent editing, Attention, retired routes, body limits, auth gate, vocabulary lint, Sync, migration, detached runs, owner access) | 218/218 pass | `swift test --filter …` on a wiped `OSAURUS_TEST_ROOT` |
| Full unit suite, this change (`make test`, keychain disabled) | 12,883 tests in 1,472 suites; 64 failed (170 issues) | `/tmp/fullsuite-current.log` |
| Full unit suite, clean `c40a4916b` worktree, same flags, same time | 12,897 tests in 1,479 suites; 69 failed (177 issues) | `/tmp/fullsuite-base.log` |
| Failure attribution | No failure is caused by this change | 47 of the 64 also fail on the base run. The 17 that fail only here pass when run alone (17/17). Rerunning all 64 alone leaves 2: `secureGetAgent_crossAgentScopedKey_returns403` fails alone on the base too (400 `invalid_agent_id`, a pre-existing bug), and `DelegatedModelOverrideTests` passes alone 3/3 (it depends on test order and also failed in the base run). Both suites ran at once, so timing tests were under double load |
| Full unit suite, final tree `d1aaf38` alone (after the two last edits) | 12,883 tests in 1,472 suites; 64 failed (301 issues) | `/tmp/fullsuite-final.log`. 40 of the 64 also fail on the base run; the other 24 pass when run alone (24/24) |
| `scripts/i18n/check.sh` (includes the new SettingsKit key check) | OK | 136 kit literals in 7 scoped paths, de / ko / ru / zh-Hans |
| `make evals-deterministic` (model-free lanes, floors enforced) | 143/143 pass, 15 skipped by design, floors met in 12/12 suites | `/tmp/evals-deterministic.log`; the skips are the live-model rows of ComputerUseLoop |
| AgentLoop / AgentLoopFrontier (model-driven) | Not run: does not apply | The change does not touch the agent loop, parsers, model runtime, cache or batching. Tool approvals only change where the answer comes from (the Sync feed instead of the phone HTTP routes); that path is covered by the targeted Attention and Sync suites |

### Live Release app

Built with `scripts/live-proof/build-keychain-free-osaurus.sh` (bundle
`com.dinoki.osaurus.multipartyproof`, ad-hoc sealed, keychain disabled,
own port 1347). Driven through the Accessibility API; window screenshots are
kept outside the repo in `/tmp/axproof/shots/`.

| Row | Result | Evidence |
|---|---|---|
| Migration from the old phone pairing | Pass | Seeded `mobileConnectPairedDevice`, `…ReachFromAnywhere`, `…RelayManagedAgents`, `…KeepMacAwake = 1`. Launch cleared all four, set `devicesKeepMacAwakeForIPhone = 1` and `mobileConnectRetiredToSync.v1`, and logged "retired the 6-digit pairing; 0 tunnel(s) off, 0 key(s) revoked" in `~/Library/Logs/Osaurus/mobile-connect.log`. Two relaunches did not run it again |
| Old phone routes | Pass | `POST /pair/hello`, `/pair/code`, `/pair/confirm`, `/pair/unpair` answer 410 `update_required` with the update message; `/pair/challenge` answers 404 |
| Devices: Keep Mac Awake for iPhone | Pass | Toggled off, stored `0`, still off after quit and relaunch |
| Devices: Add a Device and Join | Pass | Show Code renders the QR code, the code and the pairing link. A second proof instance (`…multipartyproof2`, own root) joined with the link over Same Network; both show "Connected to 1 of 1 devices" |
| Devices: Remove Device and Remove and Change Recovery Phrase | Pass | Both confirmations show the right Mac copy (the iPhone-only sentence correctly absent). Remove marks the device "Removed · No longer syncs"; the removed Mac drops to "Waiting for your other devices". Still removed after relaunch |
| Devices: stale "Device Added" after a remove | Found and fixed | The success banner stayed under a device that was just removed. `SyncStatusModel.revoke` and `revokeAndRotate` now clear it; rebuilt and rechecked with a third instance (`…multipartyproof3`): gone after the remove |
| Access: Model Sharing | Pass | Toggled on, stored `ai.osaurus.server.sharePeerInference = 1`, still on after relaunch |
| Access, Inbox, Workspaces render | Pass | All sections and empty states render; Remote Access lists the new agent |
| Agent creation (to exercise sharing) | Pass | Create Agent sheet, name set, agent persists across relaunch |
| Share Agent sheet | Pass for what is reachable | Both choices render. Workspace is disabled and says to create or join one first; Guest Link opens and shows Remote Access, What Guests Get and Guests |
| Search drill-in | Pass | "Keep Mac Awake" from Workspaces opens Devices at the iPhone section; "audit" opens Workspaces |
| Remote access consent, guest link creation, workspace detail drill-in | **BLOCKED** | All need an Osaurus ID. Generate Identity uses iCloud Keychain and the Secure Enclave, which the keychain-free proof turns off by design |

### iPhone

| Row | Result | Evidence |
|---|---|---|
| Real iPhone over Sync: add with the code, attention feed, tool approval with `arguments_preview`, sealed secret prompt, management requests, hosted runs, remove | **BLOCKED** | No iOSaurus build with a Sync client and no device in this session. The Mac side of each is covered by `SyncMobileProtocolTests`; the contract is `docs/SYNC_MOBILE_CONTRACT.md` |
| Older iPhone app against this Mac | Pass on the Mac side | The four old routes answer 410 `update_required` (live row above) |
