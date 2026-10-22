//
//  TemplateSigner.swift
//  osaurus
//
//  Template signatures. Export signs the template's content hash with the
//  master key, so a shared file carries the sender's Osaurus ID (files
//  signed earlier with an agent's key still verify). Verification recovers
//  the address from the signature and compares it with `author.address`.
//  Any edit changes the hash, and `Template.sealed()` drops the stale
//  signature, so an edited template reads as unsigned until re-exported.
//

import Foundation
import LocalAuthentication

public enum TemplateSignatureStatus: Equatable, Sendable {
    case unsigned
    /// Valid signature. `knownAgentID` is set when the signing address
    /// belongs to an agent on this Mac.
    case signed(address: String, knownAgentID: UUID?)
    /// A signature that does not match the content or the stated address.
    case invalid

    /// Names the signer by address, so two files signed by different
    /// Osaurus IDs never read the same. The author's self-chosen name is
    /// shown separately by the views.
    public var label: String {
        switch self {
        case .unsigned: return L("Unsigned")
        case .signed(let address, let known):
            return known == nil
                ? L("Signed by \(SharedAgentIdentity.shortAddress(address))") : L("Signed by an agent on this Mac")
        case .invalid: return L("Signature does not match")
        }
    }

    public var isValidSignature: Bool {
        if case .signed = self { return true }
        return false
    }

    public var address: String? {
        if case .signed(let address, _) = self { return address }
        return nil
    }
}

public enum TemplateSigner {

    /// Pure verification core.
    static func status(of template: Template, knownAgent: (String) -> UUID?) -> TemplateSignatureStatus {
        guard let author = template.author, author.isSigned,
            let address = author.address, let signatureHex = author.signature
        else { return .unsigned }
        guard template.hashIsValid, let signature = Data(hexEncoded: signatureHex),
            let recovered = try? recoverAddress(
                payload: Data(template.contentHash.utf8), signature: signature, domainPrefix: templateSignatureDomain),
            recovered.lowercased() == address.lowercased()
        else { return .invalid }
        return .signed(address: recovered, knownAgentID: knownAgent(recovered))
    }

    public static func status(of template: Template) -> TemplateSignatureStatus {
        status(of: template) { AgentIdentityRegistry.shared.agentId(forAddress: $0) }
    }

    /// Signer continuity between versions of one template id. When a
    /// version already here is validly signed, a newer version must carry
    /// a valid signature from the same address: a file that drops the
    /// signature or is signed by someone else is not an update of it.
    /// Returns the address the local version was signed by on a mismatch.
    static func continuityBreak(
        from local: [Template], to incoming: Template, knownAgent: (String) -> UUID? = { _ in nil }
    ) -> String? {
        let signed = local.sorted { $0.version > $1.version }
            .compactMap { status(of: $0, knownAgent: knownAgent).address }
        guard let expected = signed.first else { return nil }
        let actual = status(of: incoming, knownAgent: knownAgent).address
        return actual?.lowercased() == expected.lowercased() ? nil : expected
    }

    /// Sign with a raw key (tests, and the live path below).
    static func signed(_ template: Template, privateKey: Data, authorName: String?) throws -> Template {
        var copy = template
        let address = try deriveOsaurusId(from: privateKey)
        // The address is hashed content; the signature is not.
        copy.author = TemplateAuthor(name: authorName ?? copy.author?.name, address: address)
        copy = copy.sealed()
        let signature = try signTemplatePayload(Data(copy.contentHash.utf8), privateKey: privateKey)
        copy.author?.signature = signature.hexEncodedString
        return copy
    }

    /// Sign with the master key, so the file carries the sender's Osaurus
    /// ID. The template domain prefix keeps this signature from being
    /// valid for anything but a template. Reading the key may prompt for
    /// authentication.
    public static func signedWithMasterKey(_ template: Template, authorName: String? = nil) throws -> Template {
        var master = try MasterKey.getPrivateKey(context: OsaurusIdentityContext.biometric())
        defer { master.zeroOut() }
        return try signed(template, privateKey: master, authorName: authorName)
    }
}
