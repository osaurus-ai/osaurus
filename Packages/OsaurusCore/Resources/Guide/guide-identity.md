---
title: Identity, Pairing, and Access Keys
summary: Cryptographic identity for you and your agents; pair devices and issue revocable access keys.
order: 175
---

# Identity, Pairing, and Access Keys

Osaurus gives every participant — you, each agent, and each device — a cryptographic address. External clients authenticate with signed, revocable keys instead of shared passwords, and nothing depends on a central server.

## The pieces

- **Master address** — your root identity, generated on your Mac and stored in iCloud Keychain behind Face ID / Touch ID. All authority flows from it.
- **Agent addresses** — each agent can be assigned its own address derived from the master. Assign, rotate, or revoke them under Privacy & Security → Identity; rotation and revocation automatically invalidate keys issued for the old address.
- **Device ID** — a hardware-bound identity (Secure Enclave attestation) proving which physical device is making a request.

## Backup and recovery

- On setup you are shown a 24-word recovery phrase exactly once — copy, save, or print it. It is the only way to rebuild your master key if the Keychain entry is lost.
- The Identity view shows a warning banner until you confirm the phrase is saved, and offers explicit "Reset Identity" and "Recover from phrase" flows. Your identity is never silently replaced.

## Access keys (osk-v1)

- Portable tokens (`osk-v1.…`) that let external tools, MCP clients, and remote agents authenticate against your Osaurus server without biometrics.
- **Master-scoped** keys grant access to all agents; **agent-scoped** keys work only for one agent (cross-agent requests are rejected).
- Expiration options: 30 days, 90 days, 1 year, or never (explicit opt-in only). The full key is shown once and never stored — only metadata (label, prefix, dates) is kept.
- Generate master-scoped keys under Server → Access Keys; agent-scoped keys come from the agent's row in the Identity view (or from pairing). Revocation takes effect immediately, no server restart needed.

## Pairing

Another device on your network can request access via the secure pairing flow: it discovers your Mac over Bonjour, you approve the request (choosing the agent and duration), and it receives an agent-scoped access key — 90-day expiry by default. A whitelist controls which external addresses may hold keys, globally or per agent.

## Notes

- Identity is optional for local, in-app use — it matters when you expose the server or channels to other devices and services.
- All key material lives in the macOS Keychain; nothing is uploaded anywhere.
