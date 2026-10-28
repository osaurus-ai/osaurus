//
//  TemplateShareTests.swift
//  OsaurusCoreTests
//
//  File sharing: what the sanitizer leaves out, the exported bytes reading
//  back as the same template, and signatures surviving the file and
//  breaking on edits.
//

import Foundation
import Testing

@testable import OsaurusCore

struct TemplateShareTests {
    private static func agentWithLocalDetails(name: String = "Client Intake") -> Template {
        var entry = AgentEntry(name: name)
        entry.workingFolder = .value("/Volumes/Work/Clients")
        var groups = AgentToolGroupsEntry()
        groups.enabled = ["CRM"]
        entry.mcpServers = groups
        var template = AgentTemplate(name: name, agent: entry)
        template.serverHints = [
            MCPServerHint(
                name: "CRM", url: "https://user:pw@crm.example.com/s/9f2c81ab77de4410aa93/mcp?api_key=sk-live&team=ops",
                command: nil, args: ["--token", "sk-live-123", "/Volumes/Work/config.json"])
        ]
        return template.sealed()
    }

    @Test
    func theSanitizerDropsSecretsAndMachinePaths_andIsIdempotent() throws {
        let clean = TemplateExportSanitizer.sanitized(Self.agentWithLocalDetails())
        #expect(clean.agent.workingFolder.valueOrNil == "Clients")
        let hint = try #require(clean.serverHints.first)
        #expect(hint.url == "https://crm.example.com/s/YOUR_KEY/mcp?team=ops")
        #expect(hint.args == ["--token", "YOUR_KEY", "config.json"])

        #expect(clean.hashIsValid)
        #expect(TemplateExportSanitizer.sanitized(clean) == clean)
    }

    @Test
    func agentWorkingFoldersTravelAsPortablePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(TemplateExportSanitizer.portablePath(home + "/Clients") == "~/Clients")
        #expect(TemplateExportSanitizer.portablePath("/Volumes/Work/Clients") == "Clients")
        #expect(TemplateExportSanitizer.portablePath("~/Clients") == "~/Clients")
    }

    @Test
    func theExportedFileReadsBackAsTheSameTemplate() throws {
        let template = Self.agentWithLocalDetails()
        let data = try TemplateFileExport.exportData(template)
        let parsed = try Template.parse(String(decoding: data, as: UTF8.self))
        let sanitized = TemplateExportSanitizer.sanitized(template)
        #expect(parsed.contentHash == sanitized.contentHash)
        #expect(parsed.payload == sanitized.payload)
        #expect(parsed.hashIsValid)
        #expect(TemplateFileExport.suggestedFileName(template) == "client-intake-v1.osaurustemplate")
    }

    @Test
    func aSignatureSurvivesTheFile_andAnyEditDropsIt() throws {
        let signed = try TemplateSigner.signed(
            TemplateExportSanitizer.sanitized(Self.agentWithLocalDetails()),
            privateKey: TestKeys.alicePrivateKey, authorName: "Alice")
        let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        #expect(TemplateSigner.status(of: signed, knownAgent: { _ in nil }) == .signed(address: alice, knownAgentID: nil))
        #expect(
            TemplateSigner.status(of: signed, knownAgent: { _ in nil }).label
                == "Signed by \(SharedAgentIdentity.shortAddress(alice))")
        // A signed template is the signer's content: the sanitizer leaves it alone.
        #expect(TemplateExportSanitizer.sanitized(signed) == signed)

        let read = try Template.parse(String(decoding: try TemplateFileExport.exportData(signed), as: UTF8.self))
        let known = UUID()
        #expect(TemplateSigner.status(of: read, knownAgent: { $0 == alice ? known : nil }) == .signed(address: alice, knownAgentID: known))

        var edited = read
        edited.summary = "Changed"
        #expect(TemplateSigner.status(of: edited, knownAgent: { _ in nil }) == .invalid, "stale hash")
        #expect(TemplateSigner.status(of: edited.sealed(), knownAgent: { _ in nil }) == .unsigned, "resealing drops the signature")

        var forged = read
        forged.author?.address = try deriveOsaurusId(from: TestKeys.bobPrivateKey)
        #expect(TemplateSigner.status(of: forged.sealed(), knownAgent: { _ in nil }) != .signed(address: alice, knownAgentID: nil))
    }

    @Test
    func signerContinuity_requiresTheSameAddressOnceAVersionIsSigned() throws {
        let base = TemplateExportSanitizer.sanitized(Self.agentWithLocalDetails())
        let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        let v1Alice = try TemplateSigner.signed(base, privateKey: TestKeys.alicePrivateKey, authorName: "Alice")
        var v2 = base
        v2.version = 2
        v2.summary = "Second"
        let v2Unsigned = v2.sealed()
        let v2Alice = try TemplateSigner.signed(v2, privateKey: TestKeys.alicePrivateKey, authorName: nil)
        let v2Bob = try TemplateSigner.signed(v2, privateKey: TestKeys.bobPrivateKey, authorName: "Alice")

        // Nothing signed locally: anything goes, including an upgrade to signed.
        #expect(TemplateSigner.continuityBreak(from: [base], to: v2Unsigned) == nil)
        #expect(TemplateSigner.continuityBreak(from: [base], to: v2Alice) == nil)
        // Alice signed v1: v2 must be hers.
        #expect(TemplateSigner.continuityBreak(from: [v1Alice], to: v2Alice) == nil)
        #expect(TemplateSigner.continuityBreak(from: [v1Alice], to: v2Unsigned)?.lowercased() == alice.lowercased())
        #expect(TemplateSigner.continuityBreak(from: [v1Alice], to: v2Bob)?.lowercased() == alice.lowercased())
        // A tampered copy of her signature does not count as hers.
        var tampered = v2Alice
        tampered.summary = "Edited after signing"
        #expect(TemplateSigner.continuityBreak(from: [v1Alice], to: tampered)?.lowercased() == alice.lowercased())
    }
}

@Suite(.serialized)
@MainActor
struct TemplateImportStoreTests {
    private static func intake(name: String = "Client Intake") -> Template {
        AgentTemplate(name: name, agent: AgentEntry(name: name))
    }

    private func withStore(_ body: @MainActor @Sendable (TemplateStore) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("template-bundle-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            let store = TemplateStore.shared
            store.reload()
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
                store.reload()
            }
            try body(store)
        }
    }

    @Test
    func aTamperedSignedTemplateIsRefused_notResealed() async throws {
        try await withStore { store in
            let signed = try TemplateSigner.signed(
                TemplateExportSanitizer.sanitized(Self.intake()), privateKey: TestKeys.alicePrivateKey,
                authorName: "Alice")
            var tampered = signed
            tampered.summary = "Edited in transit"
            #expect(TemplateSigner.status(of: tampered) == .invalid)
            #expect(throws: TemplateStore.StoreError.signatureMismatch) { try store.importTemplate(tampered) }
            #expect(throws: TemplateStore.StoreError.signatureMismatch) { try store.store(exactVersion: tampered) }
            #expect(store.versions(of: signed.id).isEmpty)

            // The honest file imports as signed.
            let stored = try store.importTemplate(signed)
            #expect(TemplateSigner.status(of: stored).isValidSignature)
            #expect(stored.contentHash == signed.contentHash)

            // An unsigned template with a stale hash is still resealed.
            var stale = Self.intake(name: "Stale")
            stale.contentHash = "not-a-hash"
            let resealed = try store.importTemplate(stale)
            #expect(resealed.hashIsValid)
        }
    }

    @Test
    func aSignedTemplateOnlyUpdatesFromTheSameSigner() async throws {
        try await withStore { store in
            let base = TemplateExportSanitizer.sanitized(Self.intake())
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
            let v1 = try TemplateSigner.signed(base, privateKey: TestKeys.alicePrivateKey, authorName: "Alice")
            try store.importTemplate(v1)

            var v2 = base
            v2.version = 2
            v2.summary = "Second"
            let unsigned = v2.sealed()
            let byBob = try TemplateSigner.signed(v2, privateKey: TestKeys.bobPrivateKey, authorName: "Alice")
            let byAlice = try TemplateSigner.signed(v2, privateKey: TestKeys.alicePrivateKey, authorName: "Alice")

            #expect(store.disposition(for: unsigned) == .signerMismatch(localAddress: alice))
            #expect(store.disposition(for: byBob) == .signerMismatch(localAddress: alice))
            #expect(throws: TemplateStore.StoreError.signerMismatch(localAddress: alice)) {
                try store.importTemplate(unsigned)
            }
            #expect(throws: TemplateStore.StoreError.signerMismatch(localAddress: alice)) {
                try store.importTemplate(byBob, resolution: .replace)
            }
            #expect(store.versions(of: v1.id).map(\.version) == [1])

            // Keep both forks under a new id; the original stays Alice's.
            let fork = try store.importTemplate(byBob, resolution: .keepBoth(name: "Intake (Bob)"))
            #expect(fork.id != v1.id)
            #expect(fork.name == "Intake (Bob)")
            #expect(store.versions(of: v1.id).map(\.version) == [1])

            // Alice's own v2 is an update.
            #expect(store.disposition(for: byAlice) == .update(fromVersion: 1))
            try store.importTemplate(byAlice)
            #expect(store.latest(id: v1.id)?.version == 2)

            // An unsigned library upgrading to a signed version is allowed.
            let plain = Self.intake(name: "Plain").sealed()
            try store.importTemplate(plain)
            var plain2 = plain
            plain2.version = 2
            let plain2Signed = try TemplateSigner.signed(plain2, privateKey: TestKeys.bobPrivateKey, authorName: nil)
            #expect(store.disposition(for: plain2Signed) == .update(fromVersion: 1))
        }
    }

    @Test
    func aConflictWithoutAChoiceIsRefused() async throws {
        try await withStore { store in
            let v1 = Self.intake().sealed()
            try store.importTemplate(v1)
            var other = v1
            other.summary = "Different content, same version"
            other = other.sealed()
            #expect(store.disposition(for: other) == .conflict)
            #expect(throws: TemplateStore.StoreError.conflictNeedsResolution) { try store.importTemplate(other) }
            #expect(store.versions(of: v1.id).map(\.version) == [1])
            let replaced = try store.importTemplate(other, resolution: .replace)
            #expect(replaced.version == 2)
        }
    }
}
