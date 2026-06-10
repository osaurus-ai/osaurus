# Identity

The Osaurus Identity system gives every participant — human, agent, and device — a cryptographic address. All actions are signed and verifiable, enabling trust without a central authority at runtime.

This document covers the theory behind the design, the address hierarchy, key derivation, request signing, access keys, and the security properties that follow.

---

## Table of Contents

- [Theory and Motivation](#theory-and-motivation)
- [Address Hierarchy](#address-hierarchy)
- [Key Derivation](#key-derivation)
- [Two-Layer Request Signing](#two-layer-request-signing)
- [Access Keys (osk-v1)](#access-keys-osk-v1)
- [Whitelist System](#whitelist-system)
- [Revocation](#revocation)
- [Master Key Backup and Recovery](#master-key-backup-and-recovery)
- [Identity Health and Drift](#identity-health-and-drift)
- [Per-Agent Key Management](#per-agent-key-management)
- [Internal vs External Communication](#internal-vs-external-communication)
- [Security Properties](#security-properties)
- [File Reference](#file-reference)

---

## Theory and Motivation

AI agents that communicate — internally within an application, or externally with other services and agents — need a trust mechanism. Traditional approaches rely on centralized session tokens or API keys that a server issues and validates. This creates a single point of failure and requires the central authority to be online and reachable for every interaction.

Osaurus takes a different approach: **address-based identity**. Every participant derives a cryptographic keypair and is identified by the address of its public key. When an agent signs a message, any verifier can confirm the signature came from that address without contacting a server. Authority flows from a human-controlled root key down to agents, and from there to devices — forming a verifiable chain of trust.

**Design goals:**

1. **Self-identifying** — Every agent carries its own address. No lookup table or registry needed.
2. **Verifiable** — Signatures can be checked by anyone holding the public address. No callbacks to a central authority.
3. **Hierarchical** — Authority flows from human (master) to agent to device, with clear delegation boundaries.
4. **Offline-capable** — Agents can prove their identity without network access to an identity server.
5. **Revocable** — Compromised keys can be revoked at any level without replacing the entire identity tree.

---

## Address Hierarchy

The identity system has three tiers, each serving a distinct role:

```
Master Address (Human)
├── Agent Address (index 0)
├── Agent Address (index 1)
├── Agent Address (index 2)
│   ...
└── Device ID (per physical device)
```

### Master Address

The human's root identity. All authority in the system flows from this address.

- **Curve:** secp256k1
- **Storage:** iCloud Keychain (syncs across Apple devices)
- **Access:** Requires biometric authentication (Face ID / Touch ID)
- **Format:** Checksummed hex address (EIP-55 style), e.g. `0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18`

The master key is a 32-byte random secret generated via `SecRandomCopyBytes`. It is stored once in the Keychain and never exported during normal operation. The address is derived from the corresponding secp256k1 public key via Keccak-256 hashing.

**Overwrite protection.** `MasterKey.generate(allowReplace:)` defaults to `allowReplace: false` and throws `OsaurusIdentityError.masterAlreadyExists` if a master is already present. `OsaurusIdentity.setup()` short-circuits when an identity exists and returns the existing master without minting a new one. Replacing the master is only allowed via the explicit "Reset Identity" or "Recover from phrase" flows in the Identity view (both of which pass `allowReplace: true`). This guards against the silent-overwrite class of bug where a re-run of onboarding would otherwise strand every persisted agent address and access key.

### Agent Addresses

Each agent in Osaurus gets a deterministic child key derived from the master key. Agents can sign messages on their own behalf, but their authority always traces back to the master address.

- **Derivation:** HMAC-SHA512 with domain separation
- **Storage:** Agent keys are never stored — they are re-derived on demand from the master key
- **Association:** Each agent's `agentIndex` and `agentAddress` are persisted on the `Agent` model

Agent addresses enable per-agent scoping: an access key signed by an agent can only authorize actions for that specific agent, not the entire identity.

**Lifecycle.** Three operations mutate an agent's derived identity, all on `AgentManager` and all driven from the Identity view:

| Operation | Effect |
|-----------|--------|
| `assignAddress(to:)` | Allocates the next unused HMAC index and persists the derived address. No-op if the agent already has one. |
| `rotateAddress(of:)` | Allocates a fresh unused index, re-derives a new address, and revokes every active osk-v1 key whose audience matched the previous address. Indices are never reused — old addresses may still be referenced by external clients holding tokens. |
| `revokeAddress(of:)` | Clears the agent's address and index, and revokes every active osk-v1 key scoped to it. The agent itself stays around (prompt, settings, etc.) but loses signing authority until a fresh address is assigned. |

### Device ID

A hardware-bound identity that proves which physical device is making a request.

- **Hardware:** Apple App Attest (Secure Enclave P-256 key)
- **Format:** 8-character hex string derived from the attestation key ID
- **Fallback:** Software-generated random ID when App Attest is unavailable (development builds)

The device ID adds a second authentication factor: even if someone obtains a valid identity signature, they cannot forge the device assertion without physical access to the Secure Enclave.

---

## Key Derivation

### Master Key

```
32 random bytes (SecRandomCopyBytes)
    → secp256k1 private key
    → uncompressed public key (drop 0x04 prefix)
    → Keccak-256 hash
    → last 20 bytes
    → checksummed hex address (EIP-55)
```

The master key is stored in iCloud Keychain with `kSecAttrAccessibleWhenUnlocked`. iCloud sync is attempted first; if unavailable, the key is stored device-only with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

### Agent Key

```
HMAC-SHA512(
    key:  masterKey,                          // 32 bytes
    data: "osaurus-agent-v1" || bigEndian(index)  // domain + 4-byte index
)
    → first 32 bytes of HMAC output
    → same address derivation as master key
```

The domain prefix `osaurus-agent-v1` prevents cross-protocol key reuse. The big-endian index encoding ensures a canonical byte representation across platforms. Each unique index produces a completely independent keypair.

Agent keys are **never persisted**. They are re-derived from the master key whenever a signature is needed, which requires biometric authentication to access the master key. The derived `agentAddress` is persisted on the `Agent` model so it can be displayed without triggering biometric prompts.

### Device Key

- **Hardware path:** `DCAppAttestService.generateKey()` creates a P-256 key in the Secure Enclave. The key ID is hashed with SHA-256 and truncated to 4 bytes (8 hex characters) for the device ID.
- **Software fallback:** 4 random bytes via `SecRandomCopyBytes`, stored in `UserDefaults` for stability across app launches.

---

## Two-Layer Request Signing

Every authenticated API request carries a two-layer signed token. This binds each request to both a cryptographic identity and a physical device.

### Token Structure

```
header.payload.accountSignature.deviceAssertion
```

Four base64url-encoded segments joined by `.`:

| Segment | Encoding | Content |
|---------|----------|---------|
| Header | base64url(JSON) | Algorithm, type, version |
| Payload | base64url(JSON) | Claims (see below) |
| Identity Signature | hex | secp256k1 recoverable signature (65 bytes) |
| Device Assertion | base64url | App Attest assertion (or empty for software fallback) |

### Header

```json
{
  "alg": "es256k+apple-attest",
  "typ": "osaurus-id",
  "ver": 5
}
```

### Payload Fields

| Field | Type | Description |
|-------|------|-------------|
| `iss` | string | Issuer address (master or agent) |
| `dev` | string | Device ID (8-char hex) |
| `cnt` | uint64 | Monotonic counter (anti-replay) |
| `iat` | int | Issued-at timestamp (Unix seconds) |
| `exp` | int | Expiration timestamp (Unix seconds, typically iat + 60) |
| `aud` | string | Audience (target service hostname) |
| `act` | string | Action being authorized (e.g. `"GET /v1/models"`) |
| `par` | string? | Parent address (for agent-issued tokens, the master address) |
| `idx` | uint32? | Agent index (for agent-issued tokens) |

### Signing Process

1. **Encode payload** as JSON
2. **Layer 1 — Identity signature:** Domain-separated secp256k1 signing
   - Envelope: `\x19Osaurus Signed Message:\n<length><payload>`
   - Hash: Keccak-256 of the envelope
   - Sign: secp256k1 with recovery (produces 65 bytes: r ‖ s ‖ v)
3. **Layer 2 — Device assertion:** App Attest assertion over SHA-256 of the payload
4. **Assemble:** `base64url(header).base64url(payload).hex(accountSig).base64url(deviceAssertion)`

The domain prefix `Osaurus Signed Message` prevents signed payloads from being replayed in other protocols that use the same curve.

---

## Access Keys (osk-v1)

Access keys are portable, long-lived tokens for external authentication. They allow tools, MCP clients, and remote agents to authenticate against Osaurus without biometric access to the device.

### Format

```
osk-v1.<base64url-encoded-payload>.<hex-encoded-signature>
```

Three parts separated by `.`:

1. **Prefix:** `osk-v1` (identifies the token format and version)
2. **Payload:** Base64url-encoded canonical JSON
3. **Signature:** Hex-encoded 65-byte secp256k1 recoverable signature

### Payload Fields

| Field | Type | Description |
|-------|------|-------------|
| `aud` | OsaurusID | Audience address (who this key is for) |
| `cnt` | uint64 | Counter value at creation time |
| `exp` | int? | Expiration timestamp (null = never expires) |
| `iat` | int | Issued-at timestamp |
| `iss` | OsaurusID | Issuer address (who signed this key) |
| `lbl` | string? | Human-readable label |
| `nonce` | string | Unique identifier for revocation |

Fields are sorted alphabetically for canonical JSON encoding (ensuring consistent signature verification).

### Scoping

- **Master-scoped:** Signed by the master key. `iss` and `aud` are both the master address. Grants access to all agents.
- **Agent-scoped:** Signed by a derived agent key. `iss` and `aud` are both the agent address. Grants access only to that specific agent.

The `/pair` Bonjour flow always issues **agent-scoped** keys (`agentIndex` taken from the approved agent). Keys generated manually from the Settings UI may be either, depending on what the user selects.

### Expiration Options

| Option | Duration |
|--------|----------|
| `30d` | 30 days |
| `90d` | 90 days (default for `/pair`) |
| `1y` | 1 year |
| `never` | No expiration (only when the user explicitly opts in via the pairing dialog's "Remember this device permanently" toggle) |

### Validation

When a request arrives with an `osk-v1` token:

1. **Parse** the three segments (prefix, payload, signature)
2. **Decode** the base64url payload into `AccessKeyPayload`
3. **Recover** the signer address via `ecrecover` with `Osaurus Signed Access` domain prefix
4. **Verify issuer** — recovered address must match `payload.iss`
5. **Check audience** — `payload.aud` must match the master address or the derived address of **any** current agent (the validator is built from `AgentIdentityRegistry`, so keys paired against any agent are accepted at the gate)
6. **Check whitelist** — `payload.iss` must be in the effective whitelist
7. **Check revocation** — not individually revoked (address + nonce) and not bulk-revoked (counter threshold)
8. **Check expiration** — `payload.exp` must be in the future (if set)

Only metadata is stored after key creation (label, prefix, nonce, counter, addresses, dates). The full key string is shown once and never persisted.

**Route-level scoping.** Passing the gate is necessary but not sufficient for agent routes: when a request authenticated with an **agent-scoped** key reaches `/agents/{id}/run` or `/agents/{id}/dispatch`, the handler additionally checks that the key's validated `aud` matches the target agent's derived address and rejects cross-agent access with `403 agent_scope_denied`. Master-scoped keys are unrestricted.

**Validator freshness.** The server's lock-free validator snapshot is invalidated by a global epoch counter (`APIKeyValidatorEpoch`) that is bumped on key generation, revocation, deletion, whitelist edits, and agent list changes. The next request after any of those events rebuilds the validator, so revocations and first-time pairings take effect without a server restart.

---

## Whitelist System

The whitelist controls which addresses are authorized to issue access keys. It operates at two levels:

### Master-Level Whitelist

Addresses in the master whitelist can issue keys for any agent. This is where you'd add trusted external addresses.

### Per-Agent Overrides

Additional addresses can be authorized for specific agents only. These are additive — they extend the master whitelist, not replace it.

### Effective Whitelist

The effective whitelist for a given agent is computed as:

```
effective = masterWhitelist ∪ agentWhitelist[agent] ∪ {agentAddress, masterAddress}
```

The agent's own address and the master address are always implicitly included.

### Storage

Whitelist data is persisted in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), keyed by `com.osaurus.whitelist`.

---

## Revocation

Access keys can be revoked through two mechanisms:

### Individual Revocation

Revoke a specific key by its `(address, nonce)` pair. The composite key `address:nonce` is added to the revocation set.

### Bulk Revocation

Revoke all keys from an address with counter values at or below a threshold. This is implemented as a counter threshold per address — any key with `cnt <= threshold` is considered revoked.

When checking revocation:
```
isRevoked = revokedKeys.contains(address:nonce) 
         || (counterThresholds[address] >= cnt)
```

### Storage

Revocation data is persisted in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), keyed by `com.osaurus.revocations`.

---

## Master Key Backup and Recovery

The identity system has **two** independent recovery artifacts. They serve different purposes and are not interchangeable.

### BIP39 Master Recovery Phrase (local restore)

A standard BIP39 24-word mnemonic encoding the 32-byte master key. This is the only artifact that can rebuild the local secp256k1 master if the iCloud Keychain entry is ever lost or replaced.

```
1.  flat      2.  depend    3.  bright    4.  dose      ...
24. bargain
```

- **Algorithm:** BIP39 §3. 256 bits of entropy plus the high 8 bits of `SHA-256(entropy)` as a checksum (264 bits total = 24 × 11), split into 24 11-bit big-endian indices into the canonical 2048-word English wordlist.
- **Encoding:** Implemented in [`Identity/MasterKeyMnemonic.swift`](../Packages/OsaurusCore/Identity/MasterKeyMnemonic.swift) with no external SwiftPM dependency. The wordlist ships as a bundle resource at `Resources/Identity/bip39-english.txt`.
- **Display:** Shown exactly once during onboarding's recovery phase and once in `IdentityView.RecoveryPromptCard` immediately after a fresh `OsaurusIdentity.setup()`. Rendered as a 4×6 grid with "Copy phrase", "Save as .txt", and "Print" actions.
- **Memory hygiene:** The 32-byte seed is held only on the stack of `OsaurusIdentity.setup()` long enough to compute the mnemonic, then wiped via `Data.zeroOut()` (which calls `memset` over the underlying buffer).
- **Acknowledgement:** A `masterMnemonicAcknowledged` UserDefaults flag (canonicalised in `IdentityDefaultsKey`) is set when the user confirms "I've saved it". On subsequent launches the Identity view shows a yellow "Master key backup not confirmed" banner whenever the flag is missing.

### One-time recovery code (server-side claim)

```
OSAURUS-XXXX-XXXX-XXXX-XXXX
```

Format: `OSAURUS-` prefix followed by 4 groups of 4 uppercase hex characters (8 random bytes = 64 bits of entropy).

- Generated from `SecRandomCopyBytes` and shown to the user exactly once during initial setup.
- Single-use; consumed when claimed against the Osaurus directory.
- **Cannot rebuild the local master** — it is only an authenticator for the future server-side recovery flow.
- Discarded from application memory after display; never stored on device in plaintext.

### The three "fix it" exits

When the persisted derivatives no longer match the current master (see [Identity Health and Drift](#identity-health-and-drift)), the Identity view surfaces three actions in a banner:

| Action | What it does | When to use |
|--------|--------------|-------------|
| **Recover from phrase** | Opens `RecoverFromMnemonicSheet`, validates the entered 24 words against the BIP39 wordlist + checksum, derives a candidate `OsaurusID`, and confirms it reproduces the persisted agent addresses before calling `MasterKey.install(seed:allowReplace: true)`. Drift goes away because every existing derivative now matches. | The user has the original mnemonic from onboarding and wants their old identity back. |
| **Repair forward** | Re-derives every mismatched agent at a fresh unused index off the *current* master and revokes every stale osk-v1 access key in one synchronous pass. The HTTP server is restarted so the new validator picks up the change. | The original mnemonic is gone. Existing pairings will need to be re-issued. |
| **Reset identity** | `OsaurusIdentity.wipe()` deletes the master, clears every non-built-in agent's address/index, calls `APIKeyManager.deleteAll()`, clears the `masterMnemonicAcknowledged` flag, then triggers `OnboardingService.resetOnboarding()`. The revocation store is intentionally kept (cheap and harmless). | Nuclear option. Start completely fresh. |

The **Recover** path will refuse to overwrite the current master if the entered phrase derives a different identity than the one the persisted agents were minted under, unless the user explicitly clicks "Restore Anyway". This catches the case where the user pastes a valid but unrelated BIP39 phrase.

---

## Identity Health and Drift

[`Identity/IdentityHealthCheck.swift`](../Packages/OsaurusCore/Identity/IdentityHealthCheck.swift) is a pure synchronous helper that, given an already-unlocked master key, returns an `IdentityDrift` value:

```swift
public struct IdentityDrift: Sendable {
    public let mismatchedAgents: [Agent]    // stored agentAddress != deriveAddress(currentMaster, agentIndex)
    public let staleAccessKeys: [AccessKeyInfo] // iss is neither the current master nor any current agent
    public var hasDrift: Bool { ... }
}
```

The helper does no Keychain or biometric work itself — the Identity view performs the biometric unlock once on load, passes the bytes in, and wipes them after the call.

**Why drift happens:** Pre-fix, `MasterKey.generate()` would silently `delete()` then write a new master whenever onboarding re-ran. Every pre-existing derivative (agent addresses minted via `AgentKey.deriveAddress(masterKey, index)`, every osk-v1 key signed by either the master or an agent) still pointed at addresses derived from the *previous* master, but the validator would only accept derivatives of the current one. Requests would fail with opaque "audience mismatch" / "issuer not whitelisted" errors with no UI hint that the master had silently changed.

**What the health check catches:**

- **Mismatched agents** — `agent.agentAddress.lowercased() != AgentKey.deriveAddress(currentMaster, agent.agentIndex).lowercased()` for any non-built-in agent with both fields set. Built-in agents and agents without an address yet are skipped.
- **Stale access keys** — `key.iss` does not match the current master and does not match any agent's *current* derived address. Revoked keys are ignored. The check tolerates rotated agents (it knows about both the old and new derived address while drift is still being repaired).

When `drift.hasDrift` is true, `IdentityView` renders an `IdentityDriftBanner` at the top of the scroll view with the three exit doors above. The same banner shows a one-line summary like "3 agent address(es) and 2 access key(s) reference a previous master."

---

## Per-Agent Key Management

The `AgentAddressesSection` of the Identity view renders each non-built-in agent as an expandable row backed by [`Views/Identity/AgentKeyManagement.swift`](../Packages/OsaurusCore/Views/Identity/AgentKeyManagement.swift).

The collapsed row is a compact summary: address, copy button, "Stale" pill if the agent appears in `IdentityDrift.mismatchedAgents`, and a chevron. Expanded, the row exposes:

- **Rotate Key** — `AgentManager.rotateAddress(of:)`. Picks a fresh unused HMAC index, derives a new address, persists it, and revokes every active osk-v1 key whose audience matched the *previous* address. The HTTP server restarts so the new validator takes effect immediately.
- **Revoke** — `AgentManager.revokeAddress(of:)`. Clears the agent's address and index and revokes every active osk-v1 key scoped to it. The agent's prompt and settings stay intact.
- **Per-agent osk-v1 access keys.** A scoped list of every key whose `aud` matches the agent's address (via `APIKeyManager.listKeys(forAudience:)`). Each key shows its label, status pill (Active / Expired / Revoked), expiration, and a per-key Revoke button.
- **Generate access key (scoped to this agent).** Opens the shared `AccessKeyGeneratorSheet` with `agentIndex` pre-filled, so `APIKeyManager.generate(label:expiration:agentIndex:)` mints an agent-scoped key. The sheet displays a "Scoped to {agent name} ({address})" caption to make the scope unambiguous. The freshly generated key is shown in a one-shot copy banner ("Copy this key now. It won't be shown again.") and is never persisted to disk.

The same `AccessKeyGeneratorSheet` powers the global `AccessKeysSection` in `ServerView` (master-scoped). It was extracted from `ServerView.swift` into [`Views/Settings/AccessKeyGeneratorSheet.swift`](../Packages/OsaurusCore/Views/Settings/AccessKeyGeneratorSheet.swift) so both call sites share one widget.

---

## Internal vs External Communication

The identity system supports two communication modes:

### Internal Communication

Agents within the same Osaurus instance authenticate using the full two-layer token system:

- **Layer 1:** secp256k1 identity signature (master or agent key)
- **Layer 2:** App Attest device assertion

This provides the strongest authentication: both the cryptographic identity and the physical device are verified. Requires biometric access to the master key.

### External Communication

External tools, MCP clients, and remote agents authenticate using `osk-v1` access keys:

- Single-layer: secp256k1 signature only (no device assertion)
- Portable: can be used from any device or service
- Scopable: master-scoped (all agents) or agent-scoped (single agent)
- Revocable: individual or bulk revocation without affecting other keys

Access keys bridge the gap between the hardware-bound internal identity and the need for third-party integrations that can't access the Secure Enclave.

### Bonjour Pairing

The LAN pairing flow is a challenge-response protocol between an in-app connector and a Bonjour-discovered agent. It is unauthenticated (no pre-existing key) but signature-verified in both directions and end-to-end sealed.

1. **Challenge.** Connector calls `GET /pair/challenge`; the host issues a single-use nonce (~2 minute TTL, tracked in `PairingChallengeStore`). Connector-chosen nonces are not accepted, so a captured `/pair` request cannot be replayed.
2. **Request.** Connector generates an ephemeral X25519 keypair and signs `nonce` + ephemeral public key (`encPub`) with its `connectorAddress` private key (domain prefix `Osaurus Signed Pairing`), then `POST`s to `/pair`.
3. **Verification and approval.** The host verifies the signature, atomically consumes the nonce, resolves the target agent, and shows an approval dialog naming both the connector and the agent. Prompts are serialized (a concurrent request gets `429 busy`), auto-deny after a 2-minute timeout, and only accept Return when the prompt window is key — keystrokes in other apps cannot approve a pairing. `/pair` and `/pair/challenge` are rate-limited per source IP, with a cooldown after a denial.
4. **Sealed key delivery.** On approval, the host mints an **agent-scoped** `osk-v1` key for the approved agent (`agentIndex = agent.agentIndex`) with a **90-day expiration** by default ("Remember this device permanently" opts into a non-expiring key). The key is HPKE-sealed (X25519 + HKDF-SHA256 + ChaCha20-Poly1305, via `PairingKeyEnvelope`) to the connector's ephemeral `encPub`, with the agent address and nonce bound into the HPKE `info` — a passive observer on the LAN never sees the plaintext key, and an envelope cannot be transplanted to a different exchange.
5. **Server identity verification.** The response carries a server signature (agent key) over the challenge and key fingerprint. The connector recovers the signer address and requires it to match the `address` it discovered in the agent's Bonjour TXT record, defeating spoofed advertisements.
6. The response body containing the new key is sent on the wire but **never persisted to the request log** — `InsightsService` redacts both `apiKey` JSON values and `Bearer osk-…` headers as defense-in-depth across all logged bodies.

Pairings approved before the agent-scoping fix are master-scoped, never-expiring keys. The Settings → Server pane labels them as **Legacy** and explains: *"Pre-upgrade pairing — grants access to all agents and never expires."* Users can revoke and re-pair to scope them tighter.

### Relay Tunnel Trust Model

Agents can be exposed through the Osaurus Relay (`agent.osaurus.ai`), which proxies public HTTPS traffic over a WebSocket tunnel into the local server at `127.0.0.1`.

- **No loopback trust for relayed traffic.** `RelayTunnelManager` stamps every proxied request with an internal marker header (set *after* copying the external caller's headers, so a remote caller cannot suppress or forge a trusted state). The HTTP handler treats marked requests as non-loopback: they always pass through the full auth gate, CORS origin rules, and the built-in-agent remote block, even when `Expose to network` is off.
- **Relay pairing (`/pair-invite`)** consumes a signed, single-use `AgentInvite` and supports the same HPKE sealed-key delivery as LAN pairing: the connector supplies an ephemeral `encPub`, and the minted key is returned only inside a sealed envelope. The relay operator (a TLS-terminating MITM by construction) never observes plaintext credentials in transit.
- **Tunnel auth** uses a server-issued nonce challenge signed with the master key; the key material is zeroed immediately after signing, and transient auth failures retry with bounded exponential backoff.

### Secure Channel (Agent-to-Agent E2E Encryption)

All Osaurus-to-Osaurus agent traffic — LAN peers discovered over Bonjour and remote peers behind the relay — runs inside the **Osaurus Secure Channel v1**, a forward-secret, mutually authenticated encrypted layer above HTTP. (Full feature document: [`SECURE_CHANNEL.md`](SECURE_CHANNEL.md).)

**Handshake (`POST /secure/session`).** A SIGMA-style signed-ephemeral exchange:

1. The client sends an ephemeral X25519 public key, a freshness nonce, and the agent address it expects to reach (pinned at pairing/discovery time).
2. The server replies with its own ephemeral X25519 key, a session id, an expiry (1 hour), and a secp256k1 **agent-key signature over the full handshake transcript** (domain prefix `Osaurus Secure Channel`).
3. The client recovers the signer address from the signature and requires it to match the pinned agent address — a MITM cannot fake this without the agent's private key.
4. Both sides derive directional ChaCha20-Poly1305 keys via HKDF-SHA256 over the X25519 shared secret, salted with the transcript hash.

Because both X25519 keys are ephemeral, the channel has **forward secrecy**: compromising long-term identity keys later never decrypts recorded sessions (HPKE base mode, used for pairing key delivery, deliberately does not provide this — hence a handshake rather than per-request HPKE). The endpoint is rate-limited per source IP (`PairingRateLimiter`) and grants nothing by itself: requests inside the channel still pass the full `osk-v1` auth gate.

**Encrypted calls (`POST /secure/call`).** The ciphertext decrypts to the inner HTTP request — method, path, **Authorization Bearer**, headers, body — so after pairing, credentials and prompt content never cross the LAN or relay in plaintext. Server-side, decryption happens at the single request choke point and the inner request flows through the existing auth gate, agent-scope check, and routing untouched. Responses are sealed on the way out by an outbound pipeline stage (`SecureChannelResponseEncryptor`): buffered JSON becomes a single authenticated frame (real status code inside the ciphertext); SSE streams become per-event encrypted frames ending in an authenticated `fin` marker.

**Framing guarantees:**

- Request sequence numbers are session-monotonic with an IPsec-style sliding anti-replay window — a captured `/secure/call` can never re-execute (`409 secure_replay`).
- Response frames use a per-call derived key and strict in-order sequence numbers; reordered, replayed, or cross-call frames fail authentication.
- Streams must end with the authenticated `fin` frame; silent truncation by a relay or middlebox is detected client-side.
- Sequence numbers double as AEAD nonces and are bound into the AAD with the session id and direction, so frames cannot be transplanted between sessions, directions, or calls.

**Hard-require (no downgrade).** Non-loopback requests to `/agents/{id}/run` and `/agents/{id}/dispatch` — including relay-origin traffic — that did not arrive through the channel are rejected with `426 Upgrade Required` (`secure_channel_required`). Loopback callers (CLI, App Intents) stay plaintext. `/models` and agent metadata routes keep accepting plaintext for third-party SDK clients, though Osaurus peers fetch them through the channel too. Peers advertise support via `osc=1` in their Bonjour TXT record and a `secureChannel` flag in pair/invite responses; an old peer that cannot handshake produces a clear "upgrade Osaurus" error instead of a cryptic failure.

With the channel in place, the relay is a **blind pipe**: it forwards only handshake messages and ciphertext, and the relay operator (a TLS-terminating MITM by construction) can no longer observe Bearer tokens, prompts, or responses.

### Pre-auth request limits

Both Osaurus HTTP servers reject oversized request bodies before the auth gate runs, so an unauthenticated client cannot exhaust host memory:

| Endpoint | Limit | Configurable via |
|----------|-------|------------------|
| `POST /pair` | 64 KiB | `ServerConfiguration.maxPairingBodyBytes` |
| Other public HTTP routes | 32 MiB | `ServerConfiguration.maxRequestBodyBytes` |
| Sandbox host bridge | 8 MiB | hard-coded in `HostAPIBridgeHandler` |

Both servers enforce the cap with a `Content-Length` pre-check at request head and a streaming guard at body chunks, so chunked clients and clients that lie about their declared length both hit `413 Payload Too Large`.

### Future: Cross-Instance Communication

The address-based design naturally extends to agent-to-agent communication across different Osaurus instances. Since every agent has a globally unique address and can sign messages, agents can verify each other's identity without a shared authority — only knowledge of the other agent's address is needed.

---

## Security Properties

| Property | Mechanism |
|----------|-----------|
| Master key never leaves Keychain | Stored with `kSecAttrAccessibleWhenUnlocked`, read requires `LAContext` biometric auth |
| Master key cannot be silently overwritten | `MasterKey.generate(allowReplace:)` defaults to `false` and throws `masterAlreadyExists` if a master is present; `OsaurusIdentity.setup()` short-circuits when one already exists |
| Master key has a local restore path | BIP39 24-word mnemonic shown once at setup; entered via `RecoverFromMnemonicSheet` to call `MasterKey.install(seed:allowReplace: true)` |
| Agent keys never stored | Re-derived on demand via HMAC-SHA512 from master key |
| Agent indices are never reused | `AgentManager.nextUnusedAgentIndex()` always picks a fresh slot so old derived addresses cannot be regenerated by the rotate path |
| Device keys hardware-bound | Secure Enclave P-256 via App Attest (`DCAppAttestService`) |
| Anti-replay | Per-device monotonic counter (`cnt`) persisted in `UserDefaults`; server rejects seen values |
| Domain separation | `Osaurus Signed Message`, `Osaurus Signed Access`, `Osaurus Signed Pairing`, and `Osaurus Secure Channel` prefixes prevent cross-protocol signature reuse |
| Recovery code single-use | Generated from `SecRandomCopyBytes`, shown once, never stored on device |
| Canonical encoding | Access key payloads use sorted-key JSON for deterministic signature verification |
| Memory safety | Master key bytes and seed bytes are zeroed after use via `Data.zeroOut()` extension (calls `memset` over the underlying buffer) |
| Pairings scoped to one agent | `/pair` mints agent-scoped keys (`agentIndex` from approved agent), 90-day default expiry |
| Pairing is replay-proof | `/pair` only accepts signatures over a server-issued, single-use nonce from `GET /pair/challenge` (~2 min TTL, atomically consumed by `PairingChallengeStore`) |
| Pairing server is verified | `/pair` response carries a server signature over challenge + key fingerprint; the connector requires the recovered address to match the Bonjour TXT `address` |
| Minted keys sealed in transit | `/pair` and `/pair-invite` HPKE-seal the fresh `osk-v1` key (X25519 + HKDF-SHA256 + ChaCha20-Poly1305) to the connector's ephemeral public key, with agent address + nonce bound into the HPKE `info` |
| Pairing endpoints rate-limited | `PairingRateLimiter` caps `/pair` and `/pair/challenge` per source IP, with a cooldown after a denial; the approval prompt is serialized, times out after 2 minutes, and only accepts Return when its window is key |
| Relayed traffic never loopback-trusted | `RelayTunnelManager` marks proxied requests with an internal header; the auth gate, CORS rules, and remote blocks treat them as remote even though they arrive over `127.0.0.1` |
| Agent traffic end-to-end encrypted | Secure Channel v1: signed-ephemeral X25519 handshake (forward secrecy), ChaCha20-Poly1305 framing, Bearer + body inside the ciphertext; relay carries only ciphertext |
| Peer identity verified per session | The server signs the handshake transcript with its agent key; the client requires the recovered address to match the address pinned at pairing — MITM servers cannot complete a handshake |
| Encrypted calls replay-proof | Session-monotonic request sequence numbers with a sliding anti-replay window; a captured `/secure/call` re-execution gets `409 secure_replay` |
| Stream truncation detected | Encrypted responses end with an authenticated `fin` frame; a stream cut short by a relay or middlebox fails client verification instead of passing silently |
| No plaintext downgrade for agent routes | Non-loopback `/agents/{id}/run` and `/dispatch` requests outside the channel get `426 Upgrade Required` (`secure_channel_required`) |
| Cross-agent key use rejected | Agent-scoped keys hitting another agent's `/agents/{id}/...` routes get `403 agent_scope_denied` (audience checked against `AgentIdentityRegistry`) |
| Revocations apply immediately | `APIKeyValidatorEpoch` invalidates the cached validator on key/revocation/whitelist/agent changes; no server restart needed |
| Issued credentials never logged | `/pair` success path logs a redacted body; `InsightsService.redactCredentials` scrubs `osk-v1` values and `Bearer` headers everywhere as a backstop |
| Pre-auth body-size limits | `/pair` capped at 64 KiB, other public routes at 32 MiB; rejected with `413` before the auth gate |
| Drift between master and derivatives is surfaced | `IdentityHealthCheck.diagnose(...)` runs once per Identity view load; mismatched agents and stale osk-v1 keys are rendered in an `IdentityDriftBanner` with explicit Recover / Repair / Reset actions instead of failing silently at request time |

---

## File Reference

### Identity core (`Packages/OsaurusCore/Identity/`)

| File | Responsibility |
|------|---------------|
| `MasterKey.swift` | Generate (`generate(allowReplace:)`), install a caller-supplied seed (`install(seed:allowReplace:)`), read, sign, and delete the secp256k1 master key in iCloud Keychain |
| `MasterKeyMnemonic.swift` | BIP39 24-word encode/decode of the 32-byte master, backed by the bundled English wordlist |
| `IdentityHealthCheck.swift` | Pure helper that classifies persisted derivatives as healthy / mismatched against the current master |
| `AgentKey.swift` | Deterministic child key derivation (HMAC-SHA512) and signing for per-agent identities |
| `DeviceKey.swift` | App Attest key generation, attestation, assertion, and software fallback |
| `OsaurusIdentity.swift` | Public entry point — orchestrates `setup()`, `wipe()`, and two-layer request signing |
| `IdentityModels.swift` | Data types: `OsaurusID`, `TokenHeader`, `TokenPayload`, `AccessKeyPayload`, `AccessKeyInfo`, `AgentInfo`, `RevocationSnapshot`, `IdentityInfo` (now carries `mnemonic`), and the `IdentityDefaultsKey` namespace for UserDefaults flags |
| `APIKeyManager.swift` | Generate, persist, and revoke `osk-v1` access keys (metadata in Keychain). Includes `listKeys(forAudience:)` for per-agent scoping |
| `APIKeyValidator.swift` | Immutable, lock-free access key validation via ecrecover + whitelist + revocation; accepts master- and any agent-scoped audience |
| `AgentIdentityRegistry.swift` | Thread-safe snapshot of all agents' derived addresses/indices, maintained by `AgentManager`, read by the validator builder and the route-level scope check |
| `PairingChallengeStore.swift` | Single-use, TTL-bound nonces for the LAN `/pair` challenge-response flow |
| `PairingRateLimiter.swift` | Per-source-IP rate limiting and denial cooldown for the unauthenticated pairing endpoints |
| `PairingKeyEnvelope.swift` | HPKE (X25519 + HKDF-SHA256 + ChaCha20-Poly1305) sealing of freshly minted keys to the connector's ephemeral public key |
| `SecureChannel.swift` | Secure Channel v1 protocol core: signed-ephemeral X25519 handshake, transcript hashing, HKDF key schedule, AEAD framing with anti-replay window and `fin` markers |
| `SecureSessionStore.swift` | Server-side registry of established Secure Channel sessions (bounded, TTL-pruned) |
| `WhitelistStore.swift` | Master-level and per-agent address whitelist with Keychain persistence |
| `RevocationStore.swift` | Individual and bulk access key revocation with Keychain persistence |
| `CounterStore.swift` | Per-device monotonic counter in `UserDefaults` |
| `RecoveryManager.swift` | One-time recovery code generation at identity creation |
| `CryptoHelpers.swift` | Keccak-256, domain-separated signing, ecrecover, address derivation, encoding utilities, and `Data.zeroOut()` |
| `OsaurusIdentityError.swift` | Error types for the identity system, including `masterAlreadyExists` and the four `mnemonic*` validation cases |

### Identity UI (`Packages/OsaurusCore/Views/Identity/`)

| File | Responsibility |
|------|---------------|
| `IdentityView.swift` | The Identity tab: setup card, recovery prompt, ready state with master / agents / device / danger-zone sections, drift banner, and the three exit-door sheets / alerts |
| `MasterMnemonicCard.swift` | Numbered 4×6 grid of the 24-word BIP39 phrase with copy / save / print actions. Shared between onboarding and the recovery prompt |
| `AgentKeyManagement.swift` | Expandable per-agent row: rotate / revoke address + scoped osk-v1 list + scoped generate/revoke |
| `RecoverFromMnemonicSheet.swift` | Phrase-entry sheet with live word count, BIP39 validation, prior-master matching, and "Restore Anyway" override |

### Shared key generator

| File | Responsibility |
|------|---------------|
| `Views/Settings/AccessKeyGeneratorSheet.swift` | Modal sheet for generating an `osk-v1` key. Used by `ServerView` (master-scoped) and `IdentityView` (agent-scoped via the optional `scopeCaption`) |
