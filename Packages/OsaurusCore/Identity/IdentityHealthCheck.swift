//
//  IdentityHealthCheck.swift
//  osaurus
//
//  Detects drift between the currently-installed Master Key and the persisted
//  derivatives (agent addresses + osk-v1 access keys) that were derived from
//  some *previous* master. Drift happens when the master in iCloud Keychain
//  is replaced (e.g., by a buggy onboarding re-run, an iCloud Keychain reset,
//  or a manual "Reset Identity" flow on another device that races with this
//  one) without re-deriving everything that depended on the prior master.
//
//  This is a pure computation — no Keychain reads, no biometric prompts.
//  Callers are expected to pass already-unlocked master bytes and zero them
//  out after the call.
//

import Foundation

public struct IdentityDrift: Sendable {
    /// Agents whose stored `agentAddress` does NOT match what the current master
    /// would derive at their stored key path (`agentIndex` + optional
    /// `agentDeviceScope`). These agents were minted under a previous master.
    public let mismatchedAgents: [Agent]

    /// osk-v1 keys whose `iss` does not match the current master and does not
    /// match any current agent's derived address. They were signed by a key
    /// the current master can no longer reproduce, so the validator will reject
    /// them.
    public let staleAccessKeys: [AccessKeyInfo]

    /// Agents whose stored `agentAddress` does not match their stored path
    /// **because the path lost its device scope**: `agentDeviceScope` is nil,
    /// the legacy v1 derivation at `agentIndex` differs, but the device-scoped
    /// v2 derivation under `currentDeviceScope` reproduces the stored address
    /// exactly. This is the downgrade signature — an older build that did not
    /// know the field re-saved the agent and dropped it. The fix is lossless
    /// (write the scope back); nothing needs re-minting or revoking, so these
    /// are NOT counted as drift.
    public let recoverableScopeAgents: [Agent]

    public var hasDrift: Bool {
        !mismatchedAgents.isEmpty || !staleAccessKeys.isEmpty
    }

    public init(
        mismatchedAgents: [Agent],
        staleAccessKeys: [AccessKeyInfo],
        recoverableScopeAgents: [Agent] = []
    ) {
        self.mismatchedAgents = mismatchedAgents
        self.staleAccessKeys = staleAccessKeys
        self.recoverableScopeAgents = recoverableScopeAgents
    }
}

public enum IdentityHealthCheck {

    /// Diagnose drift between the current master and persisted derivatives.
    ///
    /// - Parameters:
    ///   - masterKey: 32-byte secp256k1 master key bytes (already unlocked from
    ///     Keychain). Caller is responsible for wiping these bytes after use.
    ///   - agents: All agents (built-ins included; built-ins without an address
    ///     are skipped automatically).
    ///   - accessKeys: All persisted osk-v1 access key metadata.
    ///   - currentDeviceScope: This device's ID. When supplied, an agent with a
    ///     nil scope whose stored address re-derives under the v2 path at this
    ///     scope is reported as `recoverableScopeAgents` (its scope was lost,
    ///     not its master) instead of `mismatchedAgents`.
    public static func diagnose(
        masterKey: Data,
        agents: [Agent],
        accessKeys: [AccessKeyInfo],
        currentDeviceScope: String? = nil
    ) -> IdentityDrift {
        var mismatched: [Agent] = []
        var recoverable: [Agent] = []

        let currentMasterAddress: OsaurusID
        do {
            currentMasterAddress = try deriveOsaurusId(from: masterKey)
        } catch {
            // If we can't derive an address from the master we have nothing to
            // compare against — treat as no drift rather than spuriously flag
            // every persisted derivative.
            return IdentityDrift(mismatchedAgents: [], staleAccessKeys: [])
        }

        var validAddresses: Set<String> = [currentMasterAddress.lowercased()]

        for agent in agents {
            guard !agent.isBuiltIn else { continue }
            guard let storedAddress = agent.agentAddress else { continue }
            // Re-derive along the agent's own persisted path (legacy v1 or
            // device-scoped v2) so a v2 agent isn't flagged just because a
            // v1 derivation at the same index would differ.
            guard let storedPath = agent.agentKeyPath else { continue }

            let storedLower = storedAddress.lowercased()

            do {
                let derived = try AgentKey.deriveAddress(masterKey: masterKey, path: storedPath)
                let derivedLower = derived.lowercased()

                if storedLower != derivedLower {
                    // Downgrade signature: no scope stored, but the v2 path
                    // under THIS device reproduces the address. Lossless to
                    // fix, and the stored address stays valid throughout.
                    if storedPath.deviceScope == nil, let scope = currentDeviceScope, !scope.isEmpty,
                        let scoped = try? AgentKey.deriveAddress(
                            masterKey: masterKey,
                            path: AgentKeyPath(index: storedPath.index, deviceScope: scope)
                        ),
                        scoped.lowercased() == storedLower
                    {
                        recoverable.append(agent)
                        validAddresses.insert(storedLower)
                        continue
                    }
                    mismatched.append(agent)
                    // The new derived address is what we'd issue *if* the user
                    // chooses Repair. Until then it's only "valid" insofar as
                    // the validator could mint new tokens for it — but the
                    // stored address is the one current keys reference. Track
                    // both so the staleAccessKeys filter doesn't false-positive
                    // on a key the user is about to validate via Recover.
                    validAddresses.insert(derivedLower)
                } else {
                    validAddresses.insert(storedLower)
                }
            } catch {
                // Derivation failure for a specific index is unexpected;
                // treat the agent as mismatched so the user is prompted to
                // repair.
                mismatched.append(agent)
            }
        }

        let stale = accessKeys.filter { key in
            guard !key.revoked else { return false }
            let issLower = key.iss.lowercased()
            return !validAddresses.contains(issLower)
        }

        return IdentityDrift(
            mismatchedAgents: mismatched,
            staleAccessKeys: stale,
            recoverableScopeAgents: recoverable
        )
    }
}
