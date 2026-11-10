# Upgrading from Osaurus Classic (0.25.x) to Osaurus 1.0

What an in-place update (Sparkle, same `com.dinoki.osaurus` app and
`~/.osaurus` data) changes for someone on Osaurus Classic, and what going back
costs. Use it for release notes and support answers. The details below were
verified against Classic 0.25.33.

## Who gets 1.0

Two products ship from this repository (see [RELEASING.md](RELEASING.md)):

- **Osaurus 1.x** is what new downloads, Homebrew, and the website install.
  It updates from `appcast-next.xml`.
- **Osaurus Classic** (0.25.N) gets fixes only and updates from
  `appcast.xml`.

A Classic user is offered 1.0 only after turning on **Beta Updates** in
Settings → General. Sparkle asks before installing it. Everyone else stays on
Classic until Classic support ends.

## Carries over unchanged

- Chats, agents, models, providers, MCP servers, plugins, and settings.
- Keychain secrets. Service names, the account master key
  (`com.osaurus.account`), and the storage key (`com.osaurus.storage`) are
  the same. `CredentialMigration` copies legacy secrets into the new
  credential store (the Vault) and deletes nothing. With the same Developer
  ID there is no Keychain prompt.
- Databases. Chat history moves from schema 24 to 26 (two added columns);
  Classic opens a newer stamp. Memory and Knowledge schemas are unchanged.
- Schedules, watchers, and channel inbound routes. `EventMigration` copies
  them into `events/` once, as automations, and leaves the originals.
- Onboarding. Someone who finished it on any build since 0.9.7 does not see
  it again, and no starter teammates or default workflows are added to
  their library (**Create starter agents** in Agents → Delegation adds the
  team on request). What's New is gone.
- A custom theme that was active becomes Light or Dark to match it. Custom
  themes are gone in 1.0: appearance is System, Light or Dark.

## Changes on first use

- **Sandbox is rebuilt.** The first start after updating downloads a new
  init filesystem (about 64 MiB, so it needs a connection) and builds
  per-agent environments, briefly using about 8 GiB of extra disk.
  Packages installed inside the old sandbox (apk, pip, npm) must be
  reinstalled. Files in the sandbox workspace are kept; loose files at the
  workspace root move to `shared/`. If that first start fails, the old
  sandbox disk is kept so it can be retried.
- **LAN pairing.** 1.0 no longer advertises `_osaurus._tcp` over Bonjour and
  drops `GET /pair/challenge` and `POST /pair`. Older iPhone and Mac builds
  that pair over those cannot find or pair with this Mac. Existing access
  keys keep working until they expire or are revoked. The iPhone app's
  6-digit pairing is kept for one release while the iPhone moves to Sync
  ([MOBILE_PROTOCOL.md](MOBILE_PROTOCOL.md)).
- **Settings moved.** Many Settings pages were renamed or regrouped (Keys is
  **Vault**, Schedules and Watchers are **Automations**, Sync is
  **Devices**, and so on). Old names still find the new page in Settings
  search; the full list is in the in-app Settings guide
  (`Packages/OsaurusCore/Resources/Guide/guide-settings.md`, "Older names
  still resolve").

## Going back to Classic

Sparkle never downgrades, and turning Beta Updates off on 1.x only stops
1.x betas. Going back means reinstalling the latest Classic DMG (a `0.25.N`
release on the [Releases](https://github.com/osaurus-ai/osaurus/releases)
page; Classic is never marked Latest). After that:

- Secrets added, edited, or deleted after the update are not seen; Classic
  reads the pre-update Keychain items.
- Pending self-schedules and run history are empty. Their tables were
  renamed to `agent_runs_legacy` and `agent_next_run_legacy`.
- Workflows and automations created in 1.0 do not run; Classic has no reader
  for them.
- Saving an agent, a remote agent, or the sandbox settings in Classic drops
  the fields it doesn't know. 1.0 keeps a copy of each under
  `~/.osaurus/classic-resave/` and puts back only the missing fields when it
  reads the record, so edits made in Classic stay. That covers an agent's
  workflows, read-only working folder, shared tool approval, plugin, host
  services, and follow-up toggle; a remote agent's revoked access; and the
  sandbox rootfs version, retained environments, and idle shutdown.
- Other fields Classic drops on save are not restored: `automations` and the
  other new sections of a saved config template, the default agent's avatar,
  the Slack workspace name, and the newer chat tab layout fields.
- Chats created only in the sync store are missing.
- The sandbox is rebuilt again, and packages installed after the update are
  gone.

## Macs that ran the Osaurus Beta app

The separate Osaurus Beta app (`com.dinoki.osaurus.beta`) shares
`~/.osaurus`, so once Osaurus 1.0 runs:

- Workflows and automations created in Osaurus Beta run in Osaurus too.
- Schedules, watchers, or channel routes edited in Classic after Osaurus Beta
  first ran are not imported again; the copies in `events/` from that first
  run are the ones that fire.
