# Slack and Telegram Agent Channel Setup

This setup guide is for disposable release-proof workspaces and chats. Keep
provider credentials short-lived, scoped to test rooms, and outside committed
configuration files.

## Transport Position

Target desktop transports:

- Slack: Socket Mode is the intended desktop receive transport because a local
  desktop app should not require a public HTTPS callback URL for routine smoke
  proof. Native Slack receive starts when an app token, readable channels, and
  authorized sender IDs are configured.
- Telegram: Bot API long-poll is the primary desktop receive transport because
  a local desktop app can poll without public ingress.

Advanced or future transports:

- Slack Events API public webhooks are advanced/future for this release proof.
  They require public HTTPS ingress and Slack request-signature verification.
- Telegram public webhooks are advanced/future for this release proof. They
  require a public HTTPS endpoint and `X-Telegram-Bot-Api-Secret-Token`
  verification.

## Native Channels vs. the Legacy Telegram Plugin

The native Telegram Agent Channel and the legacy Telegram plugin are separate
paths:

| Path | Where it is configured | Receive path | Message store | Review status |
| --- | --- | --- | --- | --- |
| Native Telegram Agent Channel | Settings -> Channels -> Telegram | Bot API long polling, with public webhooks reserved for future proof | Agent Channel message store | New replacement path; use this guide for live proof |
| Legacy Telegram plugin | Plugin installation/configuration flow | Plugin-owned route/webhook behavior | Plugin-owned SQLite database | Keep separate until native Channels are proven |

If feedback says "I put in the Telegram token and nothing happened," first
confirm which path the user configured. A report from the legacy Telegram plugin
does not prove a native Agent Channel bug, and a native Agent Channel fix should
not be claimed as a plugin fix unless the plugin path was tested too.

Deprecation should be staged, not abrupt:

1. Prove native Telegram Agent Channels with the live checklist below.
2. Document the migration path from plugin configuration to native channel
   settings.
3. Keep the plugin available for at least one overlap window.
4. Mark the plugin deprecated only after native receive, read, write, restart,
   and group authorization proof is complete.

## Slack App Manifest

Create a disposable Slack app for a disposable workspace. Use a dedicated bot
token and invite the bot only to the rooms used by the smoke run.

Minimal manifest shape:

```yaml
display_information:
  name: Osaurus Channel Smoke
features:
  bot_user:
    display_name: osaurus-smoke
    always_online: true
oauth_config:
  scopes:
    bot:
      - app_mentions:read
      - channels:history
      - channels:read
      - chat:write
      - groups:history
      - groups:read
      - im:history
      - im:read
      - mpim:history
      - mpim:read
      - users:read
settings:
  event_subscriptions:
    bot_events:
      - app_mention
      - message.channels
      - message.groups
      - message.im
      - message.mpim
  interactivity:
    is_enabled: false
  org_deploy_enabled: false
  socket_mode_enabled: true
```

Scope notes:

| Scope | Why it is needed |
| --- | --- |
| `chat:write` | Sends only after `confirm_send: true` and explicit smoke approval. |
| `channels:read`, `groups:read`, `im:read`, `mpim:read` | Lists rooms/chats the bot can inspect. |
| `channels:history`, `groups:history`, `im:history`, `mpim:history` | Reads recent messages for allowlisted rooms. |
| `app_mentions:read` | Receives app mentions for Socket Mode/event proof. |
| `users:read` | Populates the authorized-sender picker with workspace people. |

Do not add `chat:write.public` for release proof. Invite the bot to the
disposable channel instead, so channel membership stays explicit.

Presence note: `features.bot_user.always_online: true` is what shows the bot
with a green presence dot. Slack has no runtime presence API for bot tokens,
so this static manifest flag is the only supported mechanism. Existing Slack
apps created from an older manifest must reapply the updated manifest on the
App Manifest page for the change to take effect.

Guided setup (matches the numbered steps in Settings -> Channels -> Slack):

1. **Create the Slack app.** Open [api.slack.com/apps](https://api.slack.com/apps),
   choose "Create New App" -> "From a manifest", and paste the manifest copied
   from the sheet. The manifest already enables Socket Mode and the message
   event subscriptions. There is **no webhook**: native Slack receive never
   asks for a Request URL, public HTTPS ingress, or an Events API endpoint.
2. **Install the app and paste the Bot Token.** Use "Install App" in the Slack
   app settings, then paste the `xoxb-` Bot User OAuth Token. Reinstall after
   any scope change.
3. **Generate the App-Level Token.** Under "Basic Information" ->
   "App-Level Tokens", generate an `xapp-` token with the `connections:write`
   scope and paste it into the App Token field. This token is **required to
   receive messages** — it is what powers the outgoing Socket Mode connection.
   Test Connection validates it against `apps.connections.open` and reports
   an invalid token or missing scope explicitly.
4. **Choose channels and people.** Use **Load from Slack** to fetch the
   authenticated workspace, visible conversations, and workspace users. Select
   Read and Write independently for each joined channel (invite the bot to the
   channel first), then select the users authorized to trigger inbound
   handling. Discovery never grants access by itself: only the saved
   selections become allowlists. If workspace policy withholds `users:read` or
   conversation-list scopes, the sheet shows the missing scope and keeps the
   Advanced manual-ID fields available.
5. **Send incoming messages to an agent.** Enable dispatch and pick the target
   agent. Mention policy, thread continuation, and automatic replies are
   configured here.
6. **Verify an incoming message.** Press **Verify incoming message**, then send
   the suggested test message (for example `@your-slack-bot hello`) from an
   authorized sender in a readable channel. Mention the **Slack bot user**,
   not the Osaurus agent name. The sheet shows each stage the event reaches —
   received, stored, dispatched, replied — or the exact boundary that stopped
   it (unauthorized sender, unreadable channel, mention required, unavailable
   agent, and so on).

The signing secret lives under Advanced and is **not part of the native Slack
path**: it only verifies Slack HTTP (Events API) requests and is retained for
future webhook compatibility. Saving it never enables receive.

Saving with dispatch enabled keeps the sheet open and lists the exact blockers
whenever receive cannot actually run (missing app token, empty allowlists,
missing agent, rejected token). Diagnostics also warn when multiple Osaurus
instances are running: Slack delivers each Socket Mode envelope to only one
connection, so a forgotten Xcode debug build can silently consume the events
the installed app is waiting for.

Use **Add another Slack workspace** for each additional installation. Supply
that workspace's bot token and optional Socket Mode app token, load its choices,
select its channels and authorized senders, then save. Tokens remain separate
in Keychain and each workspace with an app token runs an independent Socket Mode
connection.

Non-secret native configuration shape:

```json
{
  "configuredTeamIds": ["T01234567"],
  "readableChannelIds": ["C012READ"],
  "writableChannelIds": ["C012WRITE"],
  "senderAllowlist": ["U012USER"],
  "writeEnabled": false,
  "defaultReadLimit": 25,
  "allowBroadcastMentions": false
}
```

Set `writeEnabled` to true only for the approved-send pass, keep
`allowBroadcastMentions` false unless a separate risk review says otherwise,
and keep `senderAllowlist` explicit so group/channel inbound handling only
responds to authorized Slack users.

## Telegram BotFather Setup

Use BotFather to create a disposable bot:

1. Send `/newbot` to BotFather and save the bot token in the local credential
   store only.
2. Set a display name that clearly identifies the disposable smoke bot.
3. Add the bot to one disposable read chat and one disposable write chat.
4. Send one harmless message in each chat so the bot can observe the chat id.
5. Use numeric chat ids for private groups and any chat where Telegram may not
   include a username. `@username` ids are acceptable only when Telegram sends
   the username in updates.
6. If the bot must receive ordinary group messages, use BotFather `/setprivacy`
   for the disposable bot and disable privacy only in the smoke environment.
7. Use `getUpdates` long-poll for desktop proof. If a webhook was configured
   during experimentation, delete it before long-poll proof.

Before enabling long polling, send the bot a message and use **Load from
Telegram** in settings. Osaurus previews pending updates without advancing the
update cursor and offers the observed chats and human senders as explicit Read,
Write, and Allow choices. Manual IDs remain available when Telegram has no
pending updates.

Saving a bot token only proves that Osaurus can store credentials. It does not
start Telegram receive by itself. For new messages to arrive in the local inbox,
all of these must be true:

- `Store Incoming Messages` is enabled.
- `Enable Long Polling` is enabled.
- At least one readable chat id is allowlisted.
- At least one authorized sender id is allowlisted.
- No Telegram webhook is registered for the same bot token.

If a user reports that they pasted a token and nothing happened, open Telegram
settings, press **Test Connection**, and follow the setup blockers shown there.
Use **Check Webhook** if long polling reports a conflict or no updates arrive
after the allowlists are complete.

The diagnostics field `receive_ready` is the authoritative signal that the local
inbox should fill from Telegram. A long-poll transport can still start and then
report conflict health if Telegram rejects `getUpdates` because a webhook or
another consumer owns the same bot token.

## Live Proof Checklist

Run this checklist in a disposable workspace/chat before telling a maintainer
the channel is ready for user testing:

### Telegram

- Bot token saved and **Test Connection** returns bot identity.
- `Store Incoming Messages` is enabled.
- `Enable Long Polling` is enabled.
- At least one readable chat id is allowlisted.
- At least one authorized sender id is allowlisted.
- No webhook is registered for the bot token.
- Send one inbound message from an authorized sender and confirm it appears in
  the local Agent Channel inbox.
- Send one inbound message from an unauthorized sender in the same group and
  confirm it is ignored.
- If writes are enabled, send one confirmed message to a write-allowlisted chat.
- Restart Osaurus and confirm configuration and stored messages persist.

### Slack

- Bot token and Socket Mode app token are saved for local desktop receive proof.
  No signing secret or webhook is required for the native path; save a signing
  secret only when out-of-scope signed HTTP event proof is planned.
- **Test Connection** returns bot identity, validates the app token through
  `apps.connections.open`, and the configured workspace/team is allowlisted.
- At least one readable channel id is allowlisted.
- At least one authorized sender id is allowlisted.
- Only one Osaurus instance is running (diagnostics warn about duplicates).
- Use **Verify incoming message** with one inbound Socket Mode message from an
  authorized sender and confirm the stages reach stored/dispatched and it
  appears in the local Agent Channel inbox.
- Send one inbound message from an unauthorized sender in the same channel and
  confirm it is ignored.
- If writes are enabled, send one confirmed message to a write-allowlisted
  channel.
- Edit and delete a disposable bot-authored message, add and remove a reaction,
  and confirm attachment metadata is returned by message reads.
- For multiple workspaces, prove one read and one confirmed write in each and
  verify the action routes to the correct workspace.
- Restart Osaurus and confirm transport health and configuration persist.

### Proactive posting (outbound destinations)

Proactive posting needs no separate setup. Once a channel has a saved
credential, write access to at least one room (`writeEnabled` plus a
write-allowlisted room id), and inbound dispatch enabled, Osaurus derives an
automatic **Ask first** posting destination for each writable room × answering
agent. They appear under Settings → Channels → Agent Posting (and per agent
under Channel Posting) with an "Automatic" badge.

Outbound spot check, after the inbound checklist above passes:

- Confirm the derived destination is listed for the answering agent.
- Ask the agent in chat to post to the room; approve the queued message from
  the outbox (Ask first is the default — nothing sends without approval).
- Confirm the message arrives in the room, and that the outbox row moves to
  sent.
- Remove the room from the write allowlist and confirm the destination
  disappears and any still-queued approval for it is refused.

Auto-send is opt-in per destination and never the derived default; see
[AGENT_CHANNEL_SECURITY.md](AGENT_CHANNEL_SECURITY.md) for the write gates and
[AGENT_CHANNELS.md](AGENT_CHANNELS.md) for the full outbound flow.

Webhook setup is advanced/future. When it is used, set a random webhook secret
token and verify the `X-Telegram-Bot-Api-Secret-Token` header before decoding
message text.

Non-secret native configuration shape:

```json
{
  "readableChatIds": ["-100111222333"],
  "writableChatIds": ["-100444555666"],
  "senderAllowlist": ["123456789"],
  "writeEnabled": false,
  "defaultReadLimit": 25,
  "ignoreSelfMessages": true,
  "ignoreBotMessages": true,
  "receiveStorageEnabled": true,
  "longPollingEnabled": true,
  "longPollingLimit": 100,
  "longPollingTimeoutSeconds": 20
}
```

`longPollingEnabled` defaults to `false`; the example above turns it on because
smoke proof needs the receive path. `receiveStorageEnabled` defaults to `true`.

Telegram reads come from the local Agent Channel message store. Populate the
store through the long-poll or webhook receive path before proving
`read_messages`/`search_messages`. With long polling left at its default
(disabled) and no webhook ingress wired, a fresh Telegram setup returns empty
read/search results: nothing fetches new updates into the store. Enable
"Enable Long Polling" in Telegram settings (with a saved token and sender
allowlist) to fill the inbox. Long polling starts from the app lifecycle when
both `receiveStorageEnabled` and `longPollingEnabled` are true; Telegram
returns a 409 conflict if another consumer (a registered webhook or a second
poller) is consuming the same bot token. Use "Check Webhook" / "Remove
Webhook" in Telegram settings to detect and clear a leftover webhook.

## Reference Links

- [Slack app manifests](https://api.slack.com/reference/manifests)
- [Slack Socket Mode](https://api.slack.com/apis/socket-mode)
- [Slack OAuth scopes](https://api.slack.com/scopes)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [Telegram BotFather overview](https://core.telegram.org/bots#botfather)
