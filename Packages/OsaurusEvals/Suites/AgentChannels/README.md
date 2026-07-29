# Agent Channels Eval Suite

Deterministic, model-free policy pins over the REAL Slack/Telegram
connection services. The harness support the old docs-only checklist was
waiting for now exists: `AgentChannelEvalHarness` (OsaurusCore) seeds
isolated connection config, injects fake provider clients, and scores the
decision plus the message-store side effects. No network, no model, no
keychain — these rows join the token-free CI-safe set.

## Cases

| Case | Scenario | Pins |
| --- | --- | --- |
| `agent_channels.unauthorized-room-read` | `unauthorized_room_read` | Read against a non-allowlisted room is rejected; no store row. |
| `agent_channels.unauthorized-sender-denied` | `sender_allowlist` | Allowed sender stores a snapshot; denied sender → `sender_not_allowlisted`, stores nothing. |
| `agent_channels.no-unapproved-send` | `unconfirmed_send` | Send without `confirm_send: true` fails before provider dispatch (fake client records zero sends). |
| `agent_channels.external-mcp-denial` | `mcp_denial` | Every `agent_channel_*` tool is externally denied (`/mcp/tools` omission, `/mcp/call` 403). |
| `agent_channels.proactive-publish-policy` | `proactive_publish` | No binding → no publish capability/prompt payload; external and channel-triggered runs denied; autonomous scheduled runs send only to their own binding; repeated `intent_key` yields one provider write; draft/unattended-confirm never silently send; ambiguous provider failures park as `delivery_unknown` (replays never resend); approvals refuse a binding repointed since queuing (`binding_route_changed`); zero-config derived destinations are confirm-only, surface in the prompt, queue unattended sends, refuse queued approvals with `binding_removed` once the room leaves the write allowlist, and are suppressed by stored customizations. |

## Run

```bash
make evals EVALS_SUITE=AgentChannels
```

## Live proof (complementary, not replaced)

The no-secret smoke script and the disposable-room runbook remain the
release-proof lane for REAL provider behavior:

```bash
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

See `docs/AGENT_CHANNELS_SLACK_TELEGRAM_SETUP.md` and
`docs/CHANNEL_RELEASE_RUNBOOK_SLACK_TELEGRAM.md`.
