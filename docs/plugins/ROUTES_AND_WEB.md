# Routes and Web UIs

End-to-end story for plugin HTTP routes and web UIs.

## At a glance

A plugin can expose two kinds of HTTP surface:

- **Routes** — dynamic JSON endpoints handled by your plugin's `handle_route` callback. Good for webhooks, OAuth callbacks, REST APIs.
- **Web UI** — a static directory bundled with the plugin, served from a configurable mount point. Good for settings panels, dashboards, custom chat surfaces.

Both live under the same `/plugins/<plugin_id>/...` prefix so URLs never collide between plugins.

## Routes

### Declaring routes

In your manifest:

```json
"capabilities": {
  "routes": [
    {
      "id": "callback",
      "path": "/oauth/callback",
      "methods": ["GET"],
      "description": "OAuth redirect handler",
      "auth": "none",
      "tunnel_exposed": true
    },
    {
      "id": "create_item",
      "path": "/items",
      "methods": ["POST"],
      "auth": "owner"
    },
    {
      "id": "get_item",
      "path": "/items/:id",
      "methods": ["GET"],
      "auth": "owner"
    }
  ]
}
```

`tunnel_exposed` is **opt-in** (default `false`). See [Tunnel exposure](#tunnel-exposure) below.

Path syntax:

| Pattern | Matches | Example |
|---|---|---|
| Exact | only the literal path | `/items` matches `/items` |
| `:name` | one segment, captured as a path parameter | `/items/:id` matches `/items/42` with `path_params.id == "42"` |
| `*` suffix | zero or more trailing segments | `/files/*` matches `/files`, `/files/a`, `/files/a/b` |

Match precedence: **exact > path-parameter > wildcard**. The first matching route wins within each tier, so define more specific routes first.

### Auth levels

| `auth` | Meaning |
|---|---|
| `none` | No host-side auth check. The route is rate-limited (100/min per plugin) but otherwise open. Combine with your own request signing for webhooks. |
| `verify` | Same handling as `none` from the host's perspective; the **plugin** verifies the request (e.g. Slack signing key, Stripe webhook signature). |
| `owner` | Host requires a valid `osk-v1` access key in the `Authorization` header. Use for routes that should only be reachable by you. |

All `/plugins/...` requests must also carry `X-Osaurus-Agent-Id` (or the `osr_agent` query parameter as a fallback for browser top-level navigation; see [Web UIs](#web-uis) below).

### Implementing `handle_route`

Set `api.handle_route` in your `osr_plugin_api` struct. The host hands you a JSON-encoded request:

```json
{
  "route_id": "get_item",
  "method": "GET",
  "path": "/items/42?format=full",
  "query": {"format": "full"},
  "path_params": {"id": "42"},
  "headers": {"x-osaurus-agent-id": "...", "user-agent": "..."},
  "body": "",
  "body_encoding": "utf8",
  "remote_addr": "",
  "plugin_id": "dev.example.MyPlugin",
  "osaurus": {
    "base_url": "http://127.0.0.1:1338",
    "plugin_url": "http://127.0.0.1:1338/plugins/dev.example.MyPlugin",
    "agent_address": "..."
  }
}
```

You return a JSON-encoded response:

```json
{
  "status": 200,
  "headers": {"Content-Type": "application/json"},
  "body": "{\"id\":\"42\",\"name\":\"Widget\"}",
  "body_encoding": "utf8"
}
```

For binary responses set `body_encoding: "base64"`. **The host validates that the body is valid base64 and returns 502 if it isn't** — silent corruption is no longer possible (this used to fall back to sending the raw string).

### Timeout

Route handlers have a default 30-second timeout. The host returns 500 with `Plugin route handler timed out after 30s` if your handler doesn't respond in time. Plan async work accordingly (return a 202, dispatch a background task, poll via `task_status`).

### HEAD requests

HEAD requests for plugin routes go through the same matching/auth pipeline as GET. Your handler can return the response shape and the host will suppress the body.

### Tunnel exposure

By default, plugin routes are **loopback-only**. A tunneled request (`wss://agent.osaurus.ai/tunnel/connect` → public HTTPS URL) for a route without `tunnel_exposed: true` returns 404, exactly as if the route did not exist. This stops route existence from leaking and prevents accidentally publishing internal endpoints.

To expose a specific route over the tunnel, set `tunnel_exposed: true` on the route spec:

```json
{
  "id": "github_webhook",
  "path": "/webhooks/github",
  "methods": ["POST"],
  "auth": "verify",
  "tunnel_exposed": true
}
```

After opting in:

- The route is reachable from both loopback and the tunnel.
- The host's existing `auth` mode still applies. `auth: "owner"` requires `osk-v1`. `auth: "verify"` means the plugin verifies the request itself (HMAC, signing key, IP allow-list, etc). `auth: "none"` is fully public over the tunnel — only use for routes that have no security implications, like a public health check.
- The tunnel-aware base URL is injected into your request as `osaurus.base_url` so the URL you generate (e.g. an OAuth redirect URL or a webhook callback URL) automatically uses the public hostname.

`capabilities.web.tunnel_exposed` works the same way for the static UI: a tunneled GET against the web mount returns 404 unless the manifest opts in.

#### Picking a posture

| Scenario | `auth` | `tunnel_exposed` |
|---|---|---|
| Internal admin UI used only from your Mac | `owner` | omit (false) |
| OAuth callback for a third-party service | `none` or `verify` | `true` |
| Webhook from Slack / GitHub / Stripe | `verify` (validate signature in the plugin) | `true` |
| Public iframe-able dashboard | `owner` for editing, separate `none` route for read-only embeds | `true` (only on the read-only route) |
| LLM streaming endpoint for your own agent | `owner` | omit (false) — keep on loopback |

## Web UIs

A web UI is a static directory bundled with your plugin, served from `/plugins/<plugin_id>/<mount>`.

### Declaring

```json
"capabilities": {
  "web": {
    "static_dir": "web",
    "entry": "index.html",
    "mount": "/ui",
    "auth": "owner",
    "api_mount": "/api"
  }
}
```

| Field | Meaning |
|---|---|
| `static_dir` | Directory inside the installed plugin bundle |
| `entry` | Default file when the path is the mount point itself or doesn't exist (SPA fallback) |
| `mount` | URL path under `/plugins/<plugin_id>` where the UI is served |
| `auth` | `none` / `verify` / `owner` |
| `api_mount` | Optional. Determines `window.__osaurus.apiUrl`. Defaults to `/api`. Set if your plugin mounts API routes under a different prefix. |
| `tunnel_exposed` | Optional. When `true`, the static UI is reachable over the tunnel. Defaults to `false` (loopback-only). See [Tunnel exposure](#tunnel-exposure). |

### Manifest validation

If a `web.mount` overlaps with a `routes[].path`, the plugin **fails to load** with a clear error:

> Plugin dev.example.MyPlugin declares route '/ui/health' under web mount '/ui'; the static web branch would shadow this route. Move the route outside the web mount or remove the web mount overlap.

Move the conflicting route outside the web mount.

### Injected `window.__osaurus`

Every HTML response served by the static branch (or the dev proxy) gets a small `<script>` injected before `</head>`:

```js
window.__osaurus = {
  pluginId: "dev.example.MyPlugin",
  baseUrl: "/plugins/dev.example.MyPlugin",
  apiUrl: "/plugins/dev.example.MyPlugin/api",
  agentId: "<UUID>",
  fetch: function(input, init) { /* attaches X-Osaurus-Agent-Id */ }
};
```

Use `window.__osaurus.fetch(...)` instead of the global `fetch` so the agent header is always carried forward. The helper attaches it automatically.

### Opening from the app

The Osaurus plugin detail screen has an **Open Web App** button. It opens the URL with `?osr_agent=<agent_uuid>` so the server accepts the top-level navigation. From that point the injected `fetch` helper carries the agent header forward.

If you need to deep-link from outside the app, append the same query parameter:

```
http://127.0.0.1:1338/plugins/dev.example.MyPlugin/ui?osr_agent=<agent_uuid>
```

### Dev proxy

During development you often want to run a Vite / Next.js / webpack dev server with HMR rather than rebuilding the plugin every time the UI changes.

Create `~/Library/Application Support/Osaurus/Config/dev-proxy.json`:

```json
{
  "plugin_id": "dev.example.MyPlugin",
  "web_proxy": "http://localhost:5173"
}
```

When the host serves a request under your plugin's `mount`, it proxies to that URL **with the original method, headers, and body** — POSTs, HMR pings, and any non-GET dev-server traffic flow through. The injected `window.__osaurus` is still added for HTML responses.

Drop the file when you're done; the plugin reverts to its bundled static directory.

### Symlinks and hidden files

The host's static serving:

- Resolves the path with `URL.standardizedFileURL` and rejects anything that escapes the web directory
- Rejects path traversal (`..` in the URL)
- Has no special handling for hidden files — **don't put `.env` or other secrets inside `web/`**. Anything under `static_dir` is reachable by URL.

## Security model summary

| Boundary | Enforced by |
|---|---|
| Cross-plugin path collision | URL namespacing — every plugin lives under `/plugins/<plugin_id>` |
| Tunnel exposure | Loopback-only by default; `tunnel_exposed: true` is the explicit opt-in per route / per web mount |
| Path traversal | `..` rejected on plugin id and subpath; resolved file path must stay under web root |
| Static directory escape | `URL.standardizedFileURL` containment + prefix check |
| Owner-only routes | `osk-v1` Bearer in `Authorization` header |
| Hung handlers | 30s timeout on `handle_route` |
| Cross-plugin task tampering | Per-plugin ownership checks in `task_status` / `dispatch_cancel` / `send_draft` / `dispatch_interrupt` |
| Outbound HTTP SSRF | `host->http_request` blocks loopback / RFC1918 / link-local |
| File reads | `host->file_read` is hard-scoped to `~/.osaurus/artifacts/` and 50 MB |

## What still needs your attention

- **Edge TLS only.** The tunnel hop is `wss://`, but the local HTTP server is plain text. If you're concerned about local-host snooping, pair the tunnel with strict request signing.
- **`tunnel_exposed: true` `auth: "none"` is genuinely public.** Treat such routes as you'd treat any public webhook endpoint. Validate inputs and rate-limit aggressively.

## See also

- [HOST_API.md](HOST_API.md)
- [DEBUGGING.md](DEBUGGING.md#why-does-my-web-ui-401)
- [PACKAGING.md](PACKAGING.md)
