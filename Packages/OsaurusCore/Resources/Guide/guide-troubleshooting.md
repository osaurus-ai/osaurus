---
title: Troubleshooting and Support
summary: Common fixes, diagnostics, and where to get help.
order: 180
---

# Troubleshooting and Support

## Quick checks

- Model not responding or slow: check the model is downloaded (Models tab) and fits in RAM; a smaller or more-quantized model often fixes it. Server → health indicator shows whether the server is running.
- Tools not being used: make sure the agent's tool mode is Auto with Tools enabled, and use a model with good tool calling (curated catalog models are validated for this).
- Provider shows Error: open the provider card for the exact message; re-check the API key (Providers tab), then use the connectivity center's reconnect.
- New skill/plugin/MCP tools not appearing mid-chat: start a new chat so the session's capability manifest refreshes.
- Port already in use: change the server port (Server tab or ask the assistant); ports below 1024 need elevated permissions — pick a higher one.
- Permission prompts (Microphone, Accessibility, Screen Recording, Full Disk Access): grant in macOS System Settings → Privacy & Security, then retry.
- Broken data store: Management → Storage → "Stores needing attention" → Retry or Reset (Reset quarantines the file, never deletes it).

## Diagnostics

- Insights tab: live server request/response traffic, plugin activity, MCP traffic.
- Memory → Diagnostics for the memory store; Sandbox → Run Diagnostics for the VM.
- CLI: `osaurus status`.

## Getting help

- Ask this assistant — it can read the guide and inspect your configuration.
- README and docs: https://docs.osaurus.ai
- Search GitHub issues (open and closed) for similar problems; file bugs with the "Bug report" template (steps, expected/actual, environment).
- Feature ideas: the "Feature request" template. Questions: GitHub Discussions.
- Security issues: never file publicly — follow SECURITY.md for private reporting.
