# Plugin Quickstart

Get a working plugin running in **under 5 minutes**. By the end you'll have a plugin loaded into Osaurus that can be invoked from chat and reloaded as you iterate.

## Prerequisites

- macOS 15 (Sequoia) or later
- Osaurus installed and running
- The `osaurus` CLI on your `PATH`. From the Osaurus app menu, choose **Settings → Developer → Install CLI**.
- Either:
  - **Swift** toolchain (Xcode 16 or `swift --version` >= 6.0), or
  - **Rust** toolchain (`cargo` and `rustc` >= 1.75)

Check the basics:

```bash
osaurus --version
swift --version   # or: cargo --version
```

## Step 1: Scaffold

```bash
mkdir my-plugin && cd my-plugin
osaurus tools create my-plugin               # Swift (default)
# or:
osaurus tools create my-plugin --language rust
```

You now have a project with:

- `osaurus-plugin.json` — the dev manifest used by the CLI
- `Sources/MyPlugin/Plugin.swift` (or `src/lib.rs`) — your plugin entry point
- A `web/` placeholder for a web UI
- A `.github/workflows/release.yml` for CI publishing

## Step 2: Build and run with hot reload

```bash
osaurus tools dev
```

This command:

1. Builds the dylib in DEBUG mode
2. Symlinks it into the Osaurus tools directory (`~/Library/Application Support/Osaurus/Tools/`)
3. Sends a reload signal so Osaurus picks up the new binary
4. Watches your sources for changes and rebuilds + reloads on every save

Leave this running while you develop.

## Step 3: Try the plugin

Open Osaurus and start a new chat. Ask:

> Use the hello_world tool with name "Plugin Author"

You should see the model call your tool and return a response. Check **Insights → Plugin Activity** to see the call logged.

## Step 4: Make a change

Open `Sources/MyPlugin/Plugin.swift` and modify the response message in `HelloTool.run`. Save. The CLI rebuilds and reloads in seconds. Run the tool again from chat — your change is live.

## What's next?

- **Add more tools**: declare them in `get_manifest` and route them in `invoke`
- **Use host APIs**: call `host->log`, `host->config_get`, `host->complete` from inside your tool
- **Expose HTTP routes**: see [ROUTES_AND_WEB.md](ROUTES_AND_WEB.md)
- **Persist data**: see [HOST_API.md#storage](HOST_API.md#storage)
- **Run inference**: see [HOST_API.md#inference](HOST_API.md#inference)
- **Read the concept guide**: [AUTHORING.md](AUTHORING.md)

## Troubleshooting

**"Plugin not found in chat"**

```bash
osaurus tools list
```

Make sure your plugin appears. If not, check `osaurus tools dev` output for build errors.

**"hello_world is not a recognized tool"**

The model needs to be told the tool exists. Either explicitly mention the tool in your prompt or use a model with strong tool-calling support.

**"Plugin failed to load"**

Open Insights and search for `[Osaurus]` log lines. Common causes: missing `init` function, invalid manifest JSON, crash during `init`. See [DEBUGGING.md](DEBUGGING.md) for a full decision tree.

**Web UI shows 401**

Use the **Open Web App** button inside the Osaurus plugin detail page rather than copying the URL into Safari directly. The button automatically attaches the current agent context. If you need to embed your own URL, append `?osr_agent=<agent_uuid>`.

## Going further

You've now used `host->log`. The full host surface — `complete`, `config_get`, `db_exec`, `dispatch`, `http_request`, and more — is documented in [HOST_API.md](HOST_API.md). Skim it once to see what's available; reach for it when your plugin needs it.
