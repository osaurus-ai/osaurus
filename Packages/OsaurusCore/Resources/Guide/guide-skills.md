---
title: Skills
summary: Reusable capability packages that teach agents specialized workflows; import from GitHub or files.
order: 60
---

# Skills

Skills are reusable packages of instructions (plus optional reference files) that teach the model specialized workflows — like a playbook it loads when relevant.

## Built-in skills

Osaurus ships nine: Web Researcher, Content Summarizer, Mac Automator, Personal Organizer, Document Builder, Workspace Assistant, Data Keeper, Autonomous Scheduler, Data Visualizer.

## Using skills

- Skills load on demand automatically during chat — no toggles. Installing a skill puts it in the library for every custom agent; a custom agent can narrow that with **Limit to selected skills** (Agents → the agent → Abilities → Tools).
- Type `/skill-name` in chat to force-load one for a single message.
- Exception: the built-in Osaurus configuration agent does not use skills (it answers questions from its built-in guide instead).

## Managing skills

- Settings… (⌘,) → Skills: tabs **All** / **Custom** / **Claude Plugins**.
- **Add Skill** → **Create Skill**: Name, Description, Category, Keywords, Instructions → Save. Keywords matter — search indexes name + keywords + description, not the instructions body.
- Expand a skill to Edit, Export (`SKILL.md` or ZIP), or Delete. Built-ins are view-only.

## Importing

- From GitHub: **Add Skill** → **Import Claude plugin from GitHub** → enter `owner/repo` → pick skills → **Import N Skills** (discovers via the repo's Claude plugin marketplace manifest). Unauthenticated GitHub rate limit is 60 requests/hour.
- From file: **Add Skill** → **Import Skill** — a `.md`/`SKILL.md` file or a `.zip` (with `SKILL.md` plus optional `references/` and `assets/`).
- From chat: paste a `SKILL.md` link, a GitHub link, or the skill's text and ask Osaurus to set it up. A review card lists what was found before anything installs; see the Importing from Chat topic. In a New Agent chat, the skill installs when you click Create Agent.

## On disk and caveats

- Stored at `~/.osaurus/skills/<skill-name>/SKILL.md` (plus `references/`, `assets/`; reference files up to 100 KB each).
- Skills auto-load when the agent's Tools are on in **Auto** tool mode; **Custom** tool mode won't auto-load them.
- A brand-new skill may need a new chat to enter the session manifest — or force it with `/skill-name`.
