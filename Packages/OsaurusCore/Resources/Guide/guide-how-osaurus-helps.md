---
title: How Osaurus Helps
summary: What happens when you ask Osaurus for something — answers, setting changes, your workflows and agents, the built-in helpers, and small workflows built and run on the spot that you can keep.
order: 46
---

# How Osaurus Helps

Ask in your own words. Osaurus decides how to handle each request. You do not have to name a tool, an agent, or a workflow, but you can, and a name you give wins.

## Answers

A question it can answer from what it knows, or from what is already in the conversation, gets a direct answer. Nothing runs.

## Changing Osaurus

Requests about Osaurus itself, such as "switch my default model", "turn off sending on Telegram", or "where is the memory setting?", are handled in the same chat. A question about where something lives gets the exact path in Settings. A change shows an approval card with what will change, and nothing changes until you confirm it.

## Your workflows and agents

When a request clearly matches one of your installed workflows, Osaurus starts it and fills its inputs from your message. The workflow's card in the chat shows each step as it runs. If two workflows fit about equally well, it asks which one you meant. If a workflow needs something your message did not say, it asks for that.

Your own agents are offered the same way. A request that fits one of them runs on that agent, with its model, tools, and folder, and its answer comes back into the chat.

## Built-in helpers

Four helpers come with Osaurus and do one kind of hands-on work each:

- **Research** searches the web and reads pages to answer with sources.
- **Files** reads, searches, writes, and edits files in this chat's working folder. Pick a folder with the Folder chip first. Reading your Downloads folder or Notes is Keeper's job, not this helper's.
- **Browser** opens websites, clicks, types, and reads pages, including sites you are signed in to. It asks before anything sensitive.
- **Code** writes and runs code and shell commands in an isolated sandbox. It works as its own sandbox user, so it needs no custom agent with the sandbox turned on, and starts the Sandbox the first time it's used (macOS 26+). It can write files, run commands, and install packages there; it can't create plugins, run background processes, or call back into Osaurus.

A helper's work shows as a card in the chat, and its result comes back into the conversation.

## Something new that takes several steps

When a request needs several steps together and nothing you have does it ("pull the action items from these notes, then draft the follow-up email"), Osaurus sketches a small workflow of up to five steps and runs it right away. The card reads **Running a workflow** and shows each step.

While the sketch is written, the card shows **Planning**. Writing it gets at least 20 seconds, more on a slower model, and its first step then has ten seconds to start. If either runs out, Osaurus stops waiting for it:

- When one of the helpers clearly fits, that helper does the request instead.
- When two options are close, it asks you which one should handle it.
- When nothing fits, it asks one question about where to start.

A sketch that fails tells you which step failed and why. When the fix is yours to make, the workflow card offers it: **Open System Settings** for a permission, **Choose Folder** when a step needs a folder or a git repository, **Search settings** when a web search failed, and **Choose a Model** when no model can run it.

## Keeping what worked

After a sketch runs successfully, Osaurus offers to keep it as a workflow. Say yes, and the usual **Save** card appears with its name and a summary. Nothing is saved until you click **Save**. The saved workflow then shows in Workflows like any other, and the run from the chat counts as its first test (**Run from chat**).

You can also say nothing about the offer. A sketch you do not keep never shows up in Workflows and is discarded after a day.

To design something bigger, such as many steps, forms, branches, schedules, or a workflow you will share, open **Workflows** and start a new one with the Architect. There you can edit each step and test it before saving.

## Keeping track

Osaurus keeps a short note of what is still open in the conversation, such as an offer it made or a question it is waiting on. That way "yes" or "the second one" refers to the right thing a few messages later. Long conversations stay quick because older exchanges are not all sent along with every message.
