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
    always_online: false
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

Do not add `chat:write.public` for release proof. Invite the bot to the
disposable channel instead, so channel membership stays explicit.

Socket Mode setup:

1. Enable Socket Mode in the Slack app settings.
2. Create an app-level token with `connections:write`.
3. Save the app-level token only in the local secret store used by the smoke
   operator. The native configuration stores the Slack bot token under the
   `bot_token` credential reference, the signing secret under
   `signing_secret`, and the Socket Mode app token under `app_token`.
4. Install or reinstall the app after scope changes.
5. Invite the bot to the read and write smoke channels.

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
  Signing secret is also saved when signed HTTP event proof is in scope.
- **Test Connection** returns bot identity and the configured workspace/team is
  allowlisted.
- At least one readable channel id is allowlisted.
- At least one authorized sender id is allowlisted.
- Send one inbound Socket Mode message from an authorized sender and confirm it
  appears in the local Agent Channel inbox.
- Send one inbound message from an unauthorized sender in the same channel and
  confirm it is ignored.
- If writes are enabled, send one confirmed message to a write-allowlisted
  channel.
- Restart Osaurus and confirm transport health and configuration persist.

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
