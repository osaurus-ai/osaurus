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
- [Recovery](#recovery)
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

The master key is a 32-byte random secret generated via `SecRandomCopyBytes`. It is stored once in the Keychain and never exported. The address is derived from the corresponding secp256k1 public key via Keccak-256 hashing.

### Agent Addresses

Each agent in Osaurus gets a deterministic child key derived from the master key. Agents can sign messages on their own behalf, but their authority always traces back to the master address.

- **Derivation:** HMAC-SHA512 with domain separation
- **Storage:** Agent keys are never stored — they are re-derived on demand from the master key
- **Association:** Each agent's `agentIndex` and `agentAddress` are persisted on the `Agent` model

Agent addresses enable per-agent scoping: an access key signed by an agent can only authorize actions for that specific agent, not the entire identity.

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

### Expiration Options

| Option | Duration |
|--------|----------|
| `30d` | 30 days |
| `90d` | 90 days |
| `1y` | 1 year |
| `never` | No expiration |

### Validation

When a request arrives with an `osk-v1` token:

1. **Parse** the three segments (prefix, payload, signature)
2. **Decode** the base64url payload into `AccessKeyPayload`
3. **Recover** the signer address via `ecrecover` with `Osaurus Signed Access` domain prefix
4. **Verify issuer** — recovered address must match `payload.iss`
5. **Check audience** — `payload.aud` must match the agent or master address
6. **Check whitelist** — `payload.iss` must be in the effective whitelist
7. **Check revocation** — not individually revoked (address + nonce) and not bulk-revoked (counter threshold)
8. **Check expiration** — `payload.exp` must be in the future (if set)

Only metadata is stored after key creation (label, prefix, nonce, counter, addresses, dates). The full key string is shown once and never persisted.

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

## Recovery

During initial identity setup, a one-time recovery code is generated:

```
OSAURUS-XXXX-XXXX-XXXX-XXXX
```

Format: `OSAURUS-` prefix followed by 4 groups of 4 uppercase hex characters (8 random bytes = 64 bits of entropy).

The recovery code is:
- Generated from `SecRandomCopyBytes` (cryptographically secure)
- Shown to the user exactly once during setup
- Discarded from application memory after display
- Never stored on device in plaintext

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

### Future: Cross-Instance Communication

The address-based design naturally extends to agent-to-agent communication across different Osaurus instances. Since every agent has a globally unique address and can sign messages, agents can verify each other's identity without a shared authority — only knowledge of the other agent's address is needed.

---

## Security Properties

| Property | Mechanism |
|----------|-----------|
| Master key never leaves Keychain | Stored with `kSecAttrAccessibleWhenUnlocked`, read requires `LAContext` biometric auth |
| Agent keys never stored | Re-derived on demand via HMAC-SHA512 from master key |
| Device keys hardware-bound | Secure Enclave P-256 via App Attest (`DCAppAttestService`) |
| Anti-replay | Per-device monotonic counter (`cnt`) persisted in `UserDefaults`; server rejects seen values |
| Domain separation | `Osaurus Signed Message` and `Osaurus Signed Access` prefixes prevent cross-protocol signature reuse |
| Recovery code single-use | Generated from `SecRandomCopyBytes`, shown once, never stored on device |
| Canonical encoding | Access key payloads use sorted-key JSON for deterministic signature verification |
| Memory safety | Master key bytes are zeroed after use (`memset` / index-level zeroing) |

---

## File Reference

| File | Responsibility |
|------|---------------|
| `MasterKey.swift` | Generate, store, read, sign with the secp256k1 master key in iCloud Keychain |
| `AgentKey.swift` | Deterministic child key derivation (HMAC-SHA512) and signing for per-agent identities |
| `DeviceKey.swift` | App Attest key generation, attestation, assertion, and software fallback |
| `OsaurusIdentity.swift` | Public entry point — orchestrates setup and two-layer request signing |
| `IdentityModels.swift` | Data types: `OsaurusID`, `TokenHeader`, `TokenPayload`, `AccessKeyPayload`, `AccessKeyInfo`, `AgentInfo`, `RevocationSnapshot` |
| `APIKeyManager.swift` | Generate, persist, and revoke `osk-v1` access keys (metadata in Keychain) |
| `APIKeyValidator.swift` | Immutable, lock-free access key validation via ecrecover + whitelist + revocation |
| `WhitelistStore.swift` | Master-level and per-agent address whitelist with Keychain persistence |
| `RevocationStore.swift` | Individual and bulk access key revocation with Keychain persistence |
| `CounterStore.swift` | Per-device monotonic counter in `UserDefaults` |
| `RecoveryManager.swift` | One-time recovery code generation at identity creation |
| `CryptoHelpers.swift` | Keccak-256, domain-separated signing, ecrecover, address derivation, encoding utilities |
| `OsaurusIdentityError.swift` | Error types for the identity system |
