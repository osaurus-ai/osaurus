---
title: Workspaces and Shared Agents
summary: Share agents and workflows with teammates, chat with their agents, and let the Orchestrator and workflows delegate to them.
order: 176
---

# Workspaces and Shared Agents

A workspace is a group of people (Settings… (⌘,) → Sharing → Workspaces) with shared **workspace credits** and a roster of **shared agents**: agents members chose to make reachable to the others. A shared agent keeps running on its owner's Mac; teammates talk to it over the agent's Remote Access. Nothing about the agent is copied, and the owner's working folder stays on their machine; the only files that travel back are small ones the agent hands over with `share_artifact` (see "What comes back" below).

Workspaces need an Osaurus identity (see the Identity topic) and Osaurus Router turned on; the same identity on two of your own devices sees the same workspaces.

## Sharing and the roster

- **Members** join through invite links the owner or an admin creates; the roster shows every member and their shared agents with online/offline presence. Roles: owner, admin, member (all three can share agents), viewer (chat only).
- **Share agent** (Workspaces → *workspace* → Shared Agents) publishes one of your agents to the workspace; **Unshare** revokes it for everyone at once. Teammates' runs of a shared agent always use workspace credits. Each agent you share also has a **Bill Workspace Credits** switch for *your own* chats with it (also in **Share Agent** → **Workspace**) — on by default once the agent is shared, so your cloud calls use workspace credits too; turn it off to bill them to your personal balance instead. The composer's credits chip shows which balance a chat is spending.
- **Workspace Credits** is the shared balance on the overview; runs billed to it show up there. A paused or suspended workspace pauses invites, shared agents, and inference billed to workspace credits until the owner renews. The host enforces it too: while a workspace is suspended, your Mac refuses teammates' new runs of the agents you shared there, even ones on a local model, with "This workspace is suspended, so its shared agents are paused until the owner renews it", and records the refusal in the audit log.
- Leaving a workspace drops your access to its shared agents, workflows, and workspace credits, revokes the agents you shared, and takes the workflows and agent templates you shared out of its **Workflows** list. If your app can't say so (it's offline, or an owner or admin removed you), store.osaurus.ai takes them out on its own within a few minutes.
- One person who isn't in a workspace can get one agent through a guest link instead (**Share Agent** → **Guest link**); they are listed under Sharing → Access → **Guests**, not in the roster.

## Chatting with a teammate's agent

Pick the agent from the roster (**Chat**) or from the workspace's group in the chat sidebar: click the agent to see your chats with it, or use its **+** (or the group's **+**) for a new one. The chat streams from the teammate's Mac; presence tells you whether it is reachable right now. Your own agents on another of your devices appear as "Yours · other device" and work the same way.

On the hosting side, a run a teammate asked for opens as a tab on the shared agent's chat and is listed in Settings → Agents → Orchestrator → Delegations → **Received** (caller, agent, duration, status, Open Chat). The tab is titled with the caller's handle and short Osaurus ID (`@alice · 0x9C3e…11aa → Research Agent`); a teammate's agent calling yours shows its name, address and owner (`Scout · 0x77d0…19be · @bob's agent`). A guest shows the handle they claimed for their Osaurus ID when they have one, looked up from Osaurus Router and remembered for a while; otherwise their short Osaurus ID.

## Approving a teammate's tool calls

A teammate cannot answer your approval cards, so by default a tool that needs approval fails in their run. Turn on **Require Approval for Teammate Tool Calls** (Workspaces → *workspace* → Shared Agents, on each agent you host; declaratively `agents[].shared_tool_approval: {mode: ask_owner, timeout_seconds: 600}`) and the run waits for you instead:

- An **Approval needed** card appears in the hosted conversation, a desktop notification offers **Allow**, **Allow for This Conversation** and **Deny**, and your iPhone lists it too. The first answer wins; the others disappear.
- Your other synced devices list it too (see the Sync topic): answer there and your Mac that runs the agent applies it when it's awake. The timeout still runs on that Mac.
- The teammate sees "Waiting for @you to allow *tool*" in their chat, then the run continues or the tool reports it was declined.
- Nobody answers within **Decline Unanswered Requests After** (below the switch, available once it is on; 10 minutes by default): the call is declined and the agent continues without it.
- **Allow for This Conversation** covers that tool for that caller in that conversation only, and lasts until the conversation is deleted (also across restarts). Tools that write or edit files ask on every call. There is no "Always Allow" for teammates.
- With the switch on, the agent can also ask you a question during a teammate's run (`ask_owner`). It reaches you the same way, with **Reply**; your answer goes back to the agent.
- Everything waiting on you is also in **Inbox** → **Needs You** in the Osaurus window's sidebar (what you answered is in Insights → Interactions), and the chat waiting on you shows **Needs your input** under its agent in the workspace's sidebar group (a folded group shows it on its header).
- Tools you set to **Deny**, and tools never allowed for remote callers (such as shell and git), stay blocked; approval can't unlock them.

Where approval requests reach you is Settings → General → Notifications → **Approvals**. Each request and answer is recorded in Insights → **Interactions** and the workspace audit log.

## Joining a teammate's conversation

A teammate's conversation with your agent can become a three-way one. Open its tab on your Mac and type in the line under the transcript (**Message *caller* and your agent as yourself…**):

- What you write joins the transcript as yours, labelled with your handle. A run in progress reads it at its next step; otherwise the agent sees it on the teammate's next message.
- The teammate sees it in their chat as a message from you (`@you`): live while a run is going, otherwise when their Osaurus next checks the conversation (within seconds while it is active, at most every two minutes while it is open and quiet). Their Mac also raises it as an inbound message. Older Osaurus versions show it on the teammate's next message.
- A message is limited to 16,384 characters.
- The agent treats your words as the owner's. A teammate's words, and another agent's, are labelled with who said them and treated as untrusted, the way channel messages are.
- Lines such as "@alice · 0x9c3e…11aa started a conversation with Research Agent" and "You allowed web_fetch for @alice · 0x9c3e…11aa · iPhone" sit between the turns; they are for you and never sent to the model. **View in Insights** on one opens its record.
- Your own iPhone's chats with your agents don't offer this line; they are already yours.
- The conversation is on your other synced devices too, under **On *Mac*** for the Mac that ran it. Writing there works the same way; your message shows **Waiting for *Mac*** until that Mac delivers it, and the teammate sees it labelled with the device you wrote on.

Each message you write is recorded in Insights → **Interactions** (the text only while **Store Prompts and Responses** is on) and as metadata in the workspace audit log.

## The Orchestrator and shared agents

Teammates' shared agents are delegation targets like your own agents:

- **Auto-join.** As a workspace roster loads, every shared agent not hosted on this Mac joins Settings → Agents → Delegation → Allowed subagents. Remove one and it stays removed — even if the teammate re-shares it — until you add it back. Unsharing, leaving, or a teammate leaving removes it from Allowed subagents. The per-workspace switch **Let the Orchestrator delegate to shared agents** (Workspaces → *workspace* → Shared Agents; declaratively `delegation.workspace_auto_join`) turns auto-join off for one workspace and removes its agents from Allowed subagents.
- **Naming.** Shared agents are addressed as `Name@Workspace` (workspace display name or id); the Orchestrator hands them work by that name through `run_workflow`. A bare name works while it is unique; when it collides with another agent the tool reports the exact forms to use. Ask "who can I delegate to?" and the Configurator lists them (with `osaurus_inspect` scope `shared_agents`: name, owner, workspace, presence, whether the agent is in Allowed subagents, and the exact `target` string; scope `workspaces` lists your workspaces). The Configurator edits the list with `osaurus_config` `delegation.spawnable_workspace_agents` using the same spelling.
- **Permission.** Shared agents have their own control, **Permission for shared (workspace) agents**, default **Ask**: the run leaves your Mac and spends that workspace's credits on the teammate's side. One card covers every shared agent in a wave (local agents on Always Allow in the same wave are not re-asked), and the card names the agent, owner, and workspace. Always Allow on that card persists only the workspace kind.
- **What the agent sees.** Only the task text. A shared agent runs on its owner's Mac and cannot see your working folder or chat, so the Orchestrator puts everything the agent needs into the task.
- **What comes back.** The agent's final answer as a digest, plus any **small files** it shared with `share_artifact` (at most 16 files and 4 MB in total; your Osaurus refuses anything past that whatever the host sends), which appear as artifact cards on your chat exactly like a local worker's. Larger files and anything it wrote to disk stay on the teammate's Mac; the agent is told to say so and summarize instead.
- **Follow-ups.** A custom agent that delegates with `spawn_agent` uses `continue: <session_id>` to reattach to the same remote session, so "one more thing" keeps the teammate agent's context. A worker that ends with `NEEDS INPUT:` is answered the same way.
- **Offline.** If the agent's host is not reachable (its Remote Access is off or disconnected), the delegation is refused before anything runs with the reason (and when it was last seen); the Orchestrator picks another agent or tells you. Presence never changes the Orchestrator's prompt, so a teammate going offline does not invalidate cached context.

Limits for shared-agent runs are the host's own agent limits; your side keeps only the time limit. Received runs on your Mac follow *your* agent's settings and permissions.

## Workflows and workspaces

There are three ways a workspace uses workflows; pick by where the work should run and whose keys it should use. Main window → Workflows → **Workspaces** shows what each of your workspaces offers, both kinds, in one place.

- **Give teammates their own copy.** Publish a workflow or an agent template with **Who can see it** → **Workspace** (its Share sheet; Main window → Workflows, or Agents → Templates) and tick the workspaces. It is not on the store and not reviewed. Owners, admins, and members can share; viewers can only install.
- **Install a teammate's.** Main window → Workflows → **Workspaces** (or Workspaces → *workspace* → **Workflows**) lists what members shared, with the author, version, and **Installed** or **Update**. **Install** goes through the usual import review and setup, and the copy runs on your Mac with your own keys, models, and connections. Copies keep working after a listing is removed. The author, and the workspace's owners and admins, can remove a listing (**Remove from workspace**). A suspended workspace can't install.
- **Let teammates run yours on your Mac.** On a workflow one of your shared agents has turned on (Agents → the agent → Abilities → **Workflows**), turn on **Teammates can run this** (the workflow's page, **Who Can Start It**). Each call then waits for your approval through the agent's **Require Approval for Teammate Tool Calls**. The run uses your keys, connections, and folders; the teammate gets its output. Without the switch the call is refused. Teammates see it in their Workflows → **Workspaces** as **Runs on *your name*'s Mac** and can **Add to My Workflows**, so their own agents call it too; every such run still asks you. Each start, finish, and refusal is in the workspace audit log and in Insights → **Interactions** with who asked; runs an invite-link guest starts are listed there too (they have no workspace audit log).

A workflow can also hand work *to* a teammate's shared agent with an **Agent** step: the step sends only its task text to the agent on their Mac and gets the answer and any small shared files back. It asks first unless **Permission for shared (workspace) agents** is Always Allow; see the Workflows topic.

## Declarative

```yaml
delegation:
  spawnable_workspace_agents: [Research@Acme, "Writer@Beta Team"]
  workspace_auto_join:
    Acme: true
  permission_defaults:
    spawn_workspace: ask
```

See the Declarative Configuration topic for the full `delegation` section and The Orchestrator topic for the local side of delegation.
