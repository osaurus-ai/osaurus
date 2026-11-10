//
//  TemplateShareTests.swift
//  OsaurusCoreTests
//
//  File sharing: what the sanitizer leaves out, the exported bytes reading
//  back as the same template, signatures surviving the file and breaking on
//  edits, and bundled workflows reusing a local copy.
//

import Foundation
import Testing

@testable import OsaurusCore

struct TemplateShareTests {
    private static func workflowWithLocalDetails() -> Template {
        var def = WF.intake()
        def.secrets = [SecretRequirement(key: "crm_token", label: "CRM token")]
        def.nodes.append(
            WorkflowNode(
                id: "ask", name: "Ask",
                kind: .dialog(
                    DialogSpec(
                        title: "Details",
                        fields: [
                            DialogField(key: "api_key", label: "API key", type: .secret, defaultValue: .string("sk-live")),
                            DialogField(key: "folder", label: "Folder", type: .folder, defaultValue: .string("/Volumes/X")),
                            DialogField(key: "firm", label: "Firm", defaultValue: .string("Acme")),
                        ]))))
        def.examples = [
            WorkflowExample(
                name: "Sample",
                input: .object([
                    "client": .string("Acme"), "crm_token": .string("secret"), "api_key": .string("sk-live"),
                    "path": .string("/Volumes/Work/clients.csv"),
                ]))
        ]
        return WF.template(def).sealed()
    }

    @Test
    func theSanitizerDropsSecretsAndMachinePaths_andIsIdempotent() throws {
        let clean = TemplateExportSanitizer.sanitized(Self.workflowWithLocalDetails())
        let def = try #require(clean.workflow)
        let example = try #require(def.examples.first?.input.objectValue)
        #expect(example["crm_token"] == nil)
        #expect(example["api_key"] == nil)
        #expect(example["client"] == .string("Acme"))
        #expect(example["path"] == .string("clients.csv"))

        guard case .dialog(let spec)? = def.nodes.first(where: { $0.id == "ask" })?.kind else {
            Issue.record("dialog node missing")
            return
        }
        #expect(spec.fields.first { $0.key == "api_key" }?.defaultValue == nil)
        #expect(spec.fields.first { $0.key == "folder" }?.defaultValue == nil)
        #expect(spec.fields.first { $0.key == "firm" }?.defaultValue == .string("Acme"))

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
        let template = Self.workflowWithLocalDetails()
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
            TemplateExportSanitizer.sanitized(Self.workflowWithLocalDetails()),
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
        let base = TemplateExportSanitizer.sanitized(Self.workflowWithLocalDetails())
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
struct TemplateBundleImportTests {
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
    func aBundledWorkflowReusesTheSameOrHigherLocalVersion() async throws {
        try await withStore { store in
            var v2 = WF.template(WF.intake())
            v2.version = 2
            v2 = v2.sealed()
            try store.importTemplate(v2)

            var v1 = v2
            v1.version = 1
            v1.summary = "Older"
            v1 = v1.sealed()
            #expect(try !TemplateBundleImport.importBundled(v1, into: store))
            #expect(try !TemplateBundleImport.importBundled(v2, into: store))
            #expect(store.versions(of: v2.id).map(\.version) == [2], "same or older bundles are not stored again")

            var v3 = v2
            v3.version = 3
            v3.summary = "Newer"
            v3 = v3.sealed()
            #expect(try TemplateBundleImport.importBundled(v3, into: store), "a newer version is stored")
            #expect(store.latest(id: v2.id)?.version == 3)

            var conflicting = v3
            conflicting.summary = "Same version, other content"
            conflicting = conflicting.sealed()
            #expect(try !TemplateBundleImport.importBundled(conflicting, into: store))
            #expect(store.latest(id: v2.id)?.summary == "Newer", "a same-version conflict keeps the local copy")
        }
    }

    @Test
    func aTamperedSignedTemplateIsRefused_notResealed() async throws {
        try await withStore { store in
            let signed = try TemplateSigner.signed(
                TemplateExportSanitizer.sanitized(WF.template(WF.intake())), privateKey: TestKeys.alicePrivateKey,
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
            var stale = WF.template(WF.intake(), name: "Stale")
            stale.contentHash = "not-a-hash"
            let resealed = try store.importTemplate(stale)
            #expect(resealed.hashIsValid)
        }
    }

    @Test
    func aSignedTemplateOnlyUpdatesFromTheSameSigner() async throws {
        try await withStore { store in
            let base = TemplateExportSanitizer.sanitized(WF.template(WF.intake()))
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
            let plain = WF.template(WF.intake(), name: "Plain").sealed()
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
            let v1 = WF.template(WF.intake()).sealed()
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

// MARK: - Deep-link download

final class TemplateFetchStubProtocol: URLProtocol, @unchecked Sendable {
    enum Route {
        case body(String, status: Int)
        case redirect(to: String)
        /// 200 with the body only when `X-Workspace-Attestation` is `token`.
        case gated(String, token: String)
    }

    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            routes = [:]
            seen = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let route = Self.lock.withLock { () -> Route? in
            Self.seen.append(request)
            return Self.routes[url.absoluteString]
        }
        switch route {
        case .redirect(let target)?:
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let text, let status)?:
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .gated(let text, let token)?:
            let allowed = request.value(forHTTPHeaderField: "X-Workspace-Attestation") == token
            let response = HTTPURLResponse(
                url: url, statusCode: allowed ? 200 : 403, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((allowed ? text : #"{"error":"workspace_required"}"#).utf8))
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct TemplateImportRouterFetchTests {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TemplateFetchStubProtocol.self]
        return config
    }

    @Test
    func onlyHTTPSHopsAreFollowed_andTheFinalHostIsReported() async throws {
        TemplateFetchStubProtocol.reset()
        TemplateFetchStubProtocol.routes["https://share.example.com/t.osaurustemplate"] = .redirect(
            to: "https://cdn.example.net/t.json")
        TemplateFetchStubProtocol.routes["https://cdn.example.net/t.json"] = .body("{\"name\":\"x\"}", status: 200)
        TemplateFetchStubProtocol.routes["https://share.example.com/down"] = .redirect(to: "http://cdn.example.net/t.json")
        TemplateFetchStubProtocol.routes["http://cdn.example.net/t.json"] = .body("plain", status: 200)

        let ok = try await TemplateImportRouter.fetch(
            URL(string: "https://share.example.com/t.osaurustemplate")!, configuration: configuration())
        #expect(ok.text == "{\"name\":\"x\"}")
        #expect(ok.host == "cdn.example.net")

        do {
            _ = try await TemplateImportRouter.fetch(URL(string: "https://share.example.com/down")!, configuration: configuration())
            Issue.record("an http hop must be refused")
        } catch let error as TemplateImportRouter.FetchError {
            #expect(error == .insecureRedirect("http://cdn.example.net/t.json"))
        }
        #expect(!TemplateFetchStubProtocol.seen.contains { $0.url?.scheme == "http" }, "the http hop was never requested")

        do {
            _ = try await TemplateImportRouter.fetch(URL(string: "http://share.example.com/x")!, configuration: configuration())
            Issue.record("a plain http start must be refused")
        } catch let error as TemplateImportRouter.FetchError {
            #expect(error == .insecureRedirect("http://share.example.com/x"))
        }
    }

    @Test
    func aWorkspaceListingIsFetchedWithEachWorkspacesAttestationInTurn() async throws {
        TemplateFetchStubProtocol.reset()
        let url = URL(string: "https://registry.example.com/workflows/x/versions/1/template.json")!
        TemplateFetchStubProtocol.routes[url.absoluteString] = .gated("{\"name\":\"x\"}", token: "att-ws-b")

        let fetched = try await TemplateImportRouter.fetch(
            url, workspaceCandidates: ["ws-a", "ws-b", "ws-c"], attestation: { "att-\($0)" },
            configuration: configuration())
        #expect(fetched.text == "{\"name\":\"x\"}")
        let sent = TemplateFetchStubProtocol.seen.map { $0.value(forHTTPHeaderField: "X-Workspace-Attestation") }
        #expect(sent == [nil, "att-ws-a", "att-ws-b"], "plain first, then one workspace at a time, stopping when let in")
        #expect(TemplateFetchStubProtocol.seen.allSatisfy { $0.url == url }, "the token never rides in the URL")

        TemplateFetchStubProtocol.reset()
        TemplateFetchStubProtocol.routes[url.absoluteString] = .gated("{}", token: "nobody")
        do {
            _ = try await TemplateImportRouter.fetch(
                url, workspaceCandidates: ["ws-a"], attestation: { "att-\($0)" }, configuration: configuration())
            Issue.record("no workspace can read it")
        } catch let error as TemplateImportRouter.FetchError {
            #expect(error == .workspaceRequired)
        }

        TemplateFetchStubProtocol.reset()
        TemplateFetchStubProtocol.routes[url.absoluteString] = .gated("{}", token: "nobody")
        do {
            _ = try await TemplateImportRouter.fetch(
                url, workspaceCandidates: [], attestation: { "att-\($0)" }, configuration: configuration())
            Issue.record("a 403 without workspaces is a plain 403")
        } catch let error as TemplateImportRouter.FetchError {
            #expect(error == .status(403))
        }
    }

    @Test
    func anAttestationNeverFollowsARedirectToAnotherHost() {
        var request = URLRequest(url: URL(string: "https://cdn.example.net/t.json")!)
        request.setValue("att", forHTTPHeaderField: "X-Workspace-Attestation")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let elsewhere = TemplateImportRouter.HTTPSRedirectGuard.forwarded(request, originHost: "registry.example.com")
        #expect(elsewhere.value(forHTTPHeaderField: "X-Workspace-Attestation") == nil)
        #expect(elsewhere.value(forHTTPHeaderField: "Accept") == "application/json")
        let sameHost = TemplateImportRouter.HTTPSRedirectGuard.forwarded(request, originHost: "cdn.example.net")
        #expect(sameHost.value(forHTTPHeaderField: "X-Workspace-Attestation") == "att")
    }

    @Test
    func aWorkspaceRowSaysWhetherInstallingAddsUpdatesOrIsDone() {
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: nil, sharedVersion: 2) == .notInstalled)
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: 1, sharedVersion: 2) == .update(from: 1))
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: 2, sharedVersion: 2) == .installed)
        #expect(WorkspaceWorkflowCatalog.installState(localVersion: 3, sharedVersion: 2) == .installed)
    }

    @Test
    func remoteImportsCarryTheirSourceHost() {
        let remote = PendingTemplateImport(text: "{}", kind: .workflow, sourceHost: "cdn.example.net")
        #expect(remote.isRemote)
        #expect(PendingTemplateImport(text: "{}", kind: .workflow).isRemote == false)
    }

    @Test
    @MainActor
    func theShareCardRendersAtTwiceTheRegistrysImageSize() throws {
        let content = WorkflowShareCardContent(
            name: "Client Intake", summary: "Sorts new leads into the CRM and drafts a reply.",
            facts: "5 steps · Runs on this Mac", handle: "@alice",
            url: URL(string: "https://store.osaurus.ai/w/client-intake/")!)
        #expect(content.displayURL == "store.osaurus.ai/w/client-intake")

        let image = try #require(WorkflowShareCard.render(content))
        let rep = try #require(image.representations.first)
        #expect(
            rep.pixelsWide == 2400 && rep.pixelsHigh == 1260,
            "1200×630 at 2×, got \(rep.pixelsWide)×\(rep.pixelsHigh)")
        let png = try #require(WorkflowShareCard.png(image))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "a PNG")
        #expect(png.count > 10_000, "not a blank frame")
    }
}
