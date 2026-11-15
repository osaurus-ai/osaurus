---
title: Slash Commands
summary: Type /name in chat to run built-in actions, insert reusable prompt templates, activate a skill, or open one of the agent's workflows.
order: 55
---

# Slash Commands

Type `/` in the chat input to open the command popup. Commands are named shortcuts: some run a built-in action, some paste a prompt template you finish typing, and some activate a skill for the next message.

## Built-in commands

- `/clear` — clear the current conversation.
- `/model` — open the model picker.
- `/agent` — switch the active agent.
- `/screenshot` — capture the current screen as a chat artifact.
- `/title` — generate a title for this chat.
- `/compact` — summarize older messages now to free up context (same as **Compact conversation** in the context budget popover). Useful right before sending something large into an already-full chat.
- `/help` — show available commands and shortcuts.

Built-ins are fixed and cannot be edited or deleted.

## Custom commands

- Create them in Settings… (⌘,) → Commands → New Command: pick a name, a description, an icon, and a template.
- Typing `/name` in chat replaces the token with your template, and you keep typing from there. Examples: `/translate` → "Please translate the following to Spanish:", `/summarize` → "Summarize the following in 3 bullet points:".
- Custom commands are stored on disk and survive restarts; edit or delete them from the same tab.

## Skill commands

Skills can register a command of their own — invoking it activates that skill for the next sent message (its instructions are injected into the system context). See the Skills topic.

## Workflow commands

The workflows turned on for the current agent (Settings → Agents → (agent) → Abilities → **Workflows**) appear by name, e.g. `/client-intake`. Picking one opens that workflow's tab, where you fill in its input and press Run. See the Workflows topic.

## Plugin commands

Imported plugins (including Claude plugin bundles) can install their own slash commands. They show a plugin origin and are removed together when the plugin is uninstalled.

## Notes

- The assistant can list and describe commands (`osaurus_inspect` with `action: list`, `scope: commands`), but creating and editing them is done in the Commands tab.
