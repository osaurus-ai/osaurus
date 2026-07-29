# iMessage Channel Release Runbook

This runbook proves service-level readiness for the native iMessage Agent
Channel and documents the pinned-helper rotation procedure. iMessage differs
from the remote-bot channels: there is no provider credential. Trust is
anchored in a pinned `imsg` helper, local macOS permissions (Full Disk
Access, Messages Automation), and local allowlists. Advanced actions use
Apple-private APIs and are additionally gated on operator-disabled SIP and
Library Validation, which Osaurus only ever diagnoses — never changes.

## Helper Acquisition

The helper is NOT part of the app bundle or the release pipeline. It is
downloaded on demand, like the sandbox runtime and models: the Download
button in iMessage settings drives `IMessageHelperInstaller`, which fetches
the pinned release archive, verifies the archive SHA-256 with the resumable
downloader, verifies each Mach-O digest again, strips quarantine only after
those digests match, and installs atomically to
`~/.osaurus/helpers/imsg/<version>/`.

Trust order at spawn time: `OSAURUS_IMSG_PATH` dev override (DEBUG builds
only; release builds ignore the variable) → `Contents/Helpers` (defense in
depth — no build lane stages a copy there today) → the downloaded
directory. Candidates verify independently: a bundle copy that fails
verification does not mask a valid downloaded copy. The downloaded
directory is user-writable, so every spawn re-verifies the executable
digest and the bridge dylib digest; a swapped binary or dylib fails closed.
The same-team-signature trust path (below) applies only to copies inside
the app bundle — a downloaded copy must match the digest pins exactly.

## Pinned Helper Rotation

All pins live in one manifest: `scripts/build/imsg-helper-manifest.json`
(version, archive URL + SHA-256, executable + bridge dylib SHA-256, required
Mach-O slices, resource bundle names). The `pinsStayInSyncWithBuildManifest`
unit test fails CI when the constants in
`Packages/OsaurusCore/Services/IMessage/IMessageRuntimeAssets.swift` drift
from it — so a rotation must update both, and CI proves they match.

To rotate to a new `imsg` release:

1. Download the release artifacts for the new tag from the upstream repository
   recorded in `IMessageRuntimeAssets.upstreamRepository` and compute their
   SHA-256 digests yourself (`shasum -a 256`). Do not trust digests published
   in release notes without recomputing.
2. Update `scripts/build/imsg-helper-manifest.json` and the matching
   constants in `IMessageRuntimeAssets.swift`, plus the version in
   `App/osaurus/Acknowledgements.json`. Run the iMessage test filter — the
   pin-sync test must pass.
3. In a build with the new pins, use the Download button in iMessage
   settings and confirm the installer verifies, installs, and reports the
   helper as Verified (the installer enforces digest and Mach-O slice
   requirements with a native parser on user machines).
4. Re-run the app-surface proof checklist below.

Trust verification at spawn time is fail-closed with two accepted paths:

- Digest pin: the helper is byte-identical to the pinned upstream release.
  This is the only path a downloaded copy can take.
- Same-team signature: accepted only for a copy sealed inside the app
  bundle (defense in depth — kept so a future bundling lane that re-signs
  the helper, changing its digest, stays trusted; never applies to the
  user-writable downloaded directory).

A stale pin therefore degrades to a hard "helper unavailable" failure — the
channel refuses to spawn an unpinned binary and falls back to configured-only
behavior. `OSAURUS_IMSG_PATH` exists for local development only and must never
be set in a release environment.

## Fast Fixture Pass

Run without any real Messages state:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
swift test --package-path Packages/OsaurusCore --filter "IMessage"
```

This covers JSON-RPC framing/redaction (including watch notifications),
configuration normalization and clamps, attachment-root fencing (traversal,
prefix-shadowing), advanced-action gating (master gate, per-action enablement,
live bridge capability probe), send confirmation/allowlist/chunking, the
watch-based receive pipeline (cursor resume, authorization, dedupe,
filtered-row cursor advancement), and the watch transport runtime health
states (helper missing, Full Disk Access gate, session interruption backoff).

## macOS Permission Matrix

Record the state of each permission in the release artifact. All are granted
in System Settings by the operator; Osaurus deep-links but cannot grant them.

| Permission | Needed for | Failure mode when missing |
| --- | --- | --- |
| Full Disk Access | Reading `chat.db` (receive, read, chat discovery) | Receive stays not-ready; diagnostics list the FDA failure. |
| Automation (Messages) | Sending via Messages.app | Sends fail; diagnostics list the Automation failure only when writes are enabled. |
| Messages signed in | Everything | Not probeable: imsg exposes no sign-in state, so diagnostics report `messages_signed_in: "unknown"` and sends fail with a helper error when signed out. Setup shows an informational sign-in row. |

## App-Surface Proof Checklist

Launch with `scripts/live-proof/launch-keychain-free-osaurus.sh`, configure
Settings → Agent Channels → iMessage with disposable chats, and drive checks
through the live app surface (`agent_channel_*` tools plus settings UI).

| Area | Required proof |
| --- | --- |
| Helper integrity | Settings shows the downloaded helper as Verified (or Dev override in a dev build); `agent_channel_diagnostics` reports `helper_verified`, `helper_state`, and no home-directory paths in any failure text. |
| Connection listing | `agent_channel_list_connections` shows `imessage` with helper availability, action policy, read/write allowlists, and confirmation metadata. No credential fields appear (the channel has none). |
| Chat discovery | Load recent Messages chats in settings returns rows from the helper; with the helper unavailable, listing falls back to configured allowlist ids only. |
| Read/store | `agent_channel_read_messages` and `agent_channel_search_messages` return only from the local message store and only for read-allowlisted chats. |
| Draft no-send | `agent_channel_draft_message` returns a local preview with `requires_send_confirmation` and no helper dispatch. |
| No unapproved send | `agent_channel_send_message` with omitted or false `confirm_send` fails before helper dispatch. |
| Approved send | A single disposable send with `confirm_send: true` to a write-allowlisted chat delivers through Messages.app. |
| Kill switch | With the global channel write switch off, the same approved send is denied; re-enabling restores it. |
| Unauthorized chat | A chat outside the read/write allowlists returns not-allowlisted results and writes no message snapshots. |
| Unauthorized sender | A message from a sender outside Authorized Senders is rejected before storage or dispatch (receive counters and store confirm). |
| Receive | With receive storage + receive enabled, an authorized sender's iMessage in a readable chat lands in the store and is readable; the receive health card reports healthy with received/stored counts; the settings receive test passes end to end. Receive runs over a live `watch.subscribe` stream; a killed helper reconnects and resubscribes from the stored `chat.db` ROWID cursor, so messages sent during the outage still arrive. |
| Crash-recovery dedupe | Restart the app mid-session and re-send: rows redelivered by the since-rowid backfill are deduplicated by message GUID (stored count 0 on replay), and the cursor never moves backwards. |
| External MCP denial | Over live HTTP: `/mcp/tools` does not expose `agent_channel_*` (including the four `agent_channel_imessage_*` tools), and `/mcp/call` returns `403 tool_not_exposable`. |

## Advanced (Private-API) Lane

Advanced actions — threaded reply, edit, unsend, tapback, typing indicator,
send attachment, message effect, poll, group management — run through `imsg`'s
private-API bridge, which only works when the operator has disabled SIP and
Library Validation. Security posture for this lane:

- Osaurus never disables, weakens, or offers to change SIP or Library
  Validation. The setup UI and diagnostics only read and display that state
  (`csrutil status`, the Library Validation override plist) with an explicit
  warning that this is an operator-selected security tradeoff made in
  Recovery, outside Osaurus.
- Every advanced action requires ALL of: the global channel write switch,
  chat write allowlist, `confirm_send: true`, the master Advanced Actions
  toggle, the individual per-action toggle, and a live bridge capability probe
  reporting the specific method. Anything missing yields a typed
  disabled/unavailable error, not a silent fallback.
- Attachment sends are additionally fenced to allowlisted attachment roots
  with traversal rejection and a size cap.

Proof rows (on a machine where the operator has NOT disabled protections):

| Area | Required proof |
| --- | --- |
| Gating without bridge | With an advanced action enabled in settings but SIP/Library Validation intact, the tool returns the `advanced action unavailable` failure and no helper dispatch occurs. |
| Master gate | With the master toggle off, an individually enabled action returns the `advanced action disabled` failure. |
| Diagnostics honesty | `agent_channel_diagnostics` reports `sip_enabled` / `library_validation_enabled` truthfully and includes the operator-tradeoff note whenever advanced actions are enabled. |

Full live advanced proof (actual edit/unsend/effect/poll/group deliveries) is
only possible on a dedicated, operator-degraded machine and must be recorded
as such in the release artifact; it must never be a release blocker for the
basic lane.

## Redaction Check

Before sharing artifacts:

```bash
rg -n "$HOME|/Users/[a-z0-9_-]+" <artifact-dir>
```

The command should return no raw home paths (helper errors and diagnostics are
`~`-redacted at the source). Phone numbers and chat GUIDs of disposable test
chats are acceptable; real contacts are not.

## Release Dependencies

None. The helper is intentionally NOT part of the release artifact — it is
acquired at runtime through the digest-pinned download flow, so the app
build, signing, and notarization pipeline is unchanged by this channel. A
release only interacts with the helper through the pins compiled into
`IMessageRuntimeAssets` (locked to the manifest by the pin-sync test).
