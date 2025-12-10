# Remote Providers

Remote Providers allow you to connect Osaurus to external OpenAI-compatible APIs, giving you access to cloud models alongside your local MLX models.

---

## Overview

With Remote Providers, you can:

- Access cloud models (GPT-4o, Claude via OpenRouter, etc.) through Osaurus
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

| Preset         | Host           | Port          | Base Path | Auth             |
| -------------- | -------------- | ------------- | --------- | ---------------- |
| **OpenAI**     | api.openai.com | 443           | /v1       | API Key required |
| **OpenRouter** | openrouter.ai  | 443           | /api/v1   | API Key required |
| **Ollama**     | localhost      | 11434         | /v1       | None             |
| **LM Studio**  | localhost      | 1234          | /v1       | None             |
| **Custom**     | (you specify)  | (you specify) | /v1       | Optional         |

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

### Troubleshooting Connection Issues

1. **Verify the endpoint** — Check host, port, and base path
2. **Check credentials** — Ensure API key is correct
3. **Test the endpoint directly** — Use curl to verify the provider is reachable
4. **Check network** — Ensure no firewall is blocking the connection
5. **Review error message** — The provider card shows detailed error info

---

## Provider-Specific Notes

### OpenAI

```
Host: api.openai.com
Protocol: HTTPS
Base Path: /v1
Auth: API Key (get from platform.openai.com)
```

Models available: `gpt-4o`, `gpt-4o-mini`, `o1-preview`, `o1-mini`, etc.

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
~/Library/Application Support/Osaurus/remote_providers.json
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
