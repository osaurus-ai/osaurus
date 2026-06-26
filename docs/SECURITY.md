# Security Policy

We take the security of Osaurus seriously. If you believe you have found a security vulnerability, please follow the process below.

## Supported versions

- `main` (development) — actively maintained
- The latest tagged release — actively maintained

Older releases may not receive security updates.

## Reporting a vulnerability

Please do not disclose security issues publicly. Instead, use one of the following private channels:

1. Open a private report via GitHub Security Advisories for this repository
2. If you prefer email, contact the maintainers privately (do not use a public issue)

What to include in your report:

- A clear description of the issue and impact
- Steps to reproduce, including sample input and configuration
- Any known mitigations

We will acknowledge receipt within 72 hours, assess the impact, and work on a fix. We may request additional information for reproduction.

## Disclosure

Once a fix is available, we will credit reporters who wish to be acknowledged and include mitigation instructions in the release notes when applicable.

## Hardening notes

These are the boundaries Osaurus relies on. Detailed mechanisms live in [`IDENTITY.md`](IDENTITY.md), [`SANDBOX.md`](SANDBOX.md), and [`STORAGE.md`](STORAGE.md).

- **Sandbox bridge identity** is bound to a per-agent token written into the guest VM as `mode 0600` files owned by the agent's Linux user. The host bridge fails closed (`401`) on missing or unknown tokens; caller-supplied identity headers are not trusted. See [`SANDBOX.md` → Bridge authentication](SANDBOX.md#bridge-authentication).
- **Bridge route scoping**: `agent dispatch` rejects body `agent_id` mismatches with `403`; `agent memory query` filters to the calling agent's pinned facts.
- **Pairing credentials** issued by the Bonjour `/pair` flow are agent-scoped and expire in 90 days by default. Permanent keys are opt-in. Pairing requires a server-issued single-use challenge nonce (anti-replay), the response is signed so the connector can verify the server against the discovered Bonjour TXT address (anti-spoofing), and the minted key is HPKE-sealed to an ephemeral connector key so it never crosses the wire in plaintext. The unauthenticated pairing endpoints are rate-limited per source IP, and the approval prompt is serialized with a 2-minute timeout. The freshly minted key is redacted from request logs. See [`IDENTITY.md` → Bonjour Pairing](IDENTITY.md#bonjour-pairing).
- **Relay tunnel traffic is never loopback-trusted**: requests proxied from the public relay into `127.0.0.1` carry an internal origin marker and always pass the full auth gate, CORS origin rules, and remote blocks — even when network exposure is off. `/pair-invite` supports the same HPKE sealed-key delivery, so the relay operator never observes plaintext credentials. See [`IDENTITY.md` → Relay Tunnel Trust Model](IDENTITY.md#relay-tunnel-trust-model).
- **Agent-to-agent traffic is end-to-end encrypted** (Osaurus Secure Channel v1): a signed-ephemeral X25519 handshake with per-session ChaCha20-Poly1305 keys gives forward secrecy; the server signs the transcript with its agent key and the client verifies it against the address pinned at pairing (anti-MITM). Bearer tokens, prompts, and responses travel only inside the ciphertext — the relay becomes a blind pipe and a LAN observer sees nothing after pairing. Replays are rejected by a sliding sequence window, streams end with an authenticated `fin` frame so truncation is detected, and non-loopback plaintext requests to `/agents/{id}/run` and `/dispatch` are refused with `426 Upgrade Required` (no downgrade path). See [`SECURE_CHANNEL.md`](SECURE_CHANNEL.md) for the full feature document and [`IDENTITY.md` → Secure Channel](IDENTITY.md#secure-channel-agent-to-agent-e2e-encryption) for mechanism details.
- **Access key scoping and freshness**: agent-scoped keys are rejected with `403` on other agents' routes — both the run route (`/agents/{id}/run`) and the metadata route (`GET /agents/{id}`, which exposes the agent's name, description, and effective model), so a paired peer cannot enumerate other agents' metadata — and the server's validator snapshot is epoch-invalidated on key generation, revocation, whitelist, and agent changes so revocations apply without a restart. Loopback callers can omit a real key only while the server is not exposed to the network; LAN and relay callers always pass the auth gate. User-triggered revocation records the key in the revocation store and removes the key metadata from access-key lists so revoked credentials do not linger as selectable keys.
- **Per-agent host workspace (authenticated remote file access)**: an agent's owner can grant it a single host folder (**Agent → Configure → Features → Host Files**), stored as a machine-local security-scoped bookmark on the agent (`Agent.hostWorkspaceBookmark`) that never crosses the wire to a paired peer. Only an authenticated remote agent run (Secure Channel, agent-scoped) over `/agents/{id}/run` mounts it, and only the host file tools (`file_read` / `file_write` / `file_edit`) confined to that folder — `shell_run`, `git_commit`, and `file_undo` stay denied. The folder root is bound as a task-local only after the secure-transport, built-in-agent, and agent-scope gates pass, so loopback, plaintext, `/mcp/call`, and cross-agent callers never reach the relaxation. Concurrent host-folder runs are serialized so the process-wide folder-tool registration can't be corrupted, and a stale/unresolvable bookmark fails closed (the run falls back to sandbox/none). See [`OpenAI_API_GUIDE.md` → External surface deny list](OpenAI_API_GUIDE.md).
- **Master identity overwrite protection**: `MasterKey.generate(allowReplace:)` defaults to `false` and refuses to silently overwrite an existing master. Replacement requires the explicit "Reset Identity" or "Recover from phrase" flows in **Settings → Identity**. Drift between the current master and persisted agent / access-key derivatives is detected by `IdentityHealthCheck` and surfaced in a banner with three exit doors. See [`IDENTITY.md` → Master Key Backup and Recovery](IDENTITY.md#master-key-backup-and-recovery).
- **Master identity backup**: a BIP39 24-word mnemonic is shown once at setup and is the only artifact that can rebuild the local secp256k1 master if the iCloud Keychain entry is ever lost or replaced. The one-time `OSAURUS-XXXX-…` recovery code is a separate server-side claim token and cannot restore the local key. See [`IDENTITY.md` → Master Key Backup and Recovery](IDENTITY.md#master-key-backup-and-recovery).
- **Pre-auth request size limits** on both HTTP servers: `/pair` 64 KiB, other public routes 32 MiB, sandbox bridge 8 MiB. Rejected with `413` before the auth gate runs.
- **Sandbox runtime artifacts** are pinned and verified: GHCR image by multi-arch index digest, Kata kernel and initfs by SHA-256. Mismatches are fail-closed. See [`SANDBOX.md` → Artifact Integrity](SANDBOX.md#artifact-integrity).
- **At-rest encryption is opt-in (plaintext by default since 0.21.0)**: chat history, memory, methods, tool index, plugin databases, and large attachments are stored as plaintext SQLite by default, relying on macOS FileVault for full-disk at-rest protection. This is a deliberate walk-back from always-on SQLCipher: an always-required Keychain key coupled every store's open to a secret that breaks on Mac migration, re-signing, or a Keychain wipe, and failed closed with no recovery. Opening is now detection-first (the on-disk file header decides plaintext vs. encrypted), so a missing key can never brick a plaintext store. Users can opt in to SQLCipher / AES-GCM whole-database encryption (per-device DEK in macOS Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not biometric-gated) from **Settings → Storage**, and existing encrypted installs are migrated invisibly on first launch of 0.21.0+ — decrypted to plaintext only when macOS FileVault is enabled (the disk is already encrypted at rest), or kept encrypted when FileVault is off so the migration never silently removes their only at-rest protection. See [`STORAGE.md` → Why encryption is opt-in](STORAGE.md#why-encryption-is-opt-in).
- **Screenshot slash-command boundary**: `/screenshot` is a local chat action, not a model-callable agent tool. It is gated by macOS Screen Recording permission, stores PNGs only in the chat artifact directory, records local artifact metadata without adding model-visible tool history or artifact host paths, does not auto-dispatch artifacts to plugins, and is unavailable to HTTP, MCP, plugin, and other external tool surfaces.
- **Key recovery posture (encrypted mode)**: there is no escrow key. In the default plaintext mode nothing depends on the Keychain, so key loss has no impact. When a user opts in to encryption, losing the Keychain entry (wiping the Mac without bringing the key, or copying `~/.osaurus/` to a different account) makes the encrypted artifacts unopenable. Osaurus never auto-deletes them: degraded stores are classified (locked / corrupt / migration) and surfaced in **Settings → Storage** and **Memory → Diagnostics** with Retry and Reset (quarantine-to-`~/.osaurus/quarantine/`, never delete) actions, plus a one-click plaintext export to run before any risky migration. See [`STORAGE.md` → Recovery](STORAGE.md#recovery).
- **Build reproducibility**: SPM dependencies that previously tracked `branch: "main"` are pinned to commit revisions; CI is pinned to a specific runner image and Xcode version.

For ongoing development, prefer adding new boundaries via the same patterns: identity bound to file permissions or signed credentials (never headers), fail-closed defaults, finite expirations, redacted logging, and immutable digests for any external runtime artifact.
