# Global Proxy

This note defines the first foundation for global proxy support tracked by
[#1091](https://github.com/osaurus-ai/osaurus/issues/1091) and the older
[#232](https://github.com/osaurus-ai/osaurus/issues/232). The goal is a single
validated proxy endpoint that later call-site migrations can apply to all
outbound network traffic without weakening TLS, persistence, or plugin
boundaries.

## Status

The current rollout adds the validated URL format, URLSession factory, settings
persistence, and first call-site wiring for remote provider traffic plus model
and Hugging Face downloads. Plugin HTTP, MCP OAuth, relay, theme sharing, GitHub
skill import, sandbox provisioning, local health checks, and per-provider
overrides remain follow-up work so the shared network policy can be reviewed in
bounded steps.

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

`GlobalProxyConfiguration` parses and validates the user-facing proxy URL.
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

## Rollout Plan

1. Migrate the remaining URLSession call sites in small PRs. Known affected
   paths include plugin fetch/search traffic, MCP HTTP/SSE and OAuth traffic,
   GitHub skill requests, relay traffic, theme sharing, sandbox provisioning,
   and remote agent HTTP traffic.
2. Add smoke coverage with a stub proxy that records CONNECT/HTTP/SOCKS attempts
   for provider and model-download flows. Include a DNS-leak check before
   marking #1091 complete.
3. Keep per-provider proxy selection and model mirror selection as separate
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
