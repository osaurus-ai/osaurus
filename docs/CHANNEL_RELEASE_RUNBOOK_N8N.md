# n8n Channel Release Runbook

This runbook proves the `n8n` Agent Channel end to end against a real n8n
instance. It is scoped to a disposable connection, a disposable agent, and a
throwaway n8n workflow. Contract details live in
`docs/AGENT_CHANNELS_N8N.md`.

## Fast Fixture Pass

Run without secrets or a live n8n:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
OSU_MODELS_DIR=/tmp/osaurus-test-models \
swift test --package-path Packages/OsaurusCore \
  --filter "AgentChannelWebhookIngress|HTTPChannelInboundRoute|CustomJSONAgentChannelRunner|N8nConnectionDraft|AgentChannelSetupFlow"
```

Then the deterministic policy eval:

```bash
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/AgentChannels OSAURUS_EVALS_SKIP_PREP=1
```

`agent_channels.n8n-inbound-contract` must pass and the AgentChannels floor
stays at 1.0. These rows are executed proof of the ingress contract but do not
exercise a real n8n execution, the settings UI, or a model.

## Live Topology

The reference setup is n8n in Docker on the same Mac. Record these facts before
starting; they decide which transport rows apply:

| Fact | How to check | Expected |
| --- | --- | --- |
| n8n version and container | `docker ps` | `n8n-n8n-1`, 2.x |
| n8n can reach Osaurus | `docker exec n8n-n8n-1 wget -qO- http://host.docker.internal:1337/health` | `200` |
| Docker Desktop delivers `host.docker.internal` over loopback (macOS) | Send a verified envelope from the container while the policy is `secure_channel_required` | `202` (not `426`) — the host forwarder connects from `127.0.0.1` |
| Mac LAN IP is a genuine non-loopback origin | `ipconfig getifaddr en0`, then call `http://<lan-ip>:1337/...` from the Mac with *Expose to Network* on | `426` under `secure_channel_required` |

On macOS the Docker container is therefore a same-Mac caller for the transport
policy; the `426`/`plaintext_allowed` rows are proven by addressing Osaurus on
its LAN IP (which requires *Expose to Network* so the server binds `0.0.0.0`).
Plain `curl` to `127.0.0.1` is used to prove the loopback exemption — and it
must keep passing with *Expose to Network* on, because the policy keys off the
physical transport, not the `trustLoopback` auth flag.

## Setup (once)

1. Quit any other Osaurus bound to `:1337`. Build a fresh isolated Release
   development app from the branch SHA, launch it, and confirm `/health`
   reports the new build.
2. Settings → Channels → Add Channel → **n8n**:
   - *Name it*: display name of your choice; confirm the Connection ID
     auto-fills as a slug (edit it to `n8n-local`);
   - *Where is your n8n?*: **Docker Desktop on this Mac** (a loopback caller —
     see Live Topology; the plaintext toggle must not be shown for it);
   - *Who answers?*: a disposable custom agent with a loaded local model,
     auto-reply **off** (pull mode);
   - *Pair*: the secret was generated silently (visible under Advanced);
     verification `hmac_sha256` (repeat later with `shared_secret_header`);
     the pairing code must show exactly one URL, `http://host.docker.internal:1337`;
   - *Prove it*: leave the allowlists empty — they fill by approving the first
     workflow run (or add `n8n-test` / `tpae` under Advanced for the curl rows).
   Save, navigate away and back, **relaunch**, re-open the card and confirm
   every field persisted, including `callerLocation`. Confirm
   `agent-channels.json` contains the `n8n` block and does **not** contain the
   secret. The channel's on/off switch is on its card in the channel list.
3. Author the bridge workflow JSON under `/tmp` (never in the repo) using the
   stock-node recipe in `docs/AGENT_CHANNELS_N8N.md`, then import and activate
   it through the container CLI so runs are real n8n executions:

   ```bash
   docker cp /tmp/osaurus-bridge.json n8n-n8n-1:/tmp/osaurus-bridge.json
   docker exec n8n-n8n-1 n8n import:workflow --input=/tmp/osaurus-bridge.json
   docker exec n8n-n8n-1 n8n update:workflow --id=<id> --active=true
   ```

   Provide the secret to the workflow through an n8n credential or env var,
   not inline in the workflow JSON.

## Live Proof Matrix

Every row is recorded with the redacted request and response bodies, the n8n
execution id where applicable, and the Osaurus UI observation. Rows are
reported as proven / partial / failed; a source-wired control is not proof.

| Row | Action | Required result |
| --- | --- | --- |
| Happy path | `curl -X POST http://localhost:5678/webhook/osaurus-bridge -d '{"text":"Reply with the single word PONG"}'` | Workflow returns the agent's visible text; n8n execution succeeds; Osaurus Activity shows the channel task with the n8n title; audit workbench shows `received → stored → dispatched → agent_replied`; token/s recorded from the task. |
| Session continuity | Second call, same `conversation_id`, "What word did you just say?" | Same `session_id`/`task_id`; answer references the prior turn; Activity shows one reattached conversation. |
| Dedupe | Replay an identical envelope (same `event_id`) | `200 {"status":"duplicate"}`, no new task, no new store row. |
| Verify-before-parse | Wrong secret with a syntactically invalid body | `401 unauthorized`; no activity row; `signature_failures` increments on the card. |
| Rate limit | 5+ rapid wrong-secret attempts | `429 rate_limited` and cooldown; `rate_limited` increments. |
| First contact | Run the workflow with a `conversation_id` / `sender.id` not yet allowlisted | `202 {"status":"rejected","reason":"pending_approval"}`, no dispatch; the n8n card shows "1 waiting for approval"; *Prove it* shows the Allow / Deny row with both ids. Press **Allow** → allowlists updated without a separate Save; re-run → happy path. |
| Deny | Repeat with a second identity and press **Deny** | Row disappears; the next event from that identity returns the bare `sender_not_allowlisted` / `room_not_allowlisted`, no new prompt this session. |
| Fail-closed sender (denied) | `sender.id: "mallory"` after denying it | `202 {"status":"rejected","reason":"sender_not_allowlisted"}`, no dispatch, audit row present. |
| Fail-closed conversation (denied) | `conversation_id: "other-room"` after denying it | `202 rejected`, `reason: room_not_allowlisted`, no dispatch. |
| Remote policy (426) | Switch *Where is your n8n?* to **Another machine on my network**, *Expose to Network* on, policy `secure_channel_required`; POST the envelope to `http://<lan-ip>:1337/channels/n8n/n8n-local/inbound` and GET the poll URL on the LAN IP | Both `426 secure_channel_required`. Toggle **Allow plaintext HTTP from other machines** on, save → same calls return `202`/`200`; toggle off, save → `426` again. Switching back to Docker Desktop hides the toggle and resets the policy. |
| Remote gating | Switch *Where is your n8n?* to **Remote** with no local agent, then with a local agent whose Relay is off | *Pair* shows the `needsBoundAgent`, then `needsRelay` blocker instead of a code; **Enable Relay** in *Who answers?* → once connected the code shows only the relay URL. |
| Loopback exemption | Same payload via `curl` to `127.0.0.1` while policy is `secure_channel_required` **and** *Expose to Network* is on | `202 accepted` (physical loopback is exempt even though `trustLoopback` is off). |
| Docker origin | Same payload from inside `n8n-n8n-1` via `host.docker.internal` while policy is `secure_channel_required` | `202 accepted` on macOS (host forwarder is loopback); record the observed status. |
| Envelope version | `v: 2` | `400 unsupported_envelope_version`. |
| Envelope shape | missing `content` | `400 invalid_payload`. |
| Poll ownership | Poll a `task_id` from another connection/session | `404 task_not_found`. |
| Shared-secret mode | Switch verification to `shared_secret_header`, save, repeat happy path with `X-Osaurus-Channel-Secret` | `202 accepted` and completed poll. |
| Outbound C2 refusal | Enter `http://localhost:5678/webhook/...` as the outbound URL and save | Save is refused inline with the HTTPS/public-host message; `agent-channels.json` is unchanged. |
| Outbound push | Public HTTPS webhook URL (e.g. `ngrok http 5678`) with auto-reply on, pointing at a sink workflow that recomputes the HMAC | n8n Webhook trigger receives the signed envelope; the sink's signature check passes and responds `200 {"id": …}`; Osaurus Outbox / `outbound_sent` reflect it. **PARTIAL** when no public URL is available. |
| Disable | Flip the switch on the n8n card in the channel list off | `403 connection_disabled`; toggle back on restores. |
| Kill switch | Global channel write switch off | Pull mode unaffected (poll still returns output); outbound push (if configured) denied. Covered in-unit by `n8nReplyHandlerIsOnlyInstalledWhenOutboundAndAutoReplyAreConfigured` (`globalWritesDisabled` → `outbound_failed`, no HTTP). Live UI re-proof of the fixed binary is deferred. |

## App-Surface Proof Checklist

| Area | Required proof |
| --- | --- |
| Card | Connection Center shows the n8n card with the correct verification/policy badges and copyable inbound + poll URLs (including the Docker host form). |
| Persistence | After relaunch every field in the sheet matches what was saved; the Keychain secret is present, the JSON file has no secret. |
| Counters | The health block reflects each row above (`inbound_accepted`, `inbound_duplicates`, `inbound_rejected`, `signature_failures`, `rate_limited`, `poll_requests`). |
| Verify incoming event | Pressing the button then firing the workflow resolves with the terminal stage. |
| Diagnostics | `agent_channel_diagnostics` for the connection includes `inbound_ingress` and redacts the secret. |
| Search | Settings search for "n8n" or "webhook" lands on the channel entry. |

## Redaction Check

Before sharing artifacts:

```bash
rg -n "$OSAURUS_N8N_SECRET" /tmp/osaurus-n8n-proof
rg -n 'X-Osaurus-Channel-(Secret|Signature): [^<]' /tmp/osaurus-n8n-proof
```

Both must return nothing. If they find anything, delete the artifact and
re-capture with redaction applied.

## Evidence

Store transcripts, `agent-channels.json`, n8n execution ids and screenshots
under `/tmp/osaurus-n8n-proof/` (never in the repo). The PR report lists the
tested SHA, the model bundle and generation defaults, each matrix row as
proven / partial / failed, token/s for generation rows, and the poll `output`
text verbatim.

## Release Dependencies

- Outbound push to a local n8n cannot be proven without a public HTTPS URL; it
  is reported PARTIAL until a tunnel or hosted n8n is available.
- The `@osaurus/n8n-nodes-osaurus` community node is a separate repository and
  does not gate this channel kind. Install it in n8n under exactly that scoped
  name (Settings → Community nodes → `@osaurus/n8n-nodes-osaurus`).
