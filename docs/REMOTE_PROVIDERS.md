# Remote Providers

Remote Providers allow you to connect Osaurus to external APIs (OpenAI, Anthropic, Open Responses, and compatible endpoints), giving you access to cloud models alongside your local MLX models.

---

## Overview

With Remote Providers, you can:

- Access cloud models (ChatGPT, Claude via OpenRouter, etc.) through Osaurus
- Use Osaurus Router, the hosted inference path tied to your Osaurus identity
- Use multiple inference backends simultaneously
- Switch between local and remote models seamlessly
- Keep API keys secure in the macOS Keychain

---

## Adding a Provider

### Via the UI

1. Open the Management window (`⌘ Shift M`)
2. Click **Providers** in the sidebar
3. Click **Add Provider**
4. Select a preset or choose **Custom**
5. Configure the connection settings
6. Click **Save**

### Provider Presets

Osaurus includes presets for common providers:

| Preset         | Host              | Port | Base Path | API Format | Auth             |
| -------------- | ----------------- | ---- | --------- | ---------- | ---------------- |
| **Anthropic**  | api.anthropic.com | 443  | /v1       | Anthropic  | API Key required |
| **OpenAI**     | api.openai.com    | 443  | /v1       | OpenAI     | API Key required |
| **xAI**        | api.x.ai          | 443  | /v1       | OpenAI     | API Key required |
| **OpenRouter** | openrouter.ai     | 443  | /api/v1   | OpenAI     | API Key required |
| **Custom**     | (you specify)     | —    | /v1       | OpenAI     | Optional         |

**Note:** For Ollama, LM Studio, or other OpenAI-compatible endpoints, use the **Custom** preset and configure the host/port manually. See [Provider-Specific Notes](#provider-specific-notes) for configuration examples.

### API Format Types

| Format             | Endpoint            | Description                                                |
| ------------------ | ------------------- | ---------------------------------------------------------- |
| **OpenAI**         | `/chat/completions` | OpenAI Chat Completions API format                         |
| **Anthropic**      | `/messages`         | Anthropic Messages API format                              |
| **Open Responses** | `/responses`        | [Open Responses](https://www.openresponses.org) API format |

---

## Configuration Options

### Basic Settings

| Setting       | Description                                     |
| ------------- | ----------------------------------------------- |
| **Name**      | Display name for the provider                   |
| **Host**      | Hostname or IP address (e.g., `api.openai.com`) |
| **Protocol**  | HTTP or HTTPS                                   |
| **Port**      | Server port (optional, uses protocol default)   |
| **Base Path** | API path prefix (usually `/v1`)                 |

### Authentication

| Setting       | Description                                  |
| ------------- | -------------------------------------------- |
| **Auth Type** | None or API Key                              |
| **API Key**   | Your provider's API key (stored in Keychain) |

### Advanced Settings

| Setting            | Description                               | Default |
| ------------------ | ----------------------------------------- | ------- |
| **Enabled**        | Whether the provider is active            | true    |
| **Auto-connect**   | Connect automatically when Osaurus starts | true    |
| **Timeout**        | Request timeout in seconds                | 60      |
| **Custom Headers** | Additional HTTP headers to send           | {}      |

### Custom Headers

You can add custom HTTP headers for specialized authentication or configuration:

```
X-Custom-Header: value
Authorization: Bearer token
```

For headers containing secrets, mark them as "secret" to store values in the Keychain rather than in plain text configuration.

---

## Using Remote Models

Once a provider is connected, its models appear alongside local models:

### In the Chat UI

- Click the model selector dropdown
- Remote models are grouped under their provider name
- Select a model to start chatting

### Via API

```bash
curl http://127.0.0.1:1337/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

The model name should match what the remote provider expects.

### Via OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:1337/v1", api_key="osaurus")

# Use a remote model
response = client.chat.completions.create(
    model="gpt-4o",  # Remote model from OpenAI provider
    messages=[{"role": "user", "content": "Hello!"}]
)
```

---

## Connection States

Providers can be in the following states:

| State            | Indicator       | Description                           |
| ---------------- | --------------- | ------------------------------------- |
| **Connected**    | Green           | Active connection, models available   |
| **Connecting**   | Blue (animated) | Establishing connection               |
| **Disconnected** | Gray            | Not connected                         |
| **Disabled**     | Gray            | Manually disabled                     |
| **Error**        | Red             | Connection failed (see error message) |

### Connectivity Center

The Providers screen includes a connectivity center above the provider list.
It summarizes connected providers, attention items, discovered models, and
providers that rely on manual model IDs. Use the segmented filter to focus on
all providers, attention items, connected providers, or disabled providers.

The center also provides:

- a reconnect-all action for enabled providers
- a safe copyable diagnostics report covering every configured provider
- inline per-provider reconnect and copy-diagnostics actions
- expanded diagnostics rows on providers that need attention

Manual model IDs are treated as first-class connectivity evidence for
OpenAI-compatible and Azure-style providers. If a provider's `/models` endpoint
is missing or returns a non-OpenAI schema, a configured manual model ID can let
the connection test and provider connect path proceed without requiring a fake
model-list endpoint.

### Troubleshooting Connection Issues

1. **Verify the endpoint** — Check host, port, and base path
2. **Check credentials** — Ensure API key is correct
3. **Test the endpoint directly** — Use curl to verify the provider is reachable
4. **Check network** — Ensure no firewall is blocking the connection
5. **Review error message** — The provider card shows detailed error info

### Provider Diagnostics

Each provider card and the connectivity center include copy buttons. Copied
reports are safe to paste in GitHub or Discord: they list connection state,
authentication state, model-discovery path, request format, and global proxy
state without including API keys, OAuth tokens, request bodies, callback URLs,
or raw headers.

Useful rows:

- **Authentication** shows whether the provider has a Keychain API key, a
  custom/secret credential header, ChatGPT/Codex OAuth tokens, or a missing
  sign-in/key.
- **Model discovery** shows whether Osaurus requires `/models`, can use manual
  model IDs as a fallback, uses Azure deployment IDs, or reads the
  ChatGPT/Codex catalog.
- **Request format** shows the outbound API format and endpoint family. Local
  OpenAI-compatible API validation returns typed 400 errors for unsupported
  sampler settings such as `n > 1` or `response_format=json_schema`.
- **Global proxy** shows whether provider requests use a validated proxy, use
  direct networking, or ignore an invalid saved proxy URL.

---

## Provider-Specific Notes

### Osaurus Router

Osaurus Router is the hosted Osaurus inference service. It is injected from the
local Osaurus identity and should connect automatically at app startup, after
identity changes, and when the app becomes active again.

Router uses the OpenAI-compatible chat completions path with Router-only request
normalization for billing and upstream compatibility. It also records
metadata-only billing events in an encrypted local ledger so support can debug
charged-but-empty reports without storing prompts or responses on Osaurus
servers.

See [Osaurus Router](OSAURUS_ROUTER.md) for the Router request contract,
streaming diagnostics, billing hints, idempotency behavior, and local ledger.

### Osaurus Agents (paired / discovered)

A native Osaurus peer — paired over the LAN via Bonjour or through a relay
invite — is added as an `.osaurus` provider and can be used **two ways**:

- **Inference backend (Mode 1).** Treated like any OpenAI-compatible provider:
  requests go to `/chat/completions`, your selected model and sampling settings
  are honored, and the **local** agent loop drives any tools. Pick one of the
  peer's models from the model selector.
- **Remote agent run (Mode 2).** When you select a paired/discovered *agent*
  (not just one of its models), the conversation runs **fully server-side** on
  the peer via `/agents/{address}/run`: the remote agent uses its **own** model,
  system prompt, memory, and tools, and only text deltas (plus sanitized
  tool-progress hints) stream back. Tool calls execute on the remote machine and
  are never forwarded to you.

In Mode 2:

- The model chip is **pinned** to the remote agent's live effective model
  (resolved on connect from `GET /agents/{address}`) and is read-only — the
  agent owns its model, so the `/model` command is disabled. The caller's
  sampling/reasoning settings are intentionally **not** sent: the remote agent's
  own `generation_config.json` and settings apply.
- The first message **waits for the connection** to establish and the model to
  pin, so it can't race the async connect and fail with a misleading "model not
  found." A connecting/error pill is shown until the peer is ready.
- All traffic is end-to-end encrypted by the [Secure Channel](SECURE_CHANNEL.md).
  If the agent's owner granted it a host workspace folder, the remote run can
  also read and write files there (host **file** tools only — shell and git stay
  disabled). See [`OpenAI_API_GUIDE.md` → External surface deny list](OpenAI_API_GUIDE.md).

### OpenAI

```
Host: api.openai.com
Protocol: HTTPS
Base Path: /v1
Auth: API Key (get from platform.openai.com)
```

Models available: All ChatGPT models via the OpenAI API.

### OpenRouter

```
Host: openrouter.ai
Protocol: HTTPS
Base Path: /api/v1
Auth: API Key (get from openrouter.ai)
```

OpenRouter provides access to multiple model providers. Use model IDs like:

- `openai/gpt-4o`
- `anthropic/claude-3.5-sonnet`
- `google/gemini-pro`

### Ollama

```
Host: localhost (or remote Ollama server IP)
Protocol: HTTP
Port: 11434
Base Path: /v1
Auth: None (unless you've configured Ollama auth)
```

To expose Ollama on the network, start it with:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

### LM Studio

```
Host: localhost
Protocol: HTTP
Port: 1234
Base Path: /v1
Auth: None
```

Ensure the "Start Server" option is enabled in LM Studio.

---

## Security

### API Key Storage

API keys are stored in the macOS Keychain, not in plain text configuration files. This ensures your credentials are:

- Encrypted at rest
- Protected by your macOS login
- Never exposed in config files or logs

### Secret Headers

Custom headers marked as "secret" are also stored in the Keychain.

### Configuration Files

Non-secret provider configuration is stored at:

```
~/.osaurus/providers/remote.json
```

This file contains connection settings but **not** API keys or secret headers.

---

## Managing Providers

### Edit a Provider

1. Click the **pencil icon** on the provider card
2. Modify settings
3. Click **Save**

The connection will be re-established with new settings.

### Delete a Provider

1. Click the **trash icon** on the provider card
2. Confirm deletion

This removes the provider and its stored credentials from the Keychain.

### Enable/Disable a Provider

Toggle the switch on the provider card to enable or disable without deleting.

---

## Related Documentation

- [OpenAI API Guide](OpenAI_API_GUIDE.md) — API usage and SDK examples
- [FEATURES.md](FEATURES.md) — Feature inventory
- [README](../README.md) — Quick start guide
