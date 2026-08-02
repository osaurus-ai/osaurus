---
title: Plugins
summary: Extend Osaurus with native tool plugins and imported Claude plugin bundles.
order: 70
---

# Plugins

Plugins add new tools to Osaurus. There are two kinds: native plugins (compiled, from the Osaurus plugin registry) and imported Claude plugins (skills, schedules, commands, and MCP servers bundled from a GitHub repo).

## Native plugins

- Management (⌘⇧M) → Plugins: browse the registry, install, update, uninstall.
- Or ask the default Osaurus assistant to search and install a plugin for you.
- Release plugins must be code-signed; unsigned plugins are refused.
- Some plugins need secrets (API keys): enter them in Settings → Plugins → Secrets — they go to the Keychain, never through chat.
- Plugin activity (every host API call) is logged under Insights → Plugin Activity.

## Claude plugins

- Management → Plugins → Import → enter `owner/repo` or a GitHub URL → pick plugins → Install Selected.
- What maps where: skills → Skills tab; scheduled agents → Schedules (often imported disabled until you confirm the cadence); slash commands → chat; HTTP/SSE MCP servers → Providers; `CLAUDE.md`-style context files attach as skill references.
- After install, a Configure plugin settings sheet appears when the plugin declares user config; sensitive values go to the Keychain.
- Cards show a version pill with Update, Needs setup, View Details, Configure Settings…, and Uninstall. Uninstall removes everything the import created in one shot.
- Not run on import: hooks are ignored and skill-local scripts are attached as text only — nothing executes without you.

## Troubleshooting

- Plugin failed to load? Check the card's error and Insights logs; Retry from the plugin detail page.
- Plugin web UIs opened in a browser need the Open Web App button (it appends the agent id the plugin needs).
- Developers: `osaurus tools create`, `osaurus tools dev` (hot reload), `osaurus tools list` — install the CLI from Settings → Developer.
