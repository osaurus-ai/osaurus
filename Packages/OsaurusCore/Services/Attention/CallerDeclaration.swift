//
//  CallerDeclaration.swift
//  osaurus
//
//  A colleague's agent calling one of this Mac's shared agents says so with
//  `osaurus_caller` on `/agents/{id}/run`: its agent address and name, and
//  an EIP-191 signature by that agent's key (docs/MOBILE_PROTOCOL.md §21.5).
//  Version 2 signs
//  `osaurus-caller-v2:<target agent address>:<session_id>:<sha256(name|owner_handle)>`,
//  so the name and owner handle are covered too. Version 1 signed only
//  `osaurus-caller-v1:<target agent address>:<session_id>`; it is still
//  accepted, with the name and owner shown as unverified.
//
//  A verified declaration makes the caller a `remoteAgent` participant: its
//  turns are labelled with the agent's name and address and read as a
//  participant's words. It grants nothing; the access key still decides
//  what the caller may reach. Names the workspace roster knows always win
//  over what the caller states.
//

import CryptoKit
import Foundation

struct OsaurusCallerDeclaration: Codable, Sendable, Equatable {
    let agent_address: String
    var agent_name: String? = nil
    /// The calling agent's owner's handle, as the caller states it. Shown
    /// only when the workspace roster can't name the owner.
    var owner_handle: String? = nil
    /// 0x-prefixed 65-byte hex signature.
    let signature: String

    /// Which message a signature covered.
    enum Verification: Equatable, Sendable {
        /// Address, name and owner handle are all signed.
        case v2
        /// Only the address is signed; name and owner are the caller's word.
        case v1
    }

    static let nameLimit = 80

    static func message(targetAgentAddress: String, sessionId: String) -> String {
        "osaurus-caller-v1:\(targetAgentAddress.lowercased()):\(sessionId)"
    }

    static func messageV2(
        targetAgentAddress: String, sessionId: String, agentName: String?, ownerHandle: String?
    ) -> String {
        let identity = "\(cleanName(agentName) ?? "")|\(Participant.normalizedHandle(cleanName(ownerHandle)) ?? "")"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "osaurus-caller-v2:\(targetAgentAddress.lowercased()):\(sessionId):\(digest)"
    }

    /// Signs a v2 declaration with the calling agent's derived child key.
    static func signed(
        agentAddress: String,
        agentName: String?,
        ownerHandle: String?,
        targetAgentAddress: String,
        sessionId: String,
        agentPrivateKey: Data
    ) throws -> OsaurusCallerDeclaration {
        let name = cleanName(agentName)
        let owner = Participant.normalizedHandle(cleanName(ownerHandle))
        let signature = try signEIP191Message(
            messageV2(targetAgentAddress: targetAgentAddress, sessionId: sessionId, agentName: name, ownerHandle: owner),
            privateKey: agentPrivateKey
        )
        return OsaurusCallerDeclaration(
            agent_address: agentAddress.lowercased(),
            agent_name: name,
            owner_handle: owner,
            signature: "0x" + signature.hexEncodedString
        )
    }

    /// Which version the signature recovers to `agent_address` for, for this
    /// target and conversation. Nil for another agent or session.
    func verification(targetAgentAddress: String, sessionId: String) -> Verification? {
        let hex = signature.hasPrefix("0x") || signature.hasPrefix("0X") ? String(signature.dropFirst(2)) : signature
        guard let data = Data(hexEncoded: hex), data.count == 65 else { return nil }
        func recovers(_ message: String) -> Bool {
            guard
                let recovered = try? recoverAddress(
                    payload: Data(message.utf8), signature: data, domainPrefix: "Ethereum Signed Message")
            else { return false }
            return recovered.lowercased() == agent_address.lowercased()
        }
        let v2 = Self.messageV2(
            targetAgentAddress: targetAgentAddress, sessionId: sessionId, agentName: agent_name,
            ownerHandle: owner_handle)
        if recovers(v2) { return .v2 }
        if recovers(Self.message(targetAgentAddress: targetAgentAddress, sessionId: sessionId)) { return .v1 }
        return nil
    }

    func verifies(targetAgentAddress: String, sessionId: String) -> Bool {
        verification(targetAgentAddress: targetAgentAddress, sessionId: sessionId) != nil
    }

    /// The session context with the caller recorded as this agent. Roster
    /// names win; a v1 declaration's own name and owner are marked unverified.
    func applying(
        to context: WorkspaceSessionContext,
        rosterOwnerHandle: String?,
        rosterAgentName: String? = nil,
        verification: Verification = .v2
    ) -> WorkspaceSessionContext {
        var context = context
        context.callerKind = .remoteAgent
        context.callerAgentAddress = agent_address.lowercased()
        let rosterName = Self.cleanName(rosterAgentName)
        let rosterOwner = Participant.normalizedHandle(Self.cleanName(rosterOwnerHandle))
        context.callerAgentName = rosterName ?? Self.cleanName(agent_name)
        context.callerAgentOwnerHandle = rosterOwner ?? Participant.normalizedHandle(Self.cleanName(owner_handle))
        let nameFromCaller = rosterName == nil && context.callerAgentName != nil
        let ownerFromCaller = rosterOwner == nil && context.callerAgentOwnerHandle != nil
        context.callerAgentIdentityUnverified =
            verification == .v1 && (nameFromCaller || ownerFromCaller) ? true : nil
        return context
    }

    /// One line, no control characters, capped.
    static func cleanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : Character(scalar)
        }
        return Participant.nonEmpty(String(String(scalars).prefix(nameLimit)))
    }
}
