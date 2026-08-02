---
title: Agent Channels
summary: Let agents read and post on Discord, Slack, Telegram, and iMessage — with strict allowlists.
order: 150
---

# Agent Channels

Channels (Beta) connect agents to your messaging platforms: Discord, Slack, Telegram, and iMessage (macOS), plus custom HTTP channels. Agents can read, draft, and — only with your consent — send messages.

## Setup

- Settings → Channels: add a connection per platform with native credential sheets (tokens go to the Keychain, never JSON).
- Slack uses a bot token with Socket Mode; Telegram uses a bot via long polling; Discord polls REST (plus Gateway for presence); iMessage uses a local helper downloaded from settings.
- iMessage needs Full Disk Access to read and Messages Automation consent to send.

## Safety model

- Inbound is deny-by-default: only allowlisted spaces/rooms/senders reach an agent; bots and self are ignored unless explicitly allowed.
- Writes require the agent to pass `confirm_send: true` and the room to be on a write allowlist; broadcast mentions (@channel and similar) are blocked unless you allow them.
- Channel tools work only inside the app — external HTTP/MCP callers are denied.

## Proactive posting

- Agents → agent → Automation → Channel Posting plus Settings → Channels → Agent Posting.
- Modes: Off / Draft (writes land in an Outbox for review) / Confirm (asks each time) / Autonomous (sends directly — use sparingly).
- The Outbox (Settings → Channels → Outbox) holds drafts with mark-sent / retry / discard.

## Diagnostics

Each connection has a diagnostics view (connection state, recent events). Combine channels with Schedules for recurring digests posted as drafts.
