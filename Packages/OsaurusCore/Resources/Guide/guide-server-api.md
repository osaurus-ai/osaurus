---
title: Server and API
summary: The local OpenAI-compatible HTTP server — endpoints, port, auth, and using Osaurus from other apps.
order: 110
---

# Server and API

Osaurus runs a local HTTP server so other apps, scripts, and SDKs can use your models. It speaks the OpenAI API (plus Anthropic and Ollama formats).

## Basics

- Default base URL: `http://127.0.0.1:1337`. The port and network exposure live in the Server tab (or ask the assistant to change them — changing port/exposure restarts the server).
- List models: `GET /v1/models` — only downloaded models appear.
- Chat: `POST /v1/chat/completions` (SSE streaming with `stream: true`). Also `POST /v1/responses` (Open Responses), `/anthropic/v1/messages`, and Ollama's `/api/chat`.
- OpenAI SDK: set `base_url="http://127.0.0.1:1337/v1"` and any placeholder key (e.g. `"osaurus"`) on loopback; use a real access key from the Server tab if network exposure is on.

## Two ways to run tools

- `POST /v1/chat/completions` is strict OpenAI semantics: Osaurus returns `tool_calls` and your client executes them. No Osaurus memory or skills are injected.
- `POST /agents/{id}/run` runs a full server-side agent loop (what in-app chat uses): the agent executes its own tools, with memory and context, capped at 30 iterations.
- Dangerous tools (`file_write`, `file_edit`, `shell_run`, `git_commit`, …) are denied to external HTTP callers by default.

## Sessions and caching

Pass an optional `session_id` to group turns; KV-cache reuse is automatic. Prefix caching, paged KV, and the on-disk cache are configurable under Server settings (cache changes unload loaded models to take effect).

## Server settings you can change

Port, network exposure, generation defaults (temperature / top-p / top-k / max tokens — leave unset to use each model's own defaults), continuous batching, concurrent sequences, and cache toggles. The Server tab includes an API explorer; Insights shows live request/response traffic.

## MCP surface

`GET /mcp/tools` and `POST /mcp/call` expose Osaurus tools over HTTP; `osaurus mcp` runs Osaurus as a stdio MCP server for other AI apps.
