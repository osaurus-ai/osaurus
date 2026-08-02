---
title: Slash Commands
summary: Type /name in chat to run built-in actions, insert reusable prompt templates, or activate a skill.
order: 55
---

# Slash Commands

Type `/` in the chat input to open the command popup. Commands are named shortcuts: some run a built-in action, some paste a prompt template you finish typing, and some activate a skill for the next message.

## Built-in commands

- `/clear` — clear the current conversation.
- `/model` — open the model picker.
- `/agent` — switch the active agent.
- `/screenshot` — capture the current screen as a chat artifact.
- `/help` — show available commands and shortcuts.

Built-ins are fixed and cannot be edited or deleted.

## Custom commands

- Create them in Management (⌘⇧M) → Commands → New Command: pick a name, a description, an icon, and a template.
- Typing `/name` in chat replaces the token with your template, and you keep typing from there. Examples: `/translate` → "Please translate the following to Spanish:", `/summarize` → "Summarize the following in 3 bullet points:".
- Custom commands are stored on disk and survive restarts; edit or delete them from the same tab.

## Skill commands

Skills can register a command of their own — invoking it activates that skill for the next sent message (its instructions are injected into the system context). See the Skills topic.

## Plugin commands

Imported plugins (including Claude plugin bundles) can install their own slash commands. They show a plugin origin and are removed together when the plugin is uninstalled.

## Notes

- The assistant can list and describe commands (`osaurus_list scope=commands`), but creating and editing them is done in the Commands tab.
