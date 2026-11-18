---
title: Sync Between Your Devices
summary: What syncs between your Macs and your iPhone, how adding a device differs from Workspaces and guest links, recovery phrases, and common questions.
order: 172
---

# Sync Between Your Devices

Sync (Settings… (⌘,) → Sharing → Devices) keeps your chats on all your Macs and lets your iPhone use your Macs' agents. It is end-to-end encrypted and needs no account: your devices form one sync account when you add them, and only they can read it. Devices find each other on the same network with **Same Network** (the default), or anywhere with **Anywhere (Beta)**, which also connects through Osaurus servers.

## What syncs

- **Chats you start** in the chat window, with their attachments, titles, folders and settings.
- **Conversations teammates and your iPhone have with your agents.** They appear on all your devices, under **On <Mac>** for the Mac that ran them. From any of them you can speak in a teammate's conversation and answer its approvals; your Mac that runs the agent delivers them when it's awake. They never appear in the teammate's sync. Conversations from your iPhone are there to read: you can't speak in them from your Macs.
- **Your agents' availability.** With **Run Agents for My Other Devices** on (the default), each Mac lists its agents in the chat sidebar of your other devices under **On <this Mac>**. Picking one there chats with it while it runs on that Mac, with that Mac's models, tools, memory and files. Your iPhone sees the same list plus each Mac's Default agent.
- **What needs you, for your iPhone.** The requests listed in Inbox → **Needs You** (tool approvals, questions, workflow forms, a teammate's tool call, configuration changes, Computer Use steps, and the Privacy Filter's review of a chat you're having on the iPhone) also reach your iPhone when its row in Settings → General → **Notifications** includes **iPhone**. Answering on either one clears the other. The iPhone sees what it's asked to allow: the tool call's arguments, the configuration plan, the Computer Use step, or what the Privacy Filter found. Secret values are never sent this way.

**This Mac only:** chats from the HTTP API, plugins, channels, automations, schedules, watchers, webhooks, email and delegation. The chat sidebar marks them **This Mac only**. Agents' settings, memory, tools and files never copy; your other devices send their chats to the Mac that runs the agent.

## Adding a device, Workspaces, and guest links

These are separate, and turning one on never turns on another:

- **Add a Device** is for your own Macs and your iPhone. **Add a Device** → **Show Code** on a Mac, then scan the code with the Osaurus iPhone app, or paste the pairing link into **Join Another Device** → **Join…** on the other Mac. The code works for 5 minutes. Joining asks you to confirm, since this Mac's chats move to the other device's account; use only a link shown on your own device's screen. Then both devices show **Check the Number** with the same six digits: look at the other device, choose **Numbers Match** on both if they're the same, or **They're Different** to stop. Both devices need the latest Osaurus to pair. If the code was wrong or expired, or the other device can't be reached, Devices says which. Your iPhone shows in **Devices** like any other device, and **Remove Device…** in its … menu removes it. The confirmation's default, **Remove and Change Phrase**, also changes the recovery phrase: a removed device still holds your account's secret until the phrase changes. The new phrase shows at the top of Devices under **Write Down Your New Recovery Phrase** until you choose **I Wrote It Down**. Choose **Remove Only** for a device you've wiped. Showing a code or the recovery phrase, removing a device, restoring and signing out ask for Touch ID or your login password first.
- **Workspaces** (Settings… (⌘,) → Sharing → Workspaces) share agents with other people, one agent at a time, over that agent's Remote Access. See the Workspaces topic.
- **Guest links** (**Share Agent** → **Guest link**) give one person access to one agent. Everyone holding one is listed in Settings… (⌘,) → Sharing → Access → **Guests**.

Osaurus no longer advertises individual agents on the local network; nothing else on your network sees your agents.

## Recovery

Sync has a 24-word recovery phrase (**Recovery** → **Recovery Phrase** → **Show**). If this Mac loses its sync keys, the phrase, or another paired device that still has the chats, gets them back.

When this Mac has an Osaurus ID, the Osaurus ID's recovery phrase can restore sync too, so you keep one phrase. Creating or restoring an Osaurus ID on a Mac with no other sync devices links them automatically; otherwise **Use My Osaurus Recovery Phrase** → **Use…** links them, and your other devices stop syncing with this Mac until each does the same. Removing a device with **Remove and Change Phrase** ends the link and gives sync its own phrase again.

## Your iPhone

- Your iPhone chats with an agent on one of your Macs while that Mac is awake and **Run Agents for My Other Devices** is on. **Keep Mac Awake for iPhone** (Sharing → Devices → **iPhone**) stops idle sleep while an iPhone is in the account.
- With **Same Network**, your iPhone reaches your Mac only on the same Wi-Fi. The first time an iPhone joins, the Mac asks once whether to turn on **Anywhere (Beta)**; **Not Now** keeps Same Network, and **Find Devices** (Sharing → Devices) changes it later. When it can't reach a Mac, the iPhone says whether that Mac is asleep, only on the same network, or out of reach.
- When an agent run from your iPhone needs approval, the approval card appears in that chat on the iPhone, with **Allow**, **Allow for This Conversation**, **Always Allow** and **Deny**. When it needs a secret, the iPhone asks for it and sends it encrypted to that Mac only; it is never written into your synced chats.
- Your iPhone can create agents, edit their settings and tools, change the default model and delete agents on a Mac; the Mac applies each change the same way as its own Agents page.
- For one release, an Osaurus iPhone app that doesn't offer Sync yet can still pair with a 6-digit code under Sharing → Devices → **Mobile**, with **Remote Access for This iPhone** and **Keep Mac Awake for This iPhone** there. Its approvals, questions and secret requests show on that iPhone and on this Mac; the first answer wins. When an iPhone joins with **Add a Device**, this Mac turns the 6-digit pairing off: it revokes the old iPhone key and turns off the Remote Access that pairing turned on (Remote Access you turned on for a workspace, a guest link or a webhook stays on). The **Mobile** page then says the iPhone uses Sync.

## Questions

**Does adding a device share all my agents?** Yes, every agent except the built-in ones (your iPhone also gets the Default agent), as long as **Run Agents for My Other Devices** is on. There's no per-agent choice. The agents' settings, memory, tools and files don't copy: your other device sends its chats to the Mac that runs them. Chats you start sync; headless chats don't. Adding a device only covers your own devices, never other people.

**Does a device on my network find my agents automatically?** Only devices already added to your sync account. They find each other with **Same Network**, or anywhere with **Anywhere (Beta)**. Nothing else on the network sees your agents.

**Why aren't my devices connecting, or why is history slow?**
- With **Same Network**, devices on different networks never meet. After a while Devices shows **Your Devices Aren't Connecting**; **Use Anywhere** switches this Mac, and each other device needs the same setting.
- **Older Messages** shows how many chats are still downloading their history. New messages sync first; older ones wait while the network is metered or in Low Data Mode, or Low Power Mode is on.
- A device **Connected through a relay server** syncs normally, just with more delay than one **Connected directly**.

**Can Workspaces choose which agents to share?** Yes, one agent at a time. That is sharing with other people over the agent's Remote Access, and it is separate from sync: turning on sync never shares an agent with a workspace.

**If I lose my Keychain, are my chats gone?**
- Not if you have a way back: the sync recovery phrase (or your Osaurus recovery phrase once linked), another paired device that still has the chats (pair this Mac again), or, with a linked Osaurus ID still in iCloud Keychain, **Unlock With My Osaurus Recovery Phrase**.
- Without any of those, the chats on this Mac stay locked. They're unreadable, not deleted.
- Other local data (memory, file history, tool and automation databases, and the pre-sync chat backup) uses this Mac's storage key in its Keychain, which a phrase can't recover. Export a plaintext backup (Privacy & Security → Data & Storage) before reinstalling macOS.

**How do Workspaces and Remote Access fit with sync? Where do those conversations live?** Sync never runs anything on someone else's Mac.
- Your side of a chat with a teammate's agent is an ordinary chat, so it syncs to your other Macs. Each of your Macs connects to the teammate's agent itself. An agent shared with you through a guest link is added per device: on another Mac the history shows, but continuing there needs the link redeemed on that Mac.
- The owner's side, a conversation a teammate had with your agent, syncs to all your devices, labeled with the teammate and the Mac that served it. From any of them you can speak in it and answer its approvals; the serving Mac delivers them. It never enters the teammate's sync: their copy is their own chat.
- These are two different networks. An agent's Remote Access uses the Osaurus agent relay (`*.agent.osaurus.ai`) and the router. Sync's **Anywhere (Beta)** uses Osaurus servers of its own and only carries your own devices' sync. Neither carries the other's traffic.

**Does it work with older versions of Osaurus?**
- Workspaces, guest links and Remote Access chats are unchanged: a teammate on an older build can still chat with your shared agent, and you with theirs.
- Your other Macs on builds from before sync don't sync. They still reach your agents the old way for now.
- A synced Mac on an older sync build receives teammates' conversations but lists them with its own agents, may still let you send in them, and shows no approval cards or waiting state until it updates.
- Older Mac builds that paired with this Mac over the local network can't pair that way anymore. An Osaurus iPhone app that still uses the 6-digit code keeps working through Devices → **Mobile** until an iPhone joins with **Add a Device**; after that it's asked to update.
- Going back to a build from before sync shows your chats from before sync, from the untouched backup. Chats started since then live only in sync, so they stay behind until you upgrade again.
