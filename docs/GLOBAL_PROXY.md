# Global Proxy

This note defines global proxy support tracked by
[#1091](https://github.com/osaurus-ai/osaurus/issues/1091) and the older
[#232](https://github.com/osaurus-ai/osaurus/issues/232). The goal is a single
validated proxy endpoint that outbound network traffic can apply without
weakening TLS, persistence, or plugin boundaries.

## Status

The current rollout includes the validated URL format, shared URLSession
factory, settings persistence, and call-site wiring for remote provider traffic,
HTTP/SSE MCP provider discovery, MCP auth-challenge probes, model downloads,
Hugging Face lookups, plugin HTTP, plugin repository refreshes, plugin artifact
installs, relay, theme sharing, GitHub skill import, and sandbox provisioning.
Local loopback health checks remain direct by design. Per-provider proxy
selection and model mirror selection remain separate designs.

Provider and MCP provider cards now expose a copyable **Global proxy**
diagnostic row. A valid proxy row shows the redacted endpoint. A missing proxy
row says requests use direct networking. An invalid saved proxy URL is shown as
ignored with the validation reason, instead of silently looking like a network
failure.

Server settings also show a proxy status line:

- **Disabled** means the proxy URL is blank and new outbound sessions use direct
  networking.
- **Configured** means the URL validated and was saved; new outbound sessions
  apply that endpoint when they are created.
- **Invalid** means the typed value failed validation and is not saved.

## Proxy Policy

The global setting is a single URL with one of these forms:

- `http://proxy.example.com:8080`
- `https://proxy.example.com:8443`
- `socks://proxy.example.com:1080`
- `socks5://proxy.example.com:1080`

The validator requires an explicit scheme, host, and port. It rejects unsupported
schemes, `file:` URLs, path-based input, query strings, fragments, embedded
userinfo credentials, missing ports, localhost names, `.local` names, loopback
addresses, unspecified addresses, and link-local addresses.

Credentials are deliberately out of scope for the URL format. If authenticated
proxies are added later, usernames and secrets should be stored in the encrypted
settings/Keychain path and injected through a redacted credential API rather
than through URL userinfo or query strings.

## URLSession Factory

`GlobalProxyConfiguration` in `OsaurusNetworking` parses and validates the
user-facing proxy URL.
`GlobalProxyURLSessionFactory` copies a caller's `URLSessionConfiguration`,
applies the shaped `connectionProxyDictionary`, and builds a `URLSession`
without installing any custom TLS delegate. Certificate validation remains the
Foundation default.

HTTP and HTTPS proxy URLs populate the HTTP and HTTPS CFNetwork proxy keys so a
single global web proxy covers both web request families. SOCKS and SOCKS5 URLs
populate only the SOCKS keys. The foundation does not install PAC files, bypass
lists, environment variables, or destination rewrites.

`GlobalProxySettings` reads the persisted optional URL from `server.json` and
fails closed when the value is missing or invalid. It reads that JSON directly
instead of calling `ServerConfigurationStore` so background networking services
can create sessions synchronously without crossing the Settings UI's main-actor
store boundary.

`OsaurusRepository` uses the same `OsaurusNetworking` parser/factory but reads
only the lightweight `server.json.globalProxyURL` field through `ToolsPaths`.
That keeps plugin marketplace refreshes and plugin artifact installs on the
same proxy policy without making the repository package depend on
`OsaurusCore`.

## Rollout Plan

1. Add smoke coverage with a stub proxy that records CONNECT/HTTP/SOCKS attempts
   for provider and model-download flows. Include a DNS-leak check before
   marking #1091 complete.
2. Keep per-provider proxy selection and model mirror selection as separate
   designs. The global endpoint is intentionally simpler and should apply before
   more granular routing is considered.

## Rollback

The rollback hook is the optional proxy configuration itself. Clearing the saved
proxy URL, or passing `nil` to `GlobalProxyURLSessionFactory`, leaves
`URLSessionConfiguration` on its normal system behavior with no global proxy
dictionary applied. A risky call-site migration can also be reverted by changing
that call site back to its previous `URLSessionConfiguration.default` or
`.ephemeral` construction while keeping the validator in place.

## Security Notes

The proxy configuration does not bypass certificate validation, does not accept
credentials in URL query strings, and does not downgrade HTTPS failures to plain
HTTP retries. A malicious proxy URL is constrained to a host/port endpoint:
local file paths, PAC scripts, URL paths, localhost/link-local destinations, and
embedded credentials are rejected before any session is created. The factory only
creates outbound client sessions, so a proxy setting cannot redirect privileged
ports, grant host-Keychain access, or mutate plugin/provider identity.
