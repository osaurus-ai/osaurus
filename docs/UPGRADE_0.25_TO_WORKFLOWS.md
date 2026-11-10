# Upgrading from 0.25.x to the workflows build

What an in-place update (Sparkle, same `com.dinoki.osaurus` app and
`~/.osaurus` data) changes for someone on 0.25.33, and what going back costs.
Use it for release notes and support answers.

## Carries over unchanged

- Chats, agents, models, providers, MCP servers, plugins, and settings.
- Keychain secrets. Service names, the account master key
  (`com.osaurus.account`), and the storage key (`com.osaurus.storage`) are
  the same. `CredentialMigration` copies legacy secrets into the new
  credential store and deletes nothing. With the same Developer ID there is
  no Keychain prompt.
- Databases. Chat history moves from schema 24 to 26 (two added columns);
  0.25.33 opens a newer stamp. Memory and Knowledge schemas are unchanged.
- Schedules, watchers, and channel inbound routes. `EventMigration` copies
  them into `events/` once and leaves the originals.
- Onboarding. Someone who finished it on any build since 0.9.7 does not see
  it again, and no starter teammates or default workflows are added to
  their library. What's New is gone.

## Changes on first use

- **Sandbox is rebuilt.** The first start after updating downloads a new
  init filesystem (about 64 MiB, so it needs a connection) and builds
  per-agent environments, briefly using about 8 GiB of extra disk.
  Packages installed inside the old sandbox (apk, pip, npm) must be
  reinstalled. Files in the sandbox workspace are kept; loose files at the
  workspace root move to `shared/`. If that first start fails, the old
  sandbox disk is kept so it can be retried.
- **LAN pairing.** This build no longer advertises `_osaurus._tcp` over
  Bonjour and drops `GET /pair/challenge` and `POST /pair`. Older iPhone and
  Mac builds that pair over those cannot find or pair with this Mac. Existing
  access keys keep working until they expire or are revoked.

## Going back to 0.25.33

Sparkle never downgrades: turning beta updates off keeps this build until a
newer stable ships. Going back means reinstalling the 0.25.33 DMG. After
that:

- Secrets added, edited, or deleted after the update are not seen; 0.25.33
  reads the pre-update Keychain items.
- Pending self-schedules and run history are empty. Their tables were
  renamed to `agent_runs_legacy` and `agent_next_run_legacy`.
- Workflows and automations created here do not run; 0.25.33 has no reader
  for them.
- Saving an agent, a remote agent, or the sandbox settings in 0.25.33 drops
  the fields it doesn't know. This build keeps a copy of each under
  `~/.osaurus/classic-resave/` and puts back only the missing fields when it
  reads the record, so edits made in 0.25.33 stay. That covers an agent's
  workflows, read-only working folder, shared tool approval, plugin, host
  services, and follow-up toggle; a remote agent's revoked access; and the
  sandbox rootfs version, retained environments, and idle shutdown.
- Other fields 0.25.33 drops on save are not restored: `automations` and the
  other new sections of a saved config template, the default agent's avatar,
  the Slack workspace name, and the newer chat tab layout fields.
- Chats created only in the sync store are missing.
- The sandbox is rebuilt again, and packages installed after the update are
  gone.

## Macs that ran Osaurus Beta

Osaurus Beta shares `~/.osaurus`, so once stable runs this build:

- Workflows and automations created in Osaurus Beta run in Osaurus too.
- Schedules, watchers, or channel routes edited in stable after Osaurus Beta
  first ran are not imported again; the copies in `events/` from that first
  run are the ones that fire.
