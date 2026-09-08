import Foundation
import LocalAuthentication

/// Produces the agent-key proof required to share an agent with a workspace.
///
/// Sharing must prove the caller controls the AGENT key (not the master key):
/// an EIP-191 `personal_sign` by the agent's derived child key over
/// `osaurus-workspaces:share:<workspace_id>:<agent_address_lowercase>:<unix_timestamp>`
/// with a ±5 minute server-side window. Agent keys are derived from the
/// master key (`AgentKey.derive`), so the proof is minted locally — same
/// pattern as the relay tunnel's agent auth.
enum WorkspacesAgentProofSigner {
    /// Deterministic message layout, split out for tests.
    static func proofMessage(workspaceId: String, agentAddress: String, timestamp: Int) -> String {
        "osaurus-workspaces:share:\(workspaceId):\(agentAddress.lowercased()):\(timestamp)"
    }

    /// Pure signing core: derives the agent child key from `masterKey` at
    /// `agentIndex` and signs the proof message. The caller owns zeroing
    /// `masterKey`.
    static func signProof(
        workspaceId: String,
        agentAddress: String,
        timestamp: Int,
        masterKey: Data,
        agentIndex: UInt32
    ) throws -> OsaurusRouterWorkspaceShareAgentBody.Proof {
        var childKey = AgentKey.derive(masterKey: masterKey, index: agentIndex)
        defer { childKey.zeroOut() }
        let message = proofMessage(
            workspaceId: workspaceId, agentAddress: agentAddress, timestamp: timestamp
        )
        let signature = try signEIP191Message(message, privateKey: childKey)
        return OsaurusRouterWorkspaceShareAgentBody.Proof(
            timestamp: timestamp,
            signature: "0x" + signature.hexEncodedString
        )
    }

    /// Loads the master key (biometric-gated, off the main actor — the
    /// keychain read blocks on securityd XPC) and mints a fresh proof for
    /// the given agent.
    static func makeProof(
        workspaceId: String,
        agentAddress: String,
        agentIndex: UInt32,
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> OsaurusRouterWorkspaceShareAgentBody.Proof {
        try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 300
            var masterKey = try MasterKey.getPrivateKey(context: context)
            defer { masterKey.zeroOut() }
            return try signProof(
                workspaceId: workspaceId,
                agentAddress: agentAddress,
                timestamp: timestamp,
                masterKey: masterKey,
                agentIndex: agentIndex
            )
        }.value
    }
}
