---
title: Identity, Pairing, and Access Keys
summary: Cryptographic identity for you and your agents; pair devices and issue revocable access keys.
order: 175
---

# Identity, Pairing, and Access Keys

Osaurus gives every participant — you, each agent, and each device — a cryptographic address. External clients authenticate with signed, revocable keys instead of shared passwords, and nothing depends on a central server.

## The pieces

- **Master Address** — your root identity, generated on your first device and stored in iCloud Keychain behind Face ID / Touch ID. All authority flows from it.
- **Agent Addresses** — each agent can be assigned its own address derived from the master and the device it was created on. Assign, rotate, or revoke them under Settings… (⌘,) → Osaurus ID; rotation and revocation automatically invalidate keys issued for the old address.
- **Device ID** — a hardware-bound identity (Secure Enclave attestation) proving which physical device is making a request. Every device gets its own on first launch, including devices that picked up your identity from iCloud or a recovery phrase.

## One identity, many devices

- Set up the same identity on another device by letting iCloud Keychain sync it or by entering your recovery phrase there. Both devices are then the same person: same workspace memberships, same access.
- Agents created on each device get their own unique addresses — the same "agent #1" on two devices is two different agents and never collides at the relay.
- In a workspace, agents running on your other device show up as "Yours · other device" and you chat with them through the relay like a teammate's agent. Agents running on the device you're using open locally.
- An agent lives on one device at a time. If the same agent's Remote Access is turned on from a second machine (for example after copying a backup), the newer one serves it and the other shows **On another Mac** (Sharing → Access → Remote Access); use **Serve From This Mac** to take it back.
- A device that holds your identity can request access to an agent hosted on another of your devices directly — no workspace or invite needed. It proves it holds the master key by signing a one-time challenge; the host then issues a 90-day agent-scoped access key labelled "Owner device – <device name>", which shows up in that agent's key list and can be revoked like any other.
- Rotating an agent's key moves everything that pointed at the old address: its Remote Access reconnects with the new one and every workspace share is re-issued. Access keys for the old address stop working; other devices and teammates re-request access automatically.
- If an agent's address was saved by an older version of Osaurus that did not know about device-scoped addresses, the Identity view restores the missing device scope automatically when it can reproduce the address. No keys change and nothing needs to be re-shared.
- The built-in Default agent is never reachable from another device.

## Backup and recovery

- On setup you are shown a 24-word recovery phrase exactly once — copy, save, or print it. It is the only way to rebuild your master key if the Keychain entry is lost.
- The Identity view shows a warning banner until you confirm the phrase is saved, and offers explicit "Reset Identity" and "Recover from phrase" flows. Your identity is never silently replaced.

## Access keys (osk-v1)

- Portable tokens (`osk-v1.…`) that let external tools, MCP clients, and remote agents authenticate against your Osaurus server without biometrics.
- **Master-scoped** keys grant access to all agents; **agent-scoped** keys work only for one agent (cross-agent requests are rejected).
- Expiration options: 30 days, 90 days, 1 year, or never (explicit opt-in only). The full key is shown once and never stored — only metadata (label, prefix, dates) is kept.
- Generate master-scoped keys under Server → Access Keys; agent-scoped keys come from the agent's row in the Identity view (or from pairing). Revocation takes effect immediately, no server restart needed.

## Pairing

Other people reach one of your agents through a guest link (**Share Agent** → **Guest link** on the agent in Settings… (⌘,) → Agents) or a workspace (see the Workspaces topic); each redeemed guest link gets an agent-scoped access key, and everyone holding one is listed under Settings… (⌘,) → Sharing → Access → **Guests**. Your own Macs and your iPhone use Sync instead: add them under Settings… (⌘,) → Sharing → Devices (see the Sync topic). Osaurus no longer advertises agents on the local network, and keys from the old local-network pairing keep working until they expire or you revoke them. A whitelist controls which external addresses may hold keys, globally or per agent.

## Sign in with Osaurus

Osaurus websites, such as store.osaurus.ai, can offer **Log in with Osaurus**. Clicking it opens Osaurus, which asks "Sign in to store.osaurus.ai?" and shows the exact website address. Choose **Continue**, then confirm with Touch ID (or your password on a Mac without Touch ID). Osaurus signs a one-time login with your master key and sends it back to that website in your browser.

- The website receives your master address and, if you have one, your Osaurus ID. It never receives your keys, chats, or files.
- Each login is good for that one website, for five minutes, and only once. A login for one site does not work on any other.
- Only Osaurus's own websites can ask. A request from any other site is refused before you see a prompt.
- **Cancel**, closing the prompt, or ignoring it for two minutes tells the website you declined. If this Mac has no identity yet, Osaurus opens Settings… (⌘,) → Osaurus ID so you can set one up.
- Settings… (⌘,) → Osaurus ID → **Sign In with Osaurus** lists recent sign-in requests (**Recent Sign-ins**) and has **Clear history**. Signing out happens on the website.

## Notes

- Identity is optional for local, in-app use — it matters when you expose the server or channels to other devices and services.
- All key material lives in the Keychain; nothing is uploaded anywhere.
