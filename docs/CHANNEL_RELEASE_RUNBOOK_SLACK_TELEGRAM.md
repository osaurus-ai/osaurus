# Slack and Telegram Channel Release Runbook

This runbook proves service-level readiness for native Slack and Telegram Agent
Channels without requiring CI secrets. It is intentionally scoped to disposable
rooms/chats and app-surface behavior.

## Fast Fixture Pass

Run without secrets:

```bash
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

Optional focused Swift fixture pass:

```bash
OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1 \
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

Artifacts are written under `build/live-proof/channel-smoke/<timestamp>/`:

- `channel-smoke-proof.md`
- `channel-smoke-proof.json`
- `channel-smoke-proof.log`

The script redacts known Slack and Telegram token env values and token-shaped
strings before writing artifacts.

## Live Provider Pass

Use disposable credentials and no-send mode first:

```bash
OSAURUS_CHANNEL_SMOKE_MODE=live \
OSAURUS_SLACK_BOT_TOKEN=xoxb-... \
OSAURUS_SLACK_TEAM_ID=T... \
OSAURUS_SLACK_READ_CHANNEL_ID=C... \
OSAURUS_SLACK_WRITE_CHANNEL_ID=C... \
OSAURUS_SLACK_DENIED_CHANNEL_ID=C... \
OSAURUS_TELEGRAM_BOT_TOKEN=123456:... \
OSAURUS_TELEGRAM_READ_CHAT_ID=-100111222333 \
OSAURUS_TELEGRAM_WRITE_CHAT_ID=-100444555666 \
OSAURUS_TELEGRAM_DENIED_CHAT_ID=-100999888777 \
OSAURUS_TELEGRAM_ALLOWED_SENDER_ID=123456789 \
OSAURUS_TELEGRAM_DENIED_SENDER_ID=987654321 \
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

Run the single approved-send pass only after the disposable write destination
has been checked:

```bash
OSAURUS_CHANNEL_SMOKE_MODE=live \
OSAURUS_CHANNEL_SMOKE_APPROVE_SEND=1 \
OSAURUS_CHANNEL_SMOKE_CONFIRM_SEND=true \
OSAURUS_CHANNEL_SMOKE_TEST_MESSAGE="approved disposable channel smoke" \
OSAURUS_SLACK_BOT_TOKEN=xoxb-... \
OSAURUS_SLACK_TEAM_ID=T... \
OSAURUS_SLACK_READ_CHANNEL_ID=C... \
OSAURUS_SLACK_WRITE_CHANNEL_ID=C... \
OSAURUS_TELEGRAM_BOT_TOKEN=123456:... \
OSAURUS_TELEGRAM_READ_CHAT_ID=-100111222333 \
OSAURUS_TELEGRAM_WRITE_CHAT_ID=-100444555666 \
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

## App-Surface Proof Checklist

Record each item in the release artifact:

| Area | Required proof |
| --- | --- |
| Connection listing | `agent_channel_list_connections` shows Slack and Telegram with redacted credential state, action policy, read/write allowlists, and confirmation metadata. |
| Diagnostics | `agent_channel_diagnostics` reports missing credentials, disabled writes, denied rooms/chats, and provider auth failures without raw secrets. |
| List rooms/chats | Slack lists rooms from the disposable workspace; Telegram lists configured chats. |
| Read/store | Slack read/search stores redacted message snapshots; Telegram read/search returns from the local message store after long-poll ingest. |
| Draft no-send | `agent_channel_draft_message` returns a local preview with `requires_send_confirmation` and no provider dispatch. |
| No unapproved send | `agent_channel_send_message` and `agent_channel_reply_thread` with omitted or false `confirm_send` fail before provider dispatch. |
| Approved send | A single disposable send succeeds only when the operator explicitly sets the approval flag and the tool args include `confirm_send: true`. |
| Unauthorized room/chat | Slack denied channel and Telegram denied chat return rejected/not-allowlisted results and do not write message snapshots. |
| Unauthorized user | Slack and Telegram denied senders return `sender_not_allowlisted` before storage or dispatch. |
| External MCP denial | `/mcp/tools` does not expose `agent_channel_*`, `/mcp/call` returns `403 tool_not_exposable`, and non-loopback dispatch binds the external-surface denial. |

## Transport Proof

Primary desktop proof uses:

- Slack Socket Mode for inbound desktop receive.
- Telegram long-poll for inbound desktop receive.

Public webhooks are advanced/future for both providers. If a webhook path is
tested anyway, verify the provider secret/signature before parsing content and
record why public ingress was needed.

## Redaction Check

Before sharing artifacts:

```bash
rg -n 'xox[baprs]-|xapp-|[0-9]{5,}:[A-Za-z0-9_-]{20,}' build/live-proof/channel-smoke
```

The command should return no raw token values. If it finds anything, delete the
artifact and re-run with the script redaction updated.

## Release Dependencies

These are dependencies, not part of this proof-asset change:

- Public webhook receiver hardening if the release later promotes webhook
  ingress instead of the primary desktop transports above.
