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

## Architecture guide

### Layer definitions

The core library (`Packages/OsaurusCore/`) follows a layered architecture. Each layer has a specific role and set of rules.

**Models** — Pure data. No logic, no side effects, no singletons.

- Structs, enums, Codable types, API DTOs, configuration types
- Organized into domain subfolders: `API/`, `Chat/`, `Agent/`, `Configuration/`, `Method/`, `Plugin/`, `Memory/`, `Voice/`, `Theme/`, `Tool/`, `Work/`, `Schedule/`, `Watcher/`
- Rule: if it has `@Published` or `static let shared`, it does not belong here

**Services** — Business logic. Not observable. Not UI-aware.

- Swift `actor` for concurrent work (ChatEngine, MemoryService)
- Stateless `struct` for pure functions (Router, PromptBuilder)
- Organized into domain subfolders: `Chat/`, `Context/`, `Inference/`, `Method/`, `ModelRuntime/`, `MCP/`, `Memory/`, `Sandbox/`, `Skill/`, `Tool/`, `Voice/`, `Provider/`, `Plugin/`, `Keychain/`
- Rule: services do NOT conform to `ObservableObject` or `@Observable`
- Rule: if it drives UI directly, it is a Manager, not a Service
- Naming: suffix with `Service` or `Engine`

**Managers** — UI state. Observable. Main actor.

- `@MainActor` classes with `@Observable` (preferred) or `ObservableObject`
- Own published properties that SwiftUI views bind to
- Coordinate Services, Stores, and other Managers
- Grouped into `Chat/`, `Model/`, `Plugin/` subfolders; remaining at root
- Rule: managers always run on `@MainActor`
- Naming: suffix with `Manager`

**Views** — SwiftUI. Organized by feature, not by type.

- Each feature has its own subfolder: `Chat/`, `Agent/`, `Model/`, `Plugin/`, `Memory/`, `Voice/`, `Work/`, `Settings/`, `Theme/`, `Skill/`, `Toast/`, `Schedule/`, `Watcher/`, `Identity/`, `Sandbox/`, `Insights/`, `Onboarding/`, `Management/`
- `Common/` holds only generic, reusable primitives (buttons, layouts, glass effects)
- A view that only makes sense in one feature goes in that feature's folder

**Networking** — HTTP server, NIO, routing, relay tunnels, server controller.

**Storage** — SQLite databases and file persistence.

**Tools** — MCP tool definitions, registry, and plugin ABI.

**Identity** — Cryptographic keys and access control.

**Utils** — Cross-cutting helpers with no domain knowledge.

### Where to put new code

| You're adding...            | Put it in...                                 |
| --------------------------- | -------------------------------------------- |
| A new data type or DTO      | `Models/{domain}/`                           |
| Backend logic (no UI)       | `Services/{domain}/` as an actor             |
| UI state that views observe | `Managers/` as `@MainActor` observable class |
| A new screen or panel       | `Views/{feature}/`                           |
| A reusable UI widget        | `Views/Common/`                              |
| A new MCP tool              | `Tools/`                                     |
| A new test                  | `Tests/{matching-source-directory}/`         |

### Naming conventions

| Pattern                    | Name suffix           | Example                            |
| -------------------------- | --------------------- | ---------------------------------- |
| Observable UI state holder | `Manager`             | `AgentManager`, `ToastManager`     |
| Actor-based business logic | `Service` or `Engine` | `MemoryService`, `ChatEngine`      |
| Stateless logic            | `Service` or none     | `PromptBuilder`, `SearchService`   |
| JSON file persistence      | `Store`               | `AgentStore`, `ScheduleStore`      |
| SQLite persistence         | `Database`            | `MemoryDatabase`, `MethodDatabase` |
| SwiftUI view               | `View`                | `ChatView`, `AgentsView`           |
| Test file                  | `Tests` suffix        | `ChatEngineTests`, `MemoryTests`   |

### Tool calling (developer notes)

- OpenAI‑compatible DTOs live in `Models/API/OpenAIAPI.swift` (`Tool`, `ToolFunction`, `ToolCall`, `DeltaToolCall`, etc.).
- Prompt templating is handled internally by vmlx-swift-lm. Osaurus does not assemble prompts manually.
- Tool-call detection lives entirely in vmlx-swift-lm's `BatchEngine.generate`, which emits authoritative `Generation.toolCall(ToolCall)` events. Osaurus's `GenerationEventMapper` simply translates each one into a `ModelRuntimeEvent.toolInvocation`.
- Streaming tool calls reach the wire as OpenAI-style deltas inside `Networking/HTTPHandler.swift` (and the equivalent Anthropic / Open Responses writers in `Models/Chat/ResponseWriters.swift`).

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

### Dependencies

The workspace lockfile at `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`
is the single source of truth for pinned dependency versions. Xcode updates
this file automatically when you add, remove, or update a package. Commit
the changed `Package.resolved` alongside your other changes.

CI resolves dependencies from this committed lockfile and builds with
`-disableAutomaticPackageResolution`, so it uses the exact same versions
you tested locally. If the resolved file is stale relative to
`Package.swift`, CI will fail rather than silently pulling different
versions.

Package-level resolved files (e.g. `Packages/*/Package.resolved`) are
gitignored and not used by CI.

### Testing

- Add or update tests in `Packages/OsaurusCore/Tests/` where reasonable
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

| Document                                                       | Purpose                                                           |
| -------------------------------------------------------------- | ----------------------------------------------------------------- |
| [README.md](../README.md)                                      | Project overview, quick start, feature highlights                 |
| [FEATURES.md](FEATURES.md)                                     | **Source of truth** — feature inventory and architecture          |
| [REMOTE_PROVIDERS.md](REMOTE_PROVIDERS.md)                     | Remote provider setup and configuration                           |
| [REMOTE_MCP_PROVIDERS.md](REMOTE_MCP_PROVIDERS.md)             | Remote MCP provider setup                                         |
| [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md)                       | Insights and Server Explorer guide                                |
| [PLUGIN_AUTHORING.md](PLUGIN_AUTHORING.md)                     | Plugin authoring: tools, routes, storage, config UI, and web apps |
| [OpenAI_API_GUIDE.md](OpenAI_API_GUIDE.md)                     | API usage, tool calling, streaming                                |
| [SHARED_CONFIGURATION_GUIDE.md](SHARED_CONFIGURATION_GUIDE.md) | Shared configuration for teams                                    |

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

- **[Discord](https://discord.gg/osaurus)** — Chat with contributors and maintainers
- **[Good First Issues](https://github.com/osaurus-ai/osaurus/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)** — Great starting points

Thank you for helping make Osaurus better!
