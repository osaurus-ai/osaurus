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
    /// would derive at their stored `agentIndex`. These agents were minted under
    /// a previous master.
    public let mismatchedAgents: [Agent]

    /// osk-v1 keys whose `iss` does not match the current master and does not
    /// match any current agent's derived address. They were signed by a key
    /// the current master can no longer reproduce, so the validator will reject
    /// them.
    public let staleAccessKeys: [AccessKeyInfo]

    public var hasDrift: Bool {
        !mismatchedAgents.isEmpty || !staleAccessKeys.isEmpty
    }

    public init(mismatchedAgents: [Agent], staleAccessKeys: [AccessKeyInfo]) {
        self.mismatchedAgents = mismatchedAgents
        self.staleAccessKeys = staleAccessKeys
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
    public static func diagnose(
        masterKey: Data,
        agents: [Agent],
        accessKeys: [AccessKeyInfo]
    ) -> IdentityDrift {
        var mismatched: [Agent] = []

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
            guard let storedIndex = agent.agentIndex else { continue }

            let storedLower = storedAddress.lowercased()

            do {
                let derived = try AgentKey.deriveAddress(masterKey: masterKey, index: storedIndex)
                let derivedLower = derived.lowercased()

                if storedLower != derivedLower {
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

        return IdentityDrift(mismatchedAgents: mismatched, staleAccessKeys: stale)
    }
}
