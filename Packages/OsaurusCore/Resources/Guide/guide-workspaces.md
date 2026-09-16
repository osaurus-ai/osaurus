---
title: Workspaces and Shared Agents
summary: Share agents with teammates through the relay, chat with theirs, and let the Orchestrator delegate to them.
order: 176
---

# Workspaces and Shared Agents

A workspace is a group of people (Management ⌘⇧M → Workspaces) with a shared credit pool and a roster of **shared agents**: agents members chose to make reachable to the others. A shared agent keeps running on its owner's Mac; teammates talk to it through the Osaurus relay (Mode 2) — nothing about the agent is copied, and the owner's files never leave their machine.

Workspaces need an Osaurus identity (see the Identity topic) and Osaurus Router turned on; the same identity on two of your own devices sees the same workspaces.

## Sharing and the roster

- **Members** join through invite links the owner or an admin creates; the roster shows every member and their shared agents with online/offline presence. Roles: owner, admin, member (all three can share agents), viewer (chat only).
- **Share agent** (Workspaces → *workspace* → Shared Agents) publishes one of your agents to the workspace; **Unshare** revokes it for everyone at once. Each shared agent has a **Bill the workspace pool** switch: on, the cloud calls it makes for teammates draw from the pool instead of your balance.
- **Workspace pool** is the shared balance on the overview; pool-billed runs show up there. A paused or suspended workspace pauses invites, shared agents, and pool-billed inference until the owner renews.
- Leaving a workspace drops your access to its shared agents and pool and revokes the agents you shared.

## Chatting with a teammate's agent

Pick the agent from the roster (**Chat**) or from the chat sidebar, where shared agents are listed with your own. The chat streams from the teammate's Mac; presence tells you whether it is reachable right now. Your own agents on another of your devices appear as "Yours · other device" and work the same way.

On the hosting side, a run a teammate asked for opens as a tab on the shared agent's chat and is listed in Settings → Orchestrator → Delegations → **Received** (caller, agent, duration, status, Open Chat).

## The Orchestrator and shared agents

Teammates' shared agents are delegation targets like your own agents:

- **Auto-join.** As a workspace roster loads, every shared agent not hosted on this Mac joins Settings → Orchestrator → Subagents → Allowed subagents. Remove one and it stays removed — even if the teammate re-shares it — until you add it back. Unsharing, leaving, or a teammate leaving prunes it from the pool. The per-workspace switch **Let the Orchestrator delegate to shared agents** (Workspaces → *workspace* → Shared Agents; declaratively `delegation.workspace_auto_join`) turns auto-join off for one workspace and removes its agents from the pool.
- **Naming.** The Orchestrator addresses shared agents as `Name@Workspace` (workspace display name or id). A bare name works while it is unique; when it collides with another agent the tool reports the exact forms to use. `osaurus_inspect` scope `shared_agents` lists name, owner, workspace, presence, whether the agent is in the pool, and the exact `target` string; scope `workspaces` lists your workspaces. Edit the pool with `osaurus_config` `delegation.spawnable_workspace_agents` using the same spelling.
- **Permission.** Shared agents have their own control, **Permission for shared (workspace) agents**, default **Ask**: the run leaves your Mac and spends that workspace's pool on the teammate's side. One card covers every shared agent in a wave (local agents on Always Allow in the same wave are not re-asked), and the card names the agent, owner, and workspace. Always Allow on that card persists only the workspace kind.
- **What the agent sees.** Only the task text. A shared agent runs on its owner's Mac and cannot see your working folder or chat, so the Orchestrator puts everything the agent needs into the task.
- **What comes back.** The agent's final answer as a digest, plus any **small files** it shared with `share_artifact` (a few MB in total), which appear as artifact cards on your chat exactly like a local worker's. Larger files and anything it wrote to disk stay on the teammate's Mac; the agent is told to say so and summarize instead.
- **Follow-ups.** `spawn_agent` `continue: <session_id>` reattaches to the same remote session, so "one more thing" keeps the teammate agent's context. A worker that ends with `NEEDS INPUT:` is answered the same way.
- **Offline.** If the agent's host is not connected to the relay, the delegation is refused before anything runs with the reason (and when it was last seen); the Orchestrator picks another agent or tells you. Presence never changes the Orchestrator's prompt, so a teammate going offline does not invalidate cached context.

Limits for shared-agent runs are the host's own agent limits; your side keeps only the time limit. Received runs on your Mac follow *your* agent's settings and permissions.

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
