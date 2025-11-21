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

1. Open `osaurus.xcodeproj` in Xcode 16.4+
2. Select the `osaurus` target and press Run
3. In the app UI, choose a port (default `8080`), then Start
4. Download a model from the Model Manager to generate text locally

Project layout and API overview are in `README.md`.

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

Thank you for helping make Osaurus better!
