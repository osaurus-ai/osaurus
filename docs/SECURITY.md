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
- **Pairing credentials** issued by the Bonjour `/pair` flow are agent-scoped and expire in 90 days by default. Permanent keys are opt-in. The freshly minted key is redacted from request logs. See [`IDENTITY.md` → Bonjour Pairing](IDENTITY.md#bonjour-pairing).
- **Pre-auth request size limits** on both HTTP servers: `/pair` 64 KiB, other public routes 32 MiB, sandbox bridge 8 MiB. Rejected with `413` before the auth gate runs.
- **Sandbox runtime artifacts** are pinned and verified: GHCR image by multi-arch index digest, Kata kernel and initfs by SHA-256. Mismatches are fail-closed. See [`SANDBOX.md` → Artifact Integrity](SANDBOX.md#artifact-integrity).
- **At-rest encryption**: chat history, memory, methods, tool index, plugin databases, and large attachments are encrypted on disk with SQLCipher / AES-GCM using a per-device data-encryption key kept in macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not biometric-gated so background launches stay unattended). Migration runs once on first launch of 0.17.7+; users can export a plaintext backup or rotate the key from **Settings → Storage**. See [`STORAGE.md`](STORAGE.md).
- **Key recovery posture**: there is no escrow key. Losing the Keychain entry (e.g. wiping the Mac without a Time Machine restore, or copying `~/.osaurus/` to a different account) makes the encrypted artifacts unrecoverable. The Storage settings panel surfaces this explicitly and offers a one-click plaintext export users should run before any risky migration. See [`STORAGE.md` → Limitations and Trade-offs](STORAGE.md#limitations-and-trade-offs).
- **Build reproducibility**: SPM dependencies that previously tracked `branch: "main"` are pinned to commit revisions; CI is pinned to a specific runner image and Xcode version.

For ongoing development, prefer adding new boundaries via the same patterns: identity bound to file permissions or signed credentials (never headers), fail-closed defaults, finite expirations, redacted logging, and immutable digests for any external runtime artifact.
