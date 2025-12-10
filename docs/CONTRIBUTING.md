# Contributing to Osaurus

Thanks for your interest in contributing! We welcome bug reports, feature ideas, documentation improvements, and code contributions.

Please take a moment to read this guide to help streamline the process for everyone.

## Ways to contribute

- Report bugs and regressions
- Suggest enhancements and new features
- Improve documentation and examples
- Triage issues and review pull requests
- Implement fixes and features

## Getting started (development)

Requirements:

- macOS 15.5+
- Apple Silicon (M1 or newer)
- Xcode 16.4+

Build and run:

1. Open `osaurus.xcworkspace` in Xcode 16.4+
2. Select the `osaurus` target and press Run
3. In the app UI, choose a port (default `1337`), then Start
4. Download a model from the Model Manager to generate text locally

Project layout and API overview are in `README.md`. For a complete feature inventory, see [FEATURES.md](FEATURES.md).

### Tool calling (developer notes)

- OpenAI‑compatible DTOs live in `Models/OpenAIAPI.swift` (`Tool`, `ToolFunction`, `ToolCall`, `DeltaToolCall`, etc.).
- Prompt templating is handled internally by MLX `ChatSession`. Osaurus does not assemble prompts manually.
- We rely on MLX `ToolCallProcessor` and event streaming from `MLXLMCommon.generate` to surface tool calls; we no longer parse assistant text ourselves.
- Streaming tool calls are emitted as OpenAI‑style deltas in `Networking/AsyncHTTPHandler.swift` directly from MLX tool call events.

## Development workflow

- Create a feature branch from `main` (e.g., `feat/...`, `fix/...`, `docs/...`)
- Write clear, focused commits; prefer Conventional Commits where practical
- Open a pull request early for feedback if helpful
- Keep PRs small and focused; describe user-facing changes and test steps

### Code style

- Follow standard Swift naming and clarity guidelines
- Prefer clear, multi-line code over terse one-liners
- Add doc comments for non-obvious logic; avoid redundant comments
- Handle errors explicitly and avoid swallowing exceptions

### Testing

- Add or update tests in `osaurusTests/` where reasonable
- Ensure the project builds and tests pass in Xcode before submitting

### Commit and PR guidelines

- Link related issues (e.g., `Closes #123`)
- Include screenshots or screen recordings for UI changes
- Update `README.md`/docs when behavior or configuration changes
- Ensure new public types/functions have clear names and documentation

---

## Documentation contributions

Good documentation is just as important as good code. Here's how to contribute to docs.

### Documentation structure

| Document                                                       | Purpose                                                  |
| -------------------------------------------------------------- | -------------------------------------------------------- |
| [README.md](../README.md)                                      | Project overview, quick start, feature highlights        |
| [FEATURES.md](FEATURES.md)                                     | **Source of truth** — feature inventory and architecture |
| [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md)                     | Remote provider setup and configuration                  |
| [REMOTE_MCP_PROVIDERS.md](REMOTE_MCP_PROVIDERS.md)             | Remote MCP provider setup                                |
| [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md)                       | Insights and Server Explorer guide                       |
| [PLUGIN_AUTHORING.md](PLUGIN_AUTHORING.md)                     | Creating custom plugins                                  |
| [OpenAI_API_GUIDE.md](OpenAI_API_GUIDE.md)                     | API usage, tool calling, streaming                       |
| [SHARED_CONFIGURATION_GUIDE.md](SHARED_CONFIGURATION_GUIDE.md) | Shared configuration for teams                           |

### When adding a new feature

1. **Update FEATURES.md first** — Add a row to the Feature Matrix with:

   - Feature name and status
   - README section (if applicable)
   - Documentation file (if applicable)
   - Code location

2. **Update the README** — If the feature should be highlighted:

   - Add to the "Highlights" table
   - Add to "Key Features" section
   - Update "What is Osaurus?" if it's a major feature

3. **Create dedicated documentation** — For significant features:

   - Create a new doc in `/docs/` (e.g., `FEATURE_NAME.md`)
   - Add to the Documentation Index in FEATURES.md
   - Link from the README

4. **Update the Architecture Overview** — If the feature adds new components, update the diagram in FEATURES.md

### When modifying an existing feature

1. Update the relevant row in FEATURES.md
2. Update any affected documentation files
3. Note breaking changes in the feature's documentation

### Documentation style

- Use clear, concise language
- Include practical examples
- Add tables for options and configuration
- Use code blocks for commands and payloads
- Link to related documentation

### Documentation PRs

- Use the `docs/...` branch prefix
- No code changes required for review
- Update FEATURES.md for any feature-related changes

---

## Reporting a bug

Please use the "Bug report" issue template and include:

- Steps to reproduce
- Expected vs actual behavior
- Logs or screenshots if relevant
- Environment: macOS version, Apple Silicon chip, Xcode version

## Suggesting a feature

Use the "Feature request" issue template and describe:

- The problem you're trying to solve
- Proposed solution or alternatives
- Any additional context or prior art (links welcome)

## Security

Please do not create public issues for security vulnerabilities. See `SECURITY.md` for our security policy and private reporting process.

## Code of Conduct

This project follows the Contributor Covenant. By participating, you agree to uphold our `CODE_OF_CONDUCT.md`.

---

## Join the community

- **[Discord](https://discord.gg/dinoki)** — Chat with contributors and maintainers
- **[Good First Issues](https://github.com/dinoki-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)** — Great starting points

Thank you for helping make Osaurus better!
