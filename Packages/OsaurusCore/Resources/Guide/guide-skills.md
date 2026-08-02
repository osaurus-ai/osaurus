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

- Skills load on demand automatically during chat — no toggles, no per-agent assignment. Installing a skill puts it in the library for every custom agent.
- Type `/skill-name` in chat to force-load one for a single message.
- Exception: the built-in Osaurus configuration agent does not use skills (it answers questions from its built-in guide instead).

## Managing skills

- Management (⌘⇧M) → Skills: filter by All / Built-in / Yours / From Plugins.
- Create Skill: Name, Description, Category, Keywords, Instructions → Save. Keywords matter — search indexes name + keywords + description, not the instructions body.
- Expand a skill to Edit, Export (JSON, Markdown, or ZIP), or Delete. Built-ins are view-only.

## Importing

- From GitHub: Import → From GitHub → enter `owner/repo` → pick skills → Import Selected (discovers via the repo's Claude plugin marketplace manifest). Unauthenticated GitHub rate limit is 60 requests/hour.
- From file: Import → From File — `.md`/`SKILL.md`, `.json`, or `.zip` (with `SKILL.md` plus optional `references/` and `assets/`).

## On disk and caveats

- Stored at `~/.osaurus/skills/<skill-name>/SKILL.md` (plus `references/`, `assets/`; reference files up to 100 KB each).
- Skills require the agent's tool mode to be Auto with tools enabled; Manual tool mode won't auto-load them.
- A brand-new skill may need a new chat to enter the session manifest — or force it with `/skill-name`.
