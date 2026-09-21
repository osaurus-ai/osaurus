# Apple Apps (built-in tools)

Osaurus ships native tools for **Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps & Location, Music, and Shortcuts**. They live in `Packages/OsaurusCore/AppleApps/`, need no plugin, and are turned on **per custom agent**. Nothing is on by default.

The former `osaurus.calendar`, `osaurus.reminders`, `osaurus.contacts`, `osaurus.notes`, `osaurus.mail`, `osaurus.messages`, `osaurus.maps`, and `osaurus.music` plugins from [osaurus-tools](https://github.com/osaurus-ai/osaurus-tools) are superseded by these built-ins (see [Migration](#migration-from-the-plugins)). There is no Weather tool; WeatherKit was removed.

## Turning an app on

Agents → *your custom agent* → **Abilities → Tools**. Each Apple app is a group in the tool picker, listed above the plugin and MCP groups. The group's master checkbox — or any row switch, marked **Per app** — flips all of that app's tools together; individual tools are not toggled separately. The Create Agent sheet's **Customize…** picker takes the same set.

Turning an app on asks macOS for its permission right away:

| App | macOS grant asked on enable | Notes |
|---|---|---|
| Calendar | Calendars (Full Access) | EventKit |
| Reminders | Reminders (Full Access) | EventKit |
| Contacts | Contacts | Contacts.framework |
| Notes | Automation → Notes | AppleScript |
| Mail | Automation → Mail | AppleScript |
| Messages | Full Disk Access **and** Automation → Messages | Reading is `chat.db`; sending is AppleScript. Full Disk Access has no prompt — grant it in System Settings. |
| Maps & Location | Location | `location_current` waits for the dialog (up to 120 s) instead of failing while it is on screen |
| Music | Automation → Music | AppleScript |
| Shortcuts | none | `/usr/bin/shortcuts` CLI; individual shortcuts may prompt on their own |

A denied grant does **not** flip the switch back. The group header shows a **Permission needed** badge; clicking it re-asks for any grant macOS can still prompt for and then opens the System Settings pane for whatever is still missing (Full Disk Access, or an Automation grant that was previously denied). The same grants are listed under Management → Permissions.

## The off switch is authoritative

When an app is off for an agent, that agent cannot reach its tools by any path:

- The system-prompt composer strips the app's tools in **both** automatic and manual tool modes. Manual picks and session-loaded tools do not bypass it.
- The manual picker never stores Apple tool names; `AgentManager` strips them on save.
- `capabilities_discover` never returns Apple tools, and `capabilities_load` refuses them with a message naming the switch to flip — there is no discover → load loop.
- `ToolRegistry.execute` refuses an Apple tool unless the *current* agent has the owning app enabled. A call with no agent context is refused.
- All Apple tool names are on the external-surface deny list: hidden from `GET /mcp/tools`, `403 tool_not_exposable` from `POST /mcp/call`, and rejected in `/agents/{id}/run`.
- MCP providers, plugins, and sandbox tools cannot register a tool whose name collides with a built-in Apple tool; the registration is logged and dropped.

## Approval

Writes follow the normal per-tool permission policy (`ask` by default; "Allow for this run" covers the rest of the turn). Two classes always show an approval card, every call, regardless of that policy:

- **Sending**: `messages_send`, and `mail_compose` / `mail_reply` when `send: true`.
- **Deleting**: `calendar_delete_event` and `reminders_delete`.

`notes_open` activates Notes and steals focus, so it is treated as a write; the other `*_open` tools only open a deep link. `music_play`, `music_playback`, and `music_set_volume` are writes.

Enabling Mail, Messages, or Shortcuts on an agent adds a risk line to the `osaurus_config` plan card: these apps can act on the user's behalf (send mail or messages, run arbitrary shortcuts).

## Tool families

| App | Tools |
|---|---|
| Calendar | `calendar_list`, `calendar_events`, `calendar_create_event`, `calendar_update_event`, `calendar_delete_event`, `calendar_open_event` |
| Reminders | `reminders_lists`, `reminders_fetch`, `reminders_create`, `reminders_update`, `reminders_complete`, `reminders_delete`, `reminders_open` |
| Contacts | `contacts_me`, `contacts_search`, `contacts_list`, `contacts_get`, `contacts_create`, `contacts_update`, `contacts_open` |
| Notes | `notes_folders`, `notes_list`, `notes_search`, `notes_read`, `notes_create`, `notes_append`, `notes_open` |
| Mail | `mail_mailboxes`, `mail_list`, `mail_read`, `mail_search`, `mail_compose`, `mail_reply`, `mail_move`, `mail_set_status`, `mail_thread` |
| Messages | `messages_conversations`, `messages_read`, `messages_unread`, `messages_search`, `messages_send` |
| Maps & Location | `location_current`, `location_geocode`, `location_reverse_geocode`, `maps_search`, `maps_explore`, `maps_directions`, `maps_eta`, `maps_open` |
| Music | `music_now_playing`, `music_playback`, `music_set_volume`, `music_playlists`, `music_search`, `music_play` |
| Shortcuts | `shortcuts_list`, `shortcuts_run` |

`AppleApp.toolNames` in `AppleApp.swift` is the source of truth; the composer strip, the execution gate, and the deny list all derive from it.

### Behavior worth knowing

- **Dates** in and out are ISO 8601 with the local offset. Bare dates (`2026-09-21`) are accepted; invalid calendar dates (Feb 31) are rejected rather than rolled over. All-day events use the inclusive convention — `end` is the last day, not the day after.
- **Clearing a field**: pass JSON `null` for `location` / `notes` / `url` (Calendar) and `notes` / `url` / `due` (Reminders). Empty strings are stripped by the validator and mean "leave unchanged".
- **Recurring events**: `calendar_update_event` without `occurrence_start` or `span` defaults to `future_events` and says so in a warning; alarms are clamped to 0 … 4 weeks and reported.
- **Calendar range**: EventKit caps a single query at four years; `calendar_events` reports `end_clamped` and the effective end when that applies.
- **Notes with attachments**: `notes_append` refuses (the AppleScript body setter would drop the attachments) and names them; use `notes_create` or `notes_open`.
- **Mail ids** from `mail_list` / `mail_search` are stable within Mail and resolve with `first message of <mailbox> whose id is …`; mailbox paths are `Account/Folder/Subfolder` with `\/` for a literal slash.
- **Messages search** decodes `attributedBody` in Swift, so recent messages match; tapbacks and system rows are filtered and attachment-only messages read `[attachment]`. `messages_send` verifies delivery in `chat.db` before it will fall back to SMS and never re-sends on an unknown outcome.
- **Shortcuts output** is capped at 1 MiB (`truncated: true`), binary output is reported as such, and cancelling the chat sends SIGTERM then SIGKILL to the running shortcut. Shortcuts that show "Ask Each Time" or "Show Result" sheets block the CLI.
- **Location**: `maps_search` with `near` restricts results to that region and sorts them by distance. Coordinates are range-checked.
- **Music**: `shuffle` on `music_play` only changes Music.app's shuffle setting when you pass it.
- **Errors** are typed `ToolEnvelope`s: `permission_denied` carries the missing grant and a `system_settings_url`; `not_found`, `invalid_args`, `timeout`, and `unavailable` (with a retryable hint) are used consistently across apps. A write that times out is reported as outcome-unknown rather than failed.

## The Orchestrator

The Default agent has no Apple app groups in its picker and never calls these tools (`orchestratorExcludedToolNames`). It manages them on custom agents:

- `osaurus_inspect list agents` includes `apple_apps` per agent, so it can pick the right agent to hand a task to.
- `osaurus_config` writes `capabilities.apple_apps` on an agent (plan → approval card → apply) and can provision a new agent with apps in the same call.

Ask it "give my Mail agent access to Calendar too" or "make a Personal Organizer agent with Calendar and Reminders" and it will do exactly that, then delegate.

## Declarative configuration

`apple_apps` is a string list under an agent's `capabilities`. The full list **replaces** the set; `[]` turns every app off. Values are the raw ids `calendar`, `reminders`, `contacts`, `notes`, `mail`, `messages`, `maps`, `music`, `shortcuts` (case-insensitive; `location`, `imessage`, `apple notes`, `apple music` are accepted aliases).

```yaml
agents:
  - name: Personal Organizer
    capabilities:
      tools_enabled: true
      apple_apps: [calendar, reminders, contacts]
```

`osaurus_inspect describe agent` and the exporter include the same field. See [SHARED_CONFIGURATION_GUIDE.md](SHARED_CONFIGURATION_GUIDE.md) and `docs/examples/osaurus-config.sample.*`.

## Migration from the plugins

On first launch after upgrading, `AppleAppsPluginMigration` runs once (marker in `~/.osaurus/config/apple-apps.json`):

1. It scans `Tools/` for folders of the superseded Apple plugins that are actually **installed**. Only those plugins' legacy tool names are considered — a Slack plugin's `send_message` or a Spotify plugin's `play` is never touched.
2. For each custom agent whose manual tool allowlist names one of those legacy tools, the legacy names are **removed** from the allowlist and the owning Apple app is **enabled** on the agent. `search_messages` maps to Messages when the Messages plugin is installed, otherwise to Mail.
3. The marker is written only after every agent has been persisted.
4. If superseded Apple plugin folders are present, a one-time toast points to Agents → Abilities → Tools → Apple Apps.

Installed copies of the superseded plugins are skipped at load (`PluginManager.excludeSupersededPlugins`); their marketplace cards show a "Built into Osaurus" banner that links to the native settings. Uninstall them when you are ready.

## Files

- `Packages/OsaurusCore/AppleApps/AppleApp.swift` — enum, display metadata, permissions, tool names, legacy plugin map.
- `Packages/OsaurusCore/AppleApps/Support/` — `AppleToolBase` (argument parsing, typed envelopes), `AppleScriptBridge`, `AppleServiceQueue` (one serial queue per framework-backed service), `AppleDateParsing`, `AppleSchema`, `AppleAlarms`.
- `Packages/OsaurusCore/AppleApps/<App>/` — `<App>Service.swift` (framework/AppleScript/SQLite/CLI) and `<App>Tools.swift` (schemas and tool bodies).
- `Packages/OsaurusCore/AppleApps/AppleAppsPluginMigration.swift` — the one-time migration and notice.
- Gating: `Services/Chat/SystemPromptComposer.swift`, `Managers/AgentManager.swift`, `Tools/ToolRegistry.swift`, `Tools/CapabilityTools.swift`.
- Tests: `Packages/OsaurusCore/Tests/AppleApps/`.
