# WhatsApp Channel Release Runbook

This runbook proves service-level readiness for the native WhatsApp Agent
Channel and documents the pinned-helper release/rotation procedure. Like
iMessage, WhatsApp has no provider credential: trust is anchored in a pinned
`osaurus-wa` helper (a whatsmeow-based WhatsApp Web bridge built from
`helpers/osaurus-wa/`), a QR-linked session in the helper's local store, and
local allowlists. The channel speaks the unofficial WhatsApp Web multi-device
protocol — WhatsApp can log the session out at any time, and a dedicated
number is recommended for agent use.

## Helper Acquisition

The helper is NOT part of the app bundle or the release pipeline. It is
downloaded on demand: the Download button in WhatsApp settings drives
`WhatsAppHelperInstaller`, which fetches the pinned release archive, verifies
the archive SHA-256 with the resumable downloader, verifies the installed
binary digest again, strips quarantine only after that digest matches, and
installs atomically to `~/.osaurus/helpers/osaurus-wa/<version>/`.

Trust order at spawn time: `OSAURUS_WA_PATH` dev override (DEBUG builds only;
release builds ignore the variable) → `Contents/Helpers` (defense in depth —
no build lane stages a copy there today; accepted by digest pin or same-team
code signature) → the downloaded directory (digest pin only, since it is
user-writable). Every spawn re-verifies; a swapped binary fails closed.

Digests are pinned to the `wa-helper-v0.2.3` release archive. If the pins
were ever reset to all-zero (unpinned), the Download button would stay
hidden, the installer would refuse up front, and the only spawnable helper
would be a dev build (`make wa-helper` + `OSAURUS_WA_PATH`).

## Publishing / Rotating the Pinned Helper

All pins live in one manifest: `scripts/build/wa-helper-manifest.json`
(version, archive URL + SHA-256, executable SHA-256, required Mach-O slices).
The `pinnedDigestsMatchReleaseManifest` unit test fails CI when the constants
in `Packages/OsaurusCore/Services/WhatsApp/WhatsAppRuntimeAssets.swift` drift
from it — a rotation must update both, and CI proves they match.

To publish a new `osaurus-wa` release:

1. Bump `helperVersion` in `helpers/osaurus-wa/main.go` and `version` in
   `WhatsAppRuntimeAssets.swift` + the manifest (they must agree).
2. Run `make wa-helper-release`. It builds `build/osaurus-wa`, packages
   `build/osaurus-wa-macos.zip` with `ditto`, and prints both SHA-256
   digests. Recompute digests yourself (`shasum -a 256`) if the archive was
   produced anywhere else — never trust digests published in release notes.
3. Upload `osaurus-wa-macos.zip` to the `wa-helper-v<version>` release tag on
   the repository recorded in `WhatsAppRuntimeAssets.upstreamRepository`.
4. Pin `archiveSHA256` and `executableSHA256` in
   `scripts/build/wa-helper-manifest.json` AND `WhatsAppRuntimeAssets.swift`.
   Run the WhatsApp test filter — the pin-sync test must pass.
5. In a build with the new pins, use the Download button in WhatsApp settings
   and confirm the installer verifies, installs, and reports the helper as
   Verified (the installer enforces the digest and the arm64 slice with a
   native Mach-O parser on user machines).
6. Re-run the app-surface proof checklist below.

A stale pin degrades to a hard "helper unavailable" failure — the channel
refuses to spawn an unpinned binary. `OSAURUS_WA_PATH` exists for local
development only and must never be set in a release environment.

## Fast Fixture Pass

Run without any real WhatsApp state:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
swift test --package-path Packages/OsaurusCore --filter "WhatsApp"
```

This covers JSON-RPC framing/redaction (including watch notifications and
process lifecycle against a scripted helper), configuration normalization
(E.164/JID/LID id space) and clamps, attachment-root fencing, send
confirmation/allowlist/chunking, quoted replies / edit / revoke wiring, the
watch receive pipeline (allowlist pre-filter, authorization, WAMID dedupe,
self-message handling, media attachments, read-receipt batching), and the
watch transport runtime health states (helper missing, unlinked account,
session interruption backoff).

## Prerequisite Matrix

There are no macOS permissions to grant. The channel's preconditions are:

| Prerequisite | Needed for | Failure mode when missing |
| --- | --- | --- |
| Verified helper | Everything | Diagnostics report `helper_unavailable`; all actions refuse before spawn. |
| Linked account (QR) | Everything except configuration | Diagnostics report `not_linked`; sends/receive fail with the not-linked error and settings prompt for a QR scan. |
| Receive toggle + readable chats + authorized senders | Receive | The watch transport stays stopped; readiness lists each missing piece. |
| Write toggle + writable chats + global write switch | Sends (text, reply, edit, revoke, reaction, typing, attachment) | Typed writeDisabled / not-writable / kill-switch errors before helper dispatch. |
| Attachment support toggle + allowlisted roots | Inbound media download, outbound attachment sends | Inbound media degrades to `[image]`-style placeholders; outbound attachment sends refuse with the path-fence error. |

## App-Surface Proof Checklist

Launch with `scripts/live-proof/launch-keychain-free-osaurus.sh`, configure
Settings → Agent Channels → WhatsApp against a disposable/dedicated number,
and drive checks through the live app surface (`agent_channel_*` tools plus
settings UI).

| Area | Required proof |
| --- | --- |
| Helper integrity | Settings shows the helper as Verified (or Dev override in a dev build); `agent_channel_diagnostics` reports `helper_verified`, `helper_state`, and no home-directory paths in any failure text. |
| QR pairing | Link with QR renders rotating codes; scanning links the account; the linked number appears; Unlink logs out (or wipes locally when offline) and the UI returns to the unlinked state. Relaunch: the link survives. |
| Connection listing | `agent_channel_list_connections` shows `whatsapp` with helper/link state, action policy, read/write allowlists, and confirmation metadata. No credential fields appear. |
| Chat discovery | Load from WhatsApp returns groups + DM contacts from the helper; with the helper unavailable, listing falls back to configured allowlist ids only. |
| Read/store | `agent_channel_read_messages` / `agent_channel_search_messages` return only from the local store and only for read-allowlisted chats; rows expose `reply_thread_id`, quoted metadata, and attachments when present. |
| No unapproved send | `agent_channel_send_message` with omitted/false `confirm_send` fails before helper dispatch; the same for reply/edit/delete/reaction/typing/attachment. |
| Approved send | A single disposable send with `confirm_send: true` to a write-allowlisted chat delivers to the phone. |
| Quoted reply | `agent_channel_reply_thread` with `<chat_id>:<message_id>` renders on the phone as a real WhatsApp reply quoting the target message. |
| Edit / delete | `agent_channel_edit_message` updates the sent message in place on the phone; `agent_channel_delete_message` shows "This message was deleted" (revoke). |
| Attachment send | `agent_channel_whatsapp_send_attachment` delivers an image with caption from an allowlisted root; a path outside the roots refuses with the fence error and no helper dispatch. |
| Kill switch | With the global channel write switch off, every approved write is denied; re-enabling restores it. |
| Unauthorized chat | A chat outside the allowlists is dropped before authorization (watch drop counter) and returns not-allowlisted results for reads/writes. |
| Unauthorized sender | A message from a sender outside Authorized Senders is rejected before storage or dispatch. |
| LID sender | A sender whose events arrive LID-addressed (common in groups) still matches their `+E.164` allowlist entry and dispatches; the raw `sender_lid` is visible in the stored payload. |
| Receive | With receive on, an authorized sender's message lands in the store, the health card reports healthy, and the settings Verify flow passes end to end. Kill the helper mid-session: the runtime backs off, respawns, resubscribes, and WAMID dedupe keeps replayed rows out. |
| Inbound media | With Handle Attachments on, an inbound image lands under `~/.osaurus/whatsapp/media/…`, the stored row carries the attachment, and an over-cap file degrades to a placeholder with `media_skipped`. |
| Read receipts | With Send Read Receipts on, handled messages show blue ticks on the sender's phone; with it off they do not. |
| Remote logout | Unlink the device from the phone (Linked Devices): the watch stream surfaces the logged-out error, receive stops instead of retrying silently, and settings prompt to re-link. |
| External MCP denial | Over live HTTP: `/mcp/tools` does not expose `agent_channel_*` (including `agent_channel_whatsapp_send_attachment`), and `/mcp/call` returns `403 tool_not_exposable`. |

## Redaction Check

Before sharing artifacts:

```bash
rg -n "$HOME|/Users/[a-z0-9_-]+" <artifact-dir>
```

The command should return no raw home paths (helper errors and diagnostics
are `~`-redacted at the source). Phone numbers of disposable test numbers are
acceptable; real contacts are not.

## Release Dependencies

None. The helper is intentionally NOT part of the release artifact — it is
acquired at runtime through the digest-pinned download flow, so the app
build, signing, and notarization pipeline is unchanged by this channel. A
release only interacts with the helper through the pins compiled into
`WhatsAppRuntimeAssets` (locked to the manifest by the pin-sync test).
