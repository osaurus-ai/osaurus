# Agent Channels Eval Checklist

This is a docs-only checklist for Slack and Telegram Agent Channel release
proof. Runnable JSON cases are intentionally deferred because the current eval
harness does not provide a fixture hook to seed native Slack/Telegram
connection config, inject fake provider clients, or pre-populate the Agent
Channel message store without adding harness/source wiring outside this release
asset task.

## Deterministic Cases To Add When Harness Support Exists

| Case | Fixture setup | Expected result |
| --- | --- | --- |
| `agent_channels.unauthorized-room` | Seed native Slack/Telegram connections with one readable room/chat and one denied room/chat. | `agent_channel_read_messages` against denied targets returns rejected/not-allowlisted and no store row is written. |
| `agent_channels.unauthorized-sender` | Seed Slack/Telegram sender allowlists and feed one allowed event plus one denied event per provider. | Allowed sender stores one snapshot; denied sender returns `sender_not_allowlisted` and stores nothing. |
| `agent_channels.no-unapproved-send` | Seed writable destinations and fake provider send clients. | `confirm_send: false` or omitted returns invalid-args before provider dispatch; provider sent count stays zero. |
| `agent_channels.external-mcp-denial` | Start the local MCP test surface with Agent Channel tools registered. | `/mcp/tools` omits `agent_channel_*`; `/mcp/call` returns `403 tool_not_exposable`. |

## Proof To Run Now

Use the no-secret smoke script:

```bash
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

For focused source-backed fixtures:

```bash
OSAURUS_CHANNEL_SMOKE_RUN_CORE_FIXTURES=1 \
scripts/live-proof/run-slack-telegram-channel-smoke.sh
```

For provider setup and live disposable-room proof, follow
`docs/AGENT_CHANNELS_SLACK_TELEGRAM_SETUP.md` and
`docs/CHANNEL_RELEASE_RUNBOOK_SLACK_TELEGRAM.md`.
