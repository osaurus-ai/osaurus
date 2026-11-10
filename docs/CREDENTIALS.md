# Credentials (Keys)

One store holds every value an agent can use: API keys, tokens, passwords, and
plain variables. The user sees it as **General → Keys**; code reaches it
through `CredentialStore`, `CredentialResolver`, and one small consumer helper
per feature.

## Model

| Concept | What it is |
|---|---|
| Key | A name such as `GITHUB_TOKEN`. `[A-Za-z_][A-Za-z0-9_]*`, at most 128 characters, so it is always a valid environment variable name. |
| Scope | `global` (all agents) or `agent(<uuid>)` (one agent). |
| Kind | `secret` (hidden, value in the Keychain) or `variable` (shown as text, value in the index). |
| Exposure | `exposeToSandbox`: the sandbox gets the key as an environment variable. On by default for keys the user or an agent creates; off for keys an MCP server, plugin, channel, or workflow setup creates. |
| Slot | One place that needs a value: an MCP env var, header, or bearer token, a plugin's declared secret, a channel token, a workflow key. |
| Binding | Which key fills a slot. Without a binding the slot uses its default key. |

### Resolution

For a slot read on behalf of an agent:

1. The agent's own value for the slot's key.
2. The global value for that key.
3. The not-yet-imported legacy value (see Migration), read-only.

An agent-only value never satisfies a slot for the app as a whole: "Missing
Keys" looks at global values only, because an MCP server or channel started
outside an agent turn has no agent.

### Default keys

| Consumer | Slot id | Default key |
|---|---|---|
| MCP env var | `mcp:<uuid>:env:NAME` | `NAME` when it is upper snake case, else `<SERVER>_<NAME>` |
| MCP header | `mcp:<uuid>:header:NAME` | `<SERVER>_<HEADER>` |
| MCP bearer token | `mcp:<uuid>:token` | `<SERVER>_TOKEN` |
| Plugin secret | `plugin:<id>:<spec>` | `spec` when upper snake case, else `<PLUGIN>_<SPEC>` (`osaurus.tavily` → `TAVILY`) |
| Native channel | `channel:<slack|discord|telegram>:<field>` | `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_SIGNING_SECRET`, `DISCORD_BOT_TOKEN`, `TELEGRAM_BOT_TOKEN` |
| Custom JSON / n8n channel | `channel:agent-channel.<conn>:<secret>` | `<CONN>_<SECRET>` |
| Workflow | `workflow:<uuid>:<KEY>` | `KEY` (upper-snake-cased) |

`CredentialKeys.prefixed` never doubles a prefix (`GITHUB` + `GITHUB_TOKEN`
stays `GITHUB_TOKEN`).

Two consumers that ask for the same name share one value. When an importer or
installer would overwrite a different value, `save(_:for:owner:origin:separateOnConflict:)`
writes `<OWNER>_<KEY>` (then `_2`, `_3`, …) instead and records the binding.
Workflow setup offers the same choice explicitly with **Use a separate value
for this workflow** (`WorkflowCredentials.saveSeparate`).

## Storage

| What | Where |
|---|---|
| Secret values | Keychain service `ai.osaurus.credentials`, account `global/<KEY>` or `agent/<uuid-lower>/<KEY>` |
| Records (key, scope, kind, description, exposure, origin, dates) and variable values | `~/.osaurus/credentials/index.json` |
| Bindings (slot id → key) | `~/.osaurus/credentials/bindings.json` |
| Imported legacy ids and migration date | `index.json` (`importedLegacy`, `migrationCompletedAt`) |
| Deleted keys | `index.json` (`deletedAccounts`), so the legacy fallback and migration never bring a deleted value back |

Values are at most 64 KB. Multiline values (PEM keys) are kept as typed.

Secret values use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, the same as
the legacy items: they never sync to other devices and can't be read while
the Mac is locked. An automation that runs while the screen is locked can't
use hidden values; visible values (variables) still work.

Every write posts `.credentialsDidChange`. `CredentialRegistry` (the Keys
page model) refreshes on it, and `MCPProviderManager` evicts per-agent MCP
clients whose credentials changed.

Under `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1` secret values are held in memory.
Tests use `CredentialStore._withIsolatedStoreForTesting { … }`, which binds a
temporary store to `CredentialStore.current` through a task local. Detached
tasks must capture `CredentialStore.current` and re-bind it.

## Consumers

| Feature | Helper | Notes |
|---|---|---|
| Sandbox | `SandboxCredentials` | Env vars are the global keys with exposure on, overlaid by the agent's own keys. `sandbox_secret_set` saves an agent-scoped key; `sandbox_secret_check` reports presence. The agent page's **Sandbox → Keys** list shows what the agent sees. |
| Plugins | `PluginCredentials` | Declared secrets (`manifest.secrets`, sandbox plugin `secrets`) resolve through Keys for tool payload injection, `config_get`, and initial config. `config_set` of a declared secret saves the calling agent's value. Undeclared config and runtime state (`tunnel_url`) stay in `ToolSecretsKeychain`. |
| MCP | `MCPCredentials` | Env vars, secret headers, and the bearer token. A server with no agent-specific values shares one client; an agent whose values differ from the shared ones gets a variant client keyed by `(providerId, agentId)`, reused while its credential fingerprint matches, swept after 10 idle minutes, at most 8 per server (least recently used closed first). An agent whose own value equals the shared value uses the shared client. |
| Channels | `ChannelCredentials` | Slack, Discord, Telegram tokens, and custom JSON / n8n connection secrets. |
| Workflows | `WorkflowCredentials` | Code and HTTP steps read secrets for the calling agent (`request.caller.agentID`). OAuth and saved connections stay in `WorkflowConnections`. |
| Config documents | `ConfigSecretRef` | `credential:KEY` points at a global key. |

Model provider, web search, TTS, Hugging Face, and GitHub keys are not agent
usable and stay in their own stores. The Keys page lists them on its **App
Keys** tab and edits them in place through `AppKeys.save`. OAuth sign-ins stay
with their MCP server or provider and are listed on the **Accounts** tab. The
**Your Keys** tab holds everything in the store (`KeysTab` raw values are the
settings-search `subTab` ids).

## Migration

`CredentialMigration` runs one second after launch (and again when a plugin
loads). It is copy-only:

- Legacy Keychain items (`ToolSecretsKeychain`, `AgentSecretsKeychain`,
  `MCPProviderKeychain`, `WorkflowSecretsKeychain`, channel stores) and config
  files are never deleted or rewritten. A downgrade keeps working.
- Each copied item is recorded in `importedLegacy`. A re-run skips it, so an
  edit or delete in Keys is never undone by the old value.
- Default-agent plugin secrets become global; other agents' plugin secrets and
  agent secrets become agent-scoped.
- Each consumer lists the legacy items for a slot as
  `CredentialResolver.LegacyItem`s (its `legacyItem(s)` helpers) and passes
  them to `CredentialResolver.resolve` / `isSatisfied`; the Keys page's
  missing list uses the same items. The resolver alone decides whether an
  item may still be read (migration incomplete, item unimported, key not
  deleted). All legacy wrappers are read-only.

Until an item is imported, reads fall back to it, so nothing stops working
between upgrade and the first migration run. A pass that copies everything,
with authoritative Keychain listings, sets `migrationCompletedAt`; after that
`CredentialResolver.readsLegacy` is false and no consumer reads the legacy
stores. A pass with any failed copy, or a locked Keychain, leaves the
fallback on and runs again when the Mac is unlocked. Setup checks
(`WorkflowCredentials.isSetUp`) answer the legacy question in the background
(`LegacyPresenceCache`) instead of reading the Keychain while a view renders.

## Showing values

**Show** and **Copy** call `CredentialReveal`, which asks for Touch ID or the
Mac password (`LAContext.deviceOwnerAuthentication`, reused for 60 seconds).
A shown value (including an App Key's) hides again after 10 seconds. Copy
keeps the value on this Mac (`NSPasteboard.prepareForNewContents(with:
.currentHostOnly)`, no Universal Clipboard) and clears it after 60 seconds
unless something else was copied since. Consumer
editors (`CredentialField`) never load the saved value: a blank field keeps
it.

## Agent lifecycle

Deleting an agent deletes its agent-scoped keys (`CredentialStore.deleteAll(agentId:)`).
Uninstalling a workflow or removing an MCP server forgets its bindings but
keeps the keys, since other consumers may share them.
