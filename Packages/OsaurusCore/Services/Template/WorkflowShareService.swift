//
//  WorkflowShareService.swift
//  osaurus
//
//  Publishes a workflow or agent template to the registry, changes who can
//  see it, takes it down, reads back what the registry knows about it
//  (installs, versions, visibility), and sends the signed receipt for a
//  template installed from a registry link. Publishing uploads exactly
//  what Save as File writes: the sanitized template, sealed and signed
//  with the master key. The same key bytes sign the request, so the user
//  sees one authentication prompt and the file's author is always the
//  uploader (the registry rejects anything else).
//
//  Reads come in two kinds. `refreshStats` is unsigned and safe to run in
//  the background: it never touches the key, so it never prompts, and it
//  skips password-protected workflows (which it couldn't read anyway).
//  `refreshOwned` signs with the key, so it runs only when the user opens
//  a published workflow: it reads that one whatever its visibility or
//  status, then lists everything the key owns and brings the local records
//  in line with the registry.
//

import CryptoKit
import Foundation
import LocalAuthentication

public struct WorkflowShareOutcome: Sendable, Equatable {
    public let published: WorkflowsRegistryPublishResult
    public let record: WorkflowRegistryRecord
    /// Set when the workflow was published but the password or workspaces
    /// meant to restrict it didn't save: it is live as Unlisted, and the
    /// user is told so and offered another try.
    public var visibilityError: WorkflowShareError? = nil
    /// For an agent template: what happened to each workflow it bundles.
    public var cascade: [TemplateCascadeResult] = []
    /// How the listing edits asked for with the publish went. The publish
    /// stands whatever they did.
    public var listing: ListingEditsResult? = nil
}

/// What an owner-signed read of a published workflow returned, after the
/// local records were brought in line with the registry.
public struct WorkflowOwnedRefresh: Sendable, Equatable {
    public let detail: WorkflowsRegistryDetail
    public let record: WorkflowRegistryRecord
    /// The handle the registry shows for this Osaurus ID.
    public let authorHandle: String
    public let banned: Bool
}

public enum WorkflowShareError: LocalizedError, Sendable, Equatable {
    case noMasterKey
    case notShared
    /// The registry already has this version with other content; `latest`
    /// is the newest shared version.
    case versionNotNewer(latest: Int)
    /// A password outside the registry's bounds, caught before any upload.
    case invalidPassword
    /// No workspace chosen, or more than the registry takes.
    case invalidWorkspaces
    /// A workspace attestation couldn't be minted (signed out of the
    /// router, not a member, or the workspace is suspended).
    case workspaceAttestation(String)
    /// The registry's publish budget ran out. `publishedWorkflows` is how many
    /// of an agent's workflows went live before it did; publishing again
    /// later skips them.
    case rateLimited(publishedWorkflows: Int)
    case identity(OsaurusIdentityError)
    case api(WorkflowsRegistryAPIError)

    public var errorDescription: String? {
        switch self {
        case .noMasterKey:
            return L("Publishing needs an Osaurus ID. Create one in Identity settings, then publish again.")
        case .notShared:
            return L("This template isn't published.")
        case .versionNotNewer(let latest):
            return L("Version \(latest) is already published. Publish this as version \(latest + 1).")
        case .invalidPassword:
            return L(
                "The password must be \(WorkflowVisibility.passwordLength.lowerBound) to \(WorkflowVisibility.passwordLength.upperBound) characters."
            )
        case .invalidWorkspaces:
            return L("Choose 1 to \(WorkflowVisibility.maxWorkspaces) workspaces to share it with.")
        case .workspaceAttestation(let message):
            return message
        case .rateLimited(let published):
            if published > 0 {
                return L(
                    "\(published) of its workflows published, then the registry paused: too many publishes in a row. Try again in a few minutes; the ones already published won't publish twice."
                )
            }
            return L("Too many changes in a row. Try again in a few minutes.")
        case .identity(let error):
            return error.errorDescription
        case .api(let error):
            return error.errorDescription
        }
    }

    public var diagnosticHint: String? {
        if case .api(let error) = self { return error.diagnosticHint }
        return nil
    }

    public static func == (lhs: WorkflowShareError, rhs: WorkflowShareError) -> Bool {
        switch (lhs, rhs) {
        case (.noMasterKey, .noMasterKey), (.notShared, .notShared),
            (.invalidPassword, .invalidPassword), (.invalidWorkspaces, .invalidWorkspaces):
            return true
        case (.workspaceAttestation(let a), .workspaceAttestation(let b)): return a == b
        case (.versionNotNewer(let a), .versionNotNewer(let b)): return a == b
        case (.rateLimited(let a), .rateLimited(let b)): return a == b
        case (.identity(let a), .identity(let b)): return a.errorDescription == b.errorDescription
        case (.api(let a), .api(let b)): return a == b
        default: return false
        }
    }

    init(_ error: WorkflowsRegistryAPIError) {
        switch error {
        case .versionNotNewer(let latest?): self = .versionNotNewer(latest: latest)
        case .rateLimited: self = .rateLimited(publishedWorkflows: 0)
        default: self = .api(error)
        }
    }
}

@MainActor
public final class WorkflowShareService {
    public static let shared = WorkflowShareService(watchTokens: .shared)

    typealias KeyReader = @MainActor () throws -> Data
    typealias ReceiptKeyReader = @Sendable () async throws -> Data
    typealias AttestationMinter = @Sendable (String) async throws -> String

    let api: WorkflowsRegistryAPIClient
    private let records: WorkflowRegistryRecordStore
    private let readKey: KeyReader
    private let readReceiptKey: ReceiptKeyReader
    private let identityExists: () -> Bool
    /// The workflow and agent templates in this Mac's library, for
    /// reconciling the registry's owned list.
    private let knownTemplateIDs: @MainActor () -> Set<UUID>
    /// Built-in templates aren't the user's to sign or publish.
    private let isBuiltIn: @MainActor (UUID) -> Bool
    private let now: () -> Date
    /// Where the review watch token goes. Nil never asks for one.
    private let watchTokens: RegistryReviewWatchTokens?
    /// A fresh router workspace attestation for this Mac's wallet.
    private let workspaceAttestation: AttestationMinter

    init(
        api: WorkflowsRegistryAPIClient = WorkflowsRegistryAPIClient(),
        records: WorkflowRegistryRecordStore = .shared,
        readKey: @escaping KeyReader = WorkflowShareService.readMasterKey,
        readReceiptKey: @escaping ReceiptKeyReader = WorkflowShareService.readMasterKeyForReceipt,
        identityExists: @escaping () -> Bool = OsaurusIdentity.exists,
        knownTemplateIDs: @escaping @MainActor () -> Set<UUID> = WorkflowShareService.libraryTemplateIDs,
        isBuiltIn: @escaping @MainActor (UUID) -> Bool = WorkflowShareService.isBuiltInTemplate,
        now: @escaping () -> Date = Date.init,
        watchTokens: RegistryReviewWatchTokens? = nil,
        workspaceAttestation: @escaping AttestationMinter = { try await WorkspaceAttestationProvider.shared.attestation(for: $0) }
    ) {
        self.watchTokens = watchTokens
        self.workspaceAttestation = workspaceAttestation
        self.api = api
        self.records = records
        self.readKey = readKey
        self.readReceiptKey = readReceiptKey
        self.identityExists = identityExists
        self.knownTemplateIDs = knownTemplateIDs
        self.isBuiltIn = isBuiltIn
        self.now = now
    }

    static func isBuiltInTemplate(_ id: UUID) -> Bool {
        guard let template = TemplateStore.shared.latest(id: id) else { return false }
        return TemplateStore.shared.isBuiltIn(template)
    }

    static func libraryTemplateIDs() -> Set<UUID> {
        Set(TemplateStore.shared.allTemplates(kind: .workflow).map(\.id))
            .union(TemplateStore.shared.allTemplates(kind: .agent).map(\.id))
            .union(InstalledWorkflowStore.shared.workflows.map(\.templateID))
    }

    /// Reads the master key off the main actor for an install receipt,
    /// reusing a recent Touch ID like the router's request signer.
    nonisolated static func readMasterKeyForReceipt() async throws -> Data {
        try await Task.detached(priority: .utility) {
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 300
            return try MasterKey.getPrivateKey(context: context)
        }.value
    }

    /// Reads the master key; may prompt for authentication.
    static func readMasterKey() throws -> Data {
        guard MasterKey.exists() else { throw WorkflowShareError.noMasterKey }
        do {
            return try MasterKey.getPrivateKey(context: OsaurusIdentityContext.biometric())
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        } catch {
            throw WorkflowShareError.identity(.keychainReadFailed)
        }
    }

    public var registryBaseURL: URL { api.baseURL }

    // MARK: - Publish

    /// Signs and uploads `template`. Publishing unchanged bytes again is
    /// harmless and returns the existing link.
    ///
    /// `visibility` applies to a brand-new listing (or one coming back from
    /// a take-down). Public and Unlisted ride on the upload; Password and
    /// Workspace (`workspaceIDs`) need a second signed request after it, so
    /// the workflow is Unlisted for a moment first and, should that request
    /// fail, stays Unlisted and the outcome says so (`visibilityError`)
    /// rather than throwing: the page is live, and the user can try again
    /// from its dashboard.
    /// Changing an existing listing's visibility is `setVisibility`.
    ///
    /// `listing` (name, topics, example runs) is applied right after, with
    /// the same key read; how it went is `outcome.listing`.
    public func share(
        _ template: Template, authorName: String? = nil, visibility: WorkflowVisibility = .public,
        password: String? = nil, workspaceIDs: [String] = [], listing: ListingEdits? = nil
    ) async throws -> WorkflowShareOutcome {
        try Self.checkPassword(visibility, password)
        try Self.checkWorkspaces(visibility, workspaceIDs)
        var key = try readKey()
        defer { key.zeroOut() }
        let address = try address(from: key)
        var outcome = try await publishAndProtect(
            template, address: address, key: key, authorName: authorName, visibility: visibility, password: password,
            workspaceIDs: workspaceIDs)
        outcome.listing = await followUp(listing, after: outcome, address: address, key: key)
        await ensureWatchToken(address: address, key: key)
        return outcome
    }

    private func followUp(_ listing: ListingEdits?, after outcome: WorkflowShareOutcome, address: String, key: Data)
        async -> ListingEditsResult?
    {
        guard let listing, !listing.isEmpty else { return nil }
        let record = records.record(for: outcome.record.templateID, registry: api.baseURL) ?? outcome.record
        return await applyListingEdits(listing, on: record, address: address, key: key)
    }

    /// Publishes an agent template and, first, the workflows it bundles
    /// that are yours and not live yet (`TemplateCascadePlan`), with the
    /// agent's visibility, so its page links to theirs. One key read for
    /// all of them. A workflow that fails to publish is reported in
    /// `cascade` and doesn't stop the agent: the agent carries it anyway.
    public func shareAgent(
        _ template: Template, authorName: String? = nil, visibility: WorkflowVisibility = .public,
        password: String? = nil, workspaceIDs: [String] = [], publishWorkflows: Bool = true,
        listing: ListingEdits? = nil
    ) async throws -> WorkflowShareOutcome {
        try Self.checkPassword(visibility, password)
        try Self.checkWorkspaces(visibility, workspaceIDs)
        var key = try readKey()
        defer { key.zeroOut() }
        let address = try address(from: key)
        let plan = TemplateCascadePlan.make(
            template: template, visibility: visibility, ownAddress: address, publishWorkflows: publishWorkflows,
            record: { self.records.record(for: $0, registry: self.api.baseURL) },
            isBuiltIn: isBuiltIn)

        var cascade: [TemplateCascadeResult] = []
        for row in plan.rows {
            let status: TemplateCascadeResult.Status
            switch row.state {
            case .alreadyPublished(let record): status = .alreadyPublished(record)
            case .linkedToAuthor(let author), .checksOnPublish(let author): status = .linkedToAuthor(address: author)
            case .bundledOnly(let reason): status = .bundledOnly(reason)
            case .willPublish:
                do {
                    let (_, record) = try await upload(
                        row.template, address: address, key: key, authorName: authorName,
                        visibility: plan.visibility ?? .hidden, publishedWith: template.id)
                    status = .published(record)
                } catch WorkflowShareError.rateLimited {
                    // Every later publish, the agent's included, would be refused too.
                    throw WorkflowShareError.rateLimited(publishedWorkflows: Self.publishedCount(cascade))
                } catch {
                    status = .failed(error.localizedDescription)
                }
            }
            cascade.append(TemplateCascadeResult(templateID: row.template.id, name: row.template.name, status: status))
        }

        do {
            var outcome = try await publishAndProtect(
                template, address: address, key: key, authorName: authorName, visibility: visibility,
                password: password, workspaceIDs: workspaceIDs)
            outcome.cascade = cascade
            outcome.listing = await followUp(listing, after: outcome, address: address, key: key)
            await ensureWatchToken(address: address, key: key)
            return outcome
        } catch WorkflowShareError.rateLimited {
            throw WorkflowShareError.rateLimited(publishedWorkflows: Self.publishedCount(cascade))
        }
    }

    private static func publishedCount(_ cascade: [TemplateCascadeResult]) -> Int {
        cascade.filter { if case .published = $0.status { return true } else { return false } }.count
    }

    private static func checkPassword(_ visibility: WorkflowVisibility, _ password: String?) throws {
        guard visibility == .password else { return }
        guard let password, WorkflowVisibility.isValidPassword(password) else {
            throw WorkflowShareError.invalidPassword
        }
    }

    private static func checkWorkspaces(_ visibility: WorkflowVisibility, _ workspaceIDs: [String]) throws {
        guard visibility == .workspace else { return }
        guard WorkflowVisibility.isValidWorkspaceSelection(workspaceIDs) else {
            throw WorkflowShareError.invalidWorkspaces
        }
    }

    /// One fresh attestation per chosen workspace, in order, deduplicated.
    private func attestations(for workspaceIDs: [String]) async throws -> [String] {
        var seen = Set<String>()
        var tokens: [String] = []
        for id in workspaceIDs where seen.insert(id.lowercased()).inserted {
            do {
                tokens.append(try await workspaceAttestation(id))
            } catch {
                throw WorkflowShareError.workspaceAttestation(error.localizedDescription)
            }
        }
        return tokens
    }

    private func address(from key: Data) throws -> String {
        do {
            return try deriveOsaurusId(from: key).lowercased()
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
    }

    /// Uploads, then sets the password or the workspaces when one was asked
    /// for (see `share`).
    private func publishAndProtect(
        _ template: Template, address: String, key: Data, authorName: String?, visibility: WorkflowVisibility,
        password: String?, workspaceIDs: [String] = []
    ) async throws -> WorkflowShareOutcome {
        let (published, record) = try await upload(
            template, address: address, key: key, authorName: authorName, visibility: visibility, publishedWith: nil)
        var outcome = WorkflowShareOutcome(published: published, record: record)
        let restricts = (visibility == .password && password != nil) || visibility == .workspace
        if restricts, published.visibility != visibility {
            do {
                outcome = WorkflowShareOutcome(
                    published: published,
                    record: try await setVisibility(
                        on: record, address: address, key: key, visibility: visibility, password: password,
                        workspaceIDs: workspaceIDs))
            } catch let error as WorkflowShareError {
                outcome.visibilityError = error
            }
        }
        return outcome
    }

    /// Signs and uploads one template and stores its record. `publishedWith`
    /// names the agent whose publish this is, for a workflow's first page;
    /// a record that already exists keeps its own.
    private func upload(
        _ template: Template, address: String, key: Data, authorName: String?, visibility: WorkflowVisibility,
        publishedWith: UUID?
    ) async throws -> (WorkflowsRegistryPublishResult, WorkflowRegistryRecord) {
        let existing = records.record(for: template.id, registry: api.baseURL)
        do {
            let signed = try TemplateSigner.signed(
                TemplateExportSanitizer.sanitized(template), privateKey: key, authorName: authorName)
            let body = try TemplateFileExport.exportData(signed)
            let bodyHash = Self.sha256Hex(body)

            let published = try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.publishMessage(
                    address: address, bodyHash: bodyHash, nonce: nonce, timestamp: timestamp)
                let signature = try Self.signature(message, key: key)
                return try await self.api.publish(
                    body: body, address: address, nonce: nonce, timestamp: timestamp, signature: signature,
                    visibility: visibility)
            }
            var record = WorkflowRegistryRecord(
                templateID: template.id, registryID: published.id, slug: published.slug,
                version: published.version, contentHash: published.contentHash, url: published.url,
                rawURL: published.rawURL, deepLink: published.deepLink, address: address,
                registry: WorkflowRegistryRecordStore.registryKey(api.baseURL), sharedAt: now(),
                visibility: published.visibility, kind: template.kind)
            // Carry the numbers the registry last reported over a republish.
            if let existing {
                record.installCount = existing.installCount
                record.authorHandle = existing.authorHandle
                record.publishedAt = existing.publishedAt
                record.statsFetchedAt = existing.statsFetchedAt
                record.publishedWith = existing.publishedWith
                record.review = existing.review
                record.reviewSeenAt = existing.reviewSeenAt
                record.liveVersion = existing.liveVersion
                record.listed = existing.listed
            } else {
                record.publishedWith = publishedWith
            }
            record.registryLatestVersion = published.version
            if let live = published.liveVersion { record.liveVersion = live }
            if let inStore = published.listed { record.listed = inStore }
            if let review = published.review { record.applyReview(review) }
            records.set(record)
            return (published, record)
        } catch let error as WorkflowsRegistryAPIError {
            throw WorkflowShareError(error)
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
    }

    // MARK: - Visibility

    /// Changes who can see the published workflow. `password` is required
    /// for `.password` and replaces any earlier one; other visibilities
    /// clear it. Works on a taken-down workflow too, so a listing can be
    /// prepared before it comes back.
    @discardableResult
    public func setVisibility(
        templateID: UUID, visibility: WorkflowVisibility, password: String? = nil, workspaceIDs: [String] = []
    )
        async throws -> WorkflowRegistryRecord
    {
        guard let record = records.record(for: templateID, registry: api.baseURL) else {
            throw WorkflowShareError.notShared
        }
        if visibility == .password {
            guard let password, WorkflowVisibility.isValidPassword(password) else {
                throw WorkflowShareError.invalidPassword
            }
        }
        try Self.checkWorkspaces(visibility, workspaceIDs)
        var key = try readKey()
        defer { key.zeroOut() }
        let address: String
        do {
            address = try deriveOsaurusId(from: key).lowercased()
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
        let updated = try await setVisibility(
            on: record, address: address, key: key, visibility: visibility, password: password,
            workspaceIDs: workspaceIDs)
        await ensureWatchToken(address: address, key: key)
        return updated
    }

    /// Changes an agent's visibility, then moves the workflow pages that
    /// were published with it (`workflowIDs`, see
    /// `TemplateCascadePlan.visibilityFollowers`) to what they inherit, with
    /// one key read. The agent's change throws; a workflow that fails is
    /// returned with its message and leaves the others to go on.
    @discardableResult
    public func setAgentVisibility(
        templateID: UUID, visibility: WorkflowVisibility, password: String? = nil, workspaceIDs: [String] = [],
        workflowIDs: [UUID]
    ) async throws -> [UUID: String] {
        guard let record = records.record(for: templateID, registry: api.baseURL) else {
            throw WorkflowShareError.notShared
        }
        try Self.checkPassword(visibility, password)
        try Self.checkWorkspaces(visibility, workspaceIDs)
        var key = try readKey()
        defer { key.zeroOut() }
        let address = try address(from: key)
        _ = try await setVisibility(
            on: record, address: address, key: key, visibility: visibility, password: password,
            workspaceIDs: workspaceIDs)
        await ensureWatchToken(address: address, key: key)
        guard let inherited = TemplateCascadePlan.inheritedVisibility(visibility) else { return [:] }
        var failed: [UUID: String] = [:]
        for id in workflowIDs {
            guard let workflow = records.record(for: id, registry: api.baseURL), workflow.publishedWith == templateID,
                workflow.visibility != inherited
            else { continue }
            do {
                _ = try await setVisibility(on: workflow, address: address, key: key, visibility: inherited, password: nil)
            } catch {
                failed[id] = error.localizedDescription
            }
        }
        return failed
    }

    private func setVisibility(
        on record: WorkflowRegistryRecord, address: String, key: Data, visibility: WorkflowVisibility,
        password: String?, workspaceIDs: [String] = []
    ) async throws -> WorkflowRegistryRecord {
        let tokens = visibility == .workspace ? try await attestations(for: workspaceIDs) : []
        do {
            let body = try WorkflowsRegistryAPIClient.visibilityBody(
                visibility, password: password, workspaceAttestations: tokens)
            let bodyHash = Self.sha256Hex(body)
            let applied = try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.visibilityMessage(
                    address: address, registryID: record.registryID, bodyHash: bodyHash, nonce: nonce,
                    timestamp: timestamp)
                return try await self.api.setVisibility(
                    id: record.registryID, body: body,
                    signed: WorkflowsRegistrySignature(
                        address: address, nonce: nonce, timestamp: timestamp,
                        signature: try Self.signature(message, key: key)))
            }
            var updated = records.record(for: record.templateID, registry: api.baseURL) ?? record
            updated.visibility = applied.visibility
            updated.workspaceIDs = applied.visibility == .workspace ? applied.workspaceIDs : []
            if let live = applied.liveVersion { updated.liveVersion = live }
            if let inStore = applied.listed { updated.listed = inStore }
            if applied.carriesReview { updated.applyReview(applied.review) }
            updated.updatedAt = now()
            records.set(updated)
            return updated
        } catch let error as WorkflowsRegistryAPIError {
            throw WorkflowShareError(error)
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
    }

    // MARK: - Workspaces

    /// The workflows and agents shared with `workspaceID`, newest share
    /// first. Any member may read it, viewers included; no key is read.
    public func workspaceWorkflows(workspaceID: String) async throws -> [WorkflowsRegistryWorkspaceItem] {
        let token: String
        do {
            token = try await workspaceAttestation(workspaceID)
        } catch {
            throw WorkflowShareError.workspaceAttestation(error.localizedDescription)
        }
        do {
            var items: [WorkflowsRegistryWorkspaceItem] = []
            var offset = 0
            repeat {
                let page = try await api.fetchWorkspaceWorkflows(
                    workspaceID: workspaceID, attestation: token, offset: offset)
                items += page.items
                guard let next = page.nextOffset, next > offset, !page.items.isEmpty else { break }
                offset = next
            } while true
            return items
        } catch let error as WorkflowsRegistryAPIError {
            throw WorkflowShareError(error)
        }
    }

    /// Takes a listing out of one workspace. Its owner needs nothing else;
    /// a workspace owner or admin removing someone else's (`moderating`)
    /// also sends their attestation. Returns the workspaces it is still
    /// shared with. The listing stays Workspace, readable by its owner.
    @discardableResult
    public func unshare(registryID: String, fromWorkspace workspaceID: String, moderating: Bool = false)
        async throws -> [String]
    {
        var key = try readKey()
        defer { key.zeroOut() }
        let address = try address(from: key)
        return try await unshare(
            registryID: registryID, workspaceID: workspaceID, moderating: moderating, address: address, key: key)
    }

    /// Takes every listing of this Mac's out of `workspaceID`, with one key
    /// read: the author left it, so its members stop seeing them. Best
    /// effort; returns the template ids whose removal failed.
    @discardableResult
    public func unshareAll(fromWorkspace workspaceID: String) async -> [UUID] {
        let target = workspaceID.lowercased()
        let shared = records.records(registry: api.baseURL).filter {
            $0.visibility == .workspace && $0.workspaceIDs.contains { $0.lowercased() == target }
        }
        guard !shared.isEmpty, identityExists() else { return [] }
        var key: Data
        do { key = try readKey() } catch { return shared.map(\.templateID) }
        defer { key.zeroOut() }
        guard let address = try? address(from: key) else { return shared.map(\.templateID) }
        var failed: [UUID] = []
        for record in shared {
            do {
                _ = try await unshare(
                    registryID: record.registryID, workspaceID: target, moderating: false, address: address, key: key)
            } catch {
                print("[WorkflowsRegistry] \(record.registryID) stays in workspace \(target): \(error)")
                failed.append(record.templateID)
            }
        }
        return failed
    }

    /// Takes everything `wallet` shared out of `workspaceID`, as one of its
    /// owners or admins: that member was just removed. Best effort; returns
    /// how many listings came out.
    @discardableResult
    public func unshareAuthor(_ wallet: String, fromWorkspace workspaceID: String) async -> Int {
        let author = wallet.lowercased()
        guard identityExists(),
            let items = try? await workspaceWorkflows(workspaceID: workspaceID)
                .filter({ $0.author.address.lowercased() == author }),
            !items.isEmpty
        else { return 0 }
        var key: Data
        do { key = try readKey() } catch { return 0 }
        defer { key.zeroOut() }
        guard let address = try? address(from: key) else { return 0 }
        var removed = 0
        for item in items {
            do {
                _ = try await unshare(
                    registryID: item.id, workspaceID: workspaceID, moderating: true, address: address, key: key)
                removed += 1
            } catch {
                print("[WorkflowsRegistry] \(item.id) stays in workspace \(workspaceID): \(error)")
            }
        }
        return removed
    }

    private func unshare(
        registryID: String, workspaceID: String, moderating: Bool, address: String, key: Data
    ) async throws -> [String] {
        let target = workspaceID.lowercased()
        var token: String?
        if moderating {
            do {
                token = try await workspaceAttestation(target)
            } catch {
                throw WorkflowShareError.workspaceAttestation(error.localizedDescription)
            }
        }
        do {
            let remaining = try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.unshareMessage(
                    address: address, registryID: registryID, workspaceID: target, nonce: nonce,
                    timestamp: timestamp)
                return try await self.api.unshareFromWorkspace(
                    workspaceID: target, id: registryID,
                    signed: WorkflowsRegistrySignature(
                        address: address, nonce: nonce, timestamp: timestamp,
                        signature: try Self.signature(message, key: key)),
                    attestation: token)
            }
            if let record = records.records(registry: api.baseURL).first(where: { $0.registryID == registryID }) {
                records.update(templateID: record.templateID, registry: api.baseURL) {
                    $0.workspaceIDs = remaining
                    $0.updatedAt = self.now()
                }
            }
            return remaining
        } catch let error as WorkflowsRegistryAPIError {
            throw WorkflowShareError(error)
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
    }

    // MARK: - Listing

    /// Changes the published listing's name and description, topics, and
    /// example runs, in that order, with one key read. A part that fails is
    /// reported in the result and doesn't stop the others. Throws only when
    /// nothing could be tried (not published, no key).
    public func applyListingEdits(templateID: UUID, _ edits: ListingEdits) async throws -> ListingEditsResult {
        guard let record = records.record(for: templateID, registry: api.baseURL) else {
            throw WorkflowShareError.notShared
        }
        guard !edits.isEmpty else { return ListingEditsResult() }
        var key = try readKey()
        defer { key.zeroOut() }
        let address = try address(from: key)
        return await applyListingEdits(edits, on: record, address: address, key: key)
    }

    private func applyListingEdits(
        _ edits: ListingEdits, on record: WorkflowRegistryRecord, address: String, key: Data
    ) async -> ListingEditsResult {
        var result = ListingEditsResult()
        if let details = edits.details {
            do {
                try await setListing(details, on: record, address: address, key: key)
            } catch {
                result.detailsError = Self.message(error)
            }
        }
        if let topics = edits.topics {
            do {
                try await setTags(topics, on: record, address: address, key: key)
            } catch {
                result.topicsError = Self.message(error)
            }
        }
        if let examples = edits.examples {
            do {
                try await setExamples(examples, on: record, address: address, key: key, result: &result)
            } catch {
                result.examplesError = Self.message(error)
            }
        }
        return result
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? WorkflowsRegistryAPIError { return WorkflowShareError(error).localizedDescription }
        return error.localizedDescription
    }

    private func setListing(
        _ details: ListingEdits.Details, on record: WorkflowRegistryRecord, address: String, key: Data
    ) async throws {
        let body = try WorkflowsRegistryAPIClient.listingBody(details)
        let bodyHash = Self.sha256Hex(body)
        let answer = try await withFreshNonce(address: address) { nonce, timestamp in
            let message = Self.listingMessage(
                address: address, registryID: record.registryID, bodyHash: bodyHash, nonce: nonce,
                timestamp: timestamp)
            return try await self.api.setListing(
                id: record.registryID, body: body,
                signed: WorkflowsRegistrySignature(
                    address: address, nonce: nonce, timestamp: timestamp,
                    signature: try Self.signature(message, key: key)))
        }
        records.update(templateID: record.templateID, registry: api.baseURL) {
            $0.listingName = answer.edited ? answer.name : nil
            $0.listingSummary = answer.edited ? answer.summary : nil
            $0.updatedAt = now()
        }
    }

    private func setTags(_ topics: [ListingTopic], on record: WorkflowRegistryRecord, address: String, key: Data)
        async throws
    {
        let body = try WorkflowsRegistryAPIClient.tagsBody(ListingTopic.normalized(topics.map(\.rawValue)))
        let bodyHash = Self.sha256Hex(body)
        let tags = try await withFreshNonce(address: address) { nonce, timestamp in
            let message = Self.tagsMessage(
                address: address, registryID: record.registryID, bodyHash: bodyHash, nonce: nonce,
                timestamp: timestamp)
            return try await self.api.setTags(
                id: record.registryID, body: body,
                signed: WorkflowsRegistrySignature(
                    address: address, nonce: nonce, timestamp: timestamp,
                    signature: try Self.signature(message, key: key)))
        }
        records.update(templateID: record.templateID, registry: api.baseURL) {
            $0.tags = tags
            $0.updatedAt = now()
        }
    }

    /// Uploads each new image (re-encoded without metadata), then replaces
    /// the examples. An image that can't be read or made small enough is
    /// left out and named in `result`; when the registry can't store images
    /// at all, the examples are saved without the new ones.
    private func setExamples(
        _ drafts: [ListingExampleDraft], on record: WorkflowRegistryRecord, address: String, key: Data,
        result: inout ListingEditsResult
    ) async throws {
        var uploadedBySHA: [String: ListingExample.Image] = [:]
        var mediaAvailable = true
        var uploads: [WorkflowsRegistryAPIClient.ExampleUpload] = []
        for (index, draft) in drafts.prefix(ListingEdits.maxExamples).enumerated() {
            var images: [ListingExample.Image] = []
            for image in draft.includedImages.prefix(ListingEdits.maxImagesPerExample) {
                if let uploaded = image.uploaded {
                    images.append(uploaded)
                    continue
                }
                guard mediaAvailable, let url = image.fileURL else {
                    if image.fileURL != nil { result.imagesSkipped = true }
                    continue
                }
                let encoded: ListingImageEncoder.Encoded
                do {
                    encoded = try await Task.detached(priority: .userInitiated) {
                        try ListingImageEncoder.encode(contentsOf: url)
                    }.value
                } catch {
                    result.unreadableImages.append(image.filename)
                    continue
                }
                let sha = Self.sha256Hex(encoded.data)
                if let done = uploadedBySHA[sha] {
                    images.append(done)
                    continue
                }
                do {
                    let uploaded = try await uploadImage(
                        encoded, sha256: sha, on: record, address: address, key: key)
                    uploadedBySHA[sha] = uploaded
                    images.append(uploaded)
                } catch WorkflowsRegistryAPIError.mediaUnavailable {
                    mediaAvailable = false
                    result.imagesSkipped = true
                } catch WorkflowsRegistryAPIError.unsupportedMedia, WorkflowsRegistryAPIError.bodyTooLarge {
                    result.unreadableImages.append(image.filename)
                }
            }
            uploads.append(ListingExampleBuilder.upload(draft, images: images, index: index))
        }

        let body = try WorkflowsRegistryAPIClient.examplesBody(uploads)
        let bodyHash = Self.sha256Hex(body)
        let saved = try await withFreshNonce(address: address) { nonce, timestamp in
            let message = Self.examplesMessage(
                address: address, registryID: record.registryID, bodyHash: bodyHash, nonce: nonce,
                timestamp: timestamp)
            return try await self.api.setExamples(
                id: record.registryID, body: body,
                signed: WorkflowsRegistrySignature(
                    address: address, nonce: nonce, timestamp: timestamp,
                    signature: try Self.signature(message, key: key)))
        }
        records.update(templateID: record.templateID, registry: api.baseURL) {
            $0.exampleCount = saved.count
            $0.updatedAt = now()
        }
        result.savedExamples = saved
    }

    private func uploadImage(
        _ encoded: ListingImageEncoder.Encoded, sha256: String, on record: WorkflowRegistryRecord, address: String,
        key: Data
    ) async throws -> ListingExample.Image {
        var image = try await withFreshNonce(address: address) { nonce, timestamp in
            let message = Self.exampleImageMessage(
                address: address, registryID: record.registryID, imageHash: sha256, nonce: nonce,
                timestamp: timestamp)
            return try await self.api.uploadExampleImage(
                id: record.registryID, data: encoded.data, mime: encoded.mime,
                signed: WorkflowsRegistrySignature(
                    address: address, nonce: nonce, timestamp: timestamp,
                    signature: try Self.signature(message, key: key)))
        }
        image.width = image.width ?? encoded.width
        image.height = image.height ?? encoded.height
        image.size = image.size ?? encoded.data.count
        return image
    }

    // MARK: - Take down

    /// Takes the workflow's page down for everyone. People who installed it
    /// keep their copy; publishing it again restores the same link. The
    /// record stays, marked taken down, so the library can still show it
    /// and offer Publish Again.
    public func unpublish(templateID: UUID) async throws {
        guard let record = records.record(for: templateID, registry: api.baseURL) else {
            throw WorkflowShareError.notShared
        }
        var key = try readKey()
        defer { key.zeroOut() }
        do {
            let address = try deriveOsaurusId(from: key).lowercased()
            try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.deleteMessage(
                    address: address, registryID: record.registryID, nonce: nonce, timestamp: timestamp)
                let signature = try Self.signature(message, key: key)
                try await self.api.unpublish(
                    id: record.registryID, address: address, nonce: nonce, timestamp: timestamp,
                    signature: signature)
            }
        } catch WorkflowsRegistryAPIError.removed, WorkflowsRegistryAPIError.notFound {
            // Already gone.
        } catch let error as WorkflowsRegistryAPIError {
            throw WorkflowShareError(error)
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
        records.update(templateID: templateID, registry: api.baseURL) {
            $0.takenDown = true
            $0.updatedAt = now()
        }
    }

    /// Forgets a record without touching the registry, for a workflow the
    /// registry no longer knows.
    public func forget(templateID: UUID) {
        records.remove(templateID: templateID, registry: api.baseURL)
    }

    // MARK: - Reads

    /// How long the numbers a background refresh fetched stay fresh.
    public static let statsFreshness: TimeInterval = 5 * 60

    /// Refreshes what the library shows for one published workflow without
    /// signing anything: the public read, which works for Public and
    /// Unlisted workflows. Password-protected and taken-down ones are left
    /// to `refreshOwned`. Never throws; a miss keeps the last numbers.
    /// Returns false when nothing was fetched (fresh, skipped, or failed).
    @discardableResult
    public func refreshStats(templateID: UUID, force: Bool = false) async -> Bool {
        guard let record = records.record(for: templateID, registry: api.baseURL), record.isLive,
            record.visibility != .password
        else { return false }
        if !force, let fetched = record.statsFetchedAt, now().timeIntervalSince(fetched) < Self.statsFreshness {
            return false
        }
        do {
            let detail = try await api.fetchDetail(id: record.registryID)
            records.update(templateID: templateID, registry: api.baseURL) { $0.apply(detail, at: now()) }
            return true
        } catch WorkflowsRegistryAPIError.removed {
            // Taken down from another Mac, or by the Osaurus team; the
            // signed read says which. Until then, no longer live.
            records.update(templateID: templateID, registry: api.baseURL) {
                $0.takenDown = true
                $0.statsFetchedAt = now()
            }
            return true
        } catch WorkflowsRegistryAPIError.passwordRequired {
            records.update(templateID: templateID, registry: api.baseURL) {
                $0.visibility = .password
                $0.statsFetchedAt = now()
            }
            return true
        } catch {
            print("[WorkflowsRegistry] stats \(record.registryID) not refreshed: \(error)")
            return false
        }
    }

    /// Refreshes every live record the background read can reach.
    public func refreshAllStats(force: Bool = false) async {
        for record in records.records(registry: api.baseURL) where record.isLive && record.visibility != .password {
            await refreshStats(templateID: record.templateID, force: force)
        }
    }

    /// The owner's view of one published workflow: reads it signed (so
    /// taken-down and password-protected ones answer too), then lists
    /// everything this Osaurus ID owns and reconciles the local records:
    /// a workflow published from another Mac whose template is in this
    /// library gets a record; existing records take the registry's
    /// visibility, newest version, installs, and status; records for
    /// templates no longer in the library are kept so Take Down still
    /// works. One key read; may prompt for authentication.
    public func refreshOwned(templateID: UUID) async throws -> WorkflowOwnedRefresh {
        guard let record = records.record(for: templateID, registry: api.baseURL) else {
            throw WorkflowShareError.notShared
        }
        var key = try readKey()
        defer { key.zeroOut() }
        do {
            let address = try deriveOsaurusId(from: key).lowercased()
            let detail = try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.readMessage(
                    address: address, registryID: record.registryID, nonce: nonce, timestamp: timestamp)
                return try await self.api.fetchDetail(
                    id: record.registryID,
                    signed: WorkflowsRegistrySignature(
                        address: address, nonce: nonce, timestamp: timestamp,
                        signature: try Self.signature(message, key: key)))
            }
            records.update(templateID: templateID, registry: api.baseURL) { $0.apply(detail, at: now()) }

            var handle = detail.author.handle
            var banned = false
            do {
                let owned = try await fetchAllOwned(address: address, key: key)
                handle = owned.author.handle
                banned = owned.banned
                reconcile(owned.items, address: address)
            } catch {
                // The one workflow is fresh; the list is a bonus.
                print("[WorkflowsRegistry] owned list not refreshed: \(error)")
            }
            await ensureWatchToken(address: address, key: key)
            let fresh = records.record(for: templateID, registry: api.baseURL) ?? record
            return WorkflowOwnedRefresh(detail: detail, record: fresh, authorHandle: handle, banned: banned)
        } catch let error as WorkflowsRegistryAPIError {
            throw WorkflowShareError(error)
        } catch let error as OsaurusIdentityError {
            throw WorkflowShareError.identity(error)
        }
    }

    private struct Owned {
        var author: WorkflowsRegistryAuthor
        var banned: Bool
        var items: [WorkflowsRegistryDetail]
    }

    private func fetchAllOwned(address: String, key: Data) async throws -> Owned {
        var offset = 0
        var result: Owned?
        repeat {
            let page = try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.listMessage(address: address, nonce: nonce, timestamp: timestamp)
                return try await self.api.fetchOwned(
                    signed: WorkflowsRegistrySignature(
                        address: address, nonce: nonce, timestamp: timestamp,
                        signature: try Self.signature(message, key: key)),
                    offset: offset)
            }
            if result == nil {
                result = Owned(author: page.author, banned: page.banned, items: page.items)
            } else {
                result?.items.append(contentsOf: page.items)
            }
            guard let next = page.nextOffset, next > offset, page.items.isEmpty == false else { break }
            offset = next
        } while true
        return result ?? Owned(author: WorkflowsRegistryAuthor(address: address, osaurusID: nil, displayName: nil),
            banned: false, items: [])
    }

    /// Brings the local records in line with what the registry says this
    /// Osaurus ID owns.
    func reconcile(_ owned: [WorkflowsRegistryDetail], address: String) {
        let known = knownTemplateIDs()
        let registryKey = WorkflowRegistryRecordStore.registryKey(api.baseURL)
        for item in owned {
            if records.record(for: item.templateID, registry: api.baseURL) != nil {
                records.update(templateID: item.templateID, registry: api.baseURL) { $0.apply(item, at: now()) }
            } else if known.contains(item.templateID), let raw = item.rawURL, let deepLink = item.deepLink {
                var record = WorkflowRegistryRecord(
                    templateID: item.templateID, registryID: item.id, slug: item.slug, version: item.latestVersion,
                    contentHash: "", url: item.url, rawURL: raw, deepLink: deepLink, address: address,
                    registry: registryKey, sharedAt: item.createdAt, visibility: item.visibility, kind: item.kind)
                record.apply(item, at: now())
                records.set(record)
            }
        }
    }

    // MARK: - Install receipt

    /// Tells the registry this Osaurus ID installed the workflow a link
    /// named, after the user confirmed the import or an update. Returns the
    /// registry's `counted`, or nil when nothing was counted: no Osaurus ID,
    /// a link from another registry, or any failure. Never throws and never
    /// retries; a missed receipt must not touch the import.
    @discardableResult
    public func recordInstall(_ source: RegistryImportSource) async -> Bool? {
        await recordInstalls([source])[0]
    }

    /// The agent's receipt, then one for each bundled workflow the import
    /// added to the library whose page the agent's page links to: whoever
    /// published that page gets the install. Keyed by registry id; the same
    /// best effort as `recordInstall`, with one key read for all of them.
    @discardableResult
    public func recordAgentInstall(_ source: RegistryImportSource, bundled: [Template]) async -> [UUID: Bool?] {
        var sources = [source]
        if !bundled.isEmpty, identityExists(), isThisRegistry(source.origin) {
            do {
                let detail = try await api.fetchDetail(id: source.workflowID.uuidString.lowercased())
                sources += Self.bundledInstallSources(bundled, linkedFrom: detail, origin: source.origin)
            } catch {
                print("[WorkflowsRegistry] agent \(source.workflowID.uuidString.lowercased()) links not read: \(error)")
            }
        }
        let counted = await recordInstalls(sources)
        return Dictionary(zip(sources.map(\.workflowID), counted), uniquingKeysWith: { first, _ in first })
    }

    /// Receipts for the bundled copies an agent's page links to their own
    /// pages, at the bundled version (the latest when the page has none newer).
    static func bundledInstallSources(
        _ bundled: [Template], linkedFrom detail: WorkflowsRegistryDetail, origin: URL
    ) -> [RegistryImportSource] {
        var seen: Set<UUID> = []
        return bundled.compactMap { template in
            guard let listing = detail.workflows.first(where: { $0.templateID == template.id })?.listing,
                let id = UUID(uuidString: listing.id), id.uuidString.lowercased() != detail.id.lowercased(),
                seen.insert(id).inserted
            else { return nil }
            return RegistryImportSource(
                workflowID: id, version: min(template.version, listing.latestVersion), origin: origin)
        }
    }

    private func isThisRegistry(_ origin: URL) -> Bool {
        WorkflowRegistryRecordStore.registryKey(origin) == WorkflowRegistryRecordStore.registryKey(api.baseURL)
    }

    /// Sends receipts one after another with a single key read. Nil for
    /// each one that wasn't counted (see `recordInstall`).
    private func recordInstalls(_ sources: [RegistryImportSource]) async -> [Bool?] {
        var results = [Bool?](repeating: nil, count: sources.count)
        guard identityExists(), sources.contains(where: { isThisRegistry($0.origin) }) else { return results }
        var key: Data
        do {
            key = try await readReceiptKey()
        } catch {
            print("[WorkflowsRegistry] install receipts not recorded: \(error)")
            return results
        }
        defer { key.zeroOut() }
        for (index, source) in sources.enumerated() where isThisRegistry(source.origin) {
            do {
                let address = try deriveOsaurusId(from: key).lowercased()
                let id = source.workflowID.uuidString.lowercased()
                let nonce = try await api.requestNonce(address: address)
                let timestamp = Int(now().timeIntervalSince1970)
                let message = Self.installMessage(
                    address: address, registryID: id, version: source.version, nonce: nonce, timestamp: timestamp)
                results[index] = try await api.recordInstall(
                    id: source.workflowID, version: source.version, address: address, nonce: nonce,
                    timestamp: timestamp, signature: try Self.signature(message, key: key))
            } catch {
                print("[WorkflowsRegistry] install receipt \(source.workflowID.uuidString.lowercased()) v\(source.version) not recorded: \(error)")
            }
        }
        return results
    }

    // MARK: - Review watch

    /// While the key is already read for a signed call, gets a review
    /// watch token when a review is waiting and none is stored, so
    /// `RegistryReviewWatcher` hears the decision without another prompt.
    /// Never throws; without a token the dashboard still refreshes.
    private func ensureWatchToken(address: String, key: Data) async {
        guard let watchTokens, watchTokens.token(for: api.baseURL) == nil,
            !records.pendingReviewRecords(registry: api.baseURL).isEmpty
        else { return }
        do {
            let token = try await withFreshNonce(address: address) { nonce, timestamp in
                let message = Self.reviewWatchMessage(address: address, nonce: nonce, timestamp: timestamp)
                return try await self.api.issueReviewWatchToken(
                    signed: WorkflowsRegistrySignature(
                        address: address, nonce: nonce, timestamp: timestamp,
                        signature: try Self.signature(message, key: key)))
            }
            watchTokens.set(token, for: api.baseURL)
        } catch {
            print("[WorkflowsRegistry] review watch token not issued: \(error)")
        }
    }

    // MARK: - Helpers

    /// Runs one signed request with a fresh nonce. Nonces are spent even
    /// when a request fails, so a race or an expired nonce starts over
    /// from the challenge once.
    private func withFreshNonce<T>(
        address: String, _ request: (_ nonce: String, _ timestamp: Int) async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            let nonce = try await api.requestNonce(address: address)
            let timestamp = Int(now().timeIntervalSince1970)
            do {
                return try await request(nonce, timestamp)
            } catch let error as WorkflowsRegistryAPIError
                where attempt < 2 && (error == .concurrentPublish || error == .invalidNonce)
            {
                continue
            }
        }
    }

    nonisolated static func publishMessage(address: String, bodyHash: String, nonce: String, timestamp: Int)
        -> String
    {
        "osaurus-workflow:\(address):\(bodyHash):\(nonce):\(timestamp)"
    }

    nonisolated static func deleteMessage(address: String, registryID: String, nonce: String, timestamp: Int)
        -> String
    {
        "osaurus-workflow-delete:\(address):\(registryID):\(nonce):\(timestamp)"
    }

    nonisolated static func installMessage(
        address: String, registryID: String, version: Int, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-install:\(address):\(registryID):\(version):\(nonce):\(timestamp)"
    }

    nonisolated static func unshareMessage(
        address: String, registryID: String, workspaceID: String, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-unshare:\(address):\(registryID):\(workspaceID):\(nonce):\(timestamp)"
    }

    /// The body hash binds the password to the signature.
    nonisolated static func visibilityMessage(
        address: String, registryID: String, bodyHash: String, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-visibility:\(address):\(registryID):\(bodyHash):\(nonce):\(timestamp)"
    }

    nonisolated static func listingMessage(
        address: String, registryID: String, bodyHash: String, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-listing:\(address):\(registryID):\(bodyHash):\(nonce):\(timestamp)"
    }

    nonisolated static func tagsMessage(
        address: String, registryID: String, bodyHash: String, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-tags:\(address):\(registryID):\(bodyHash):\(nonce):\(timestamp)"
    }

    /// Over the image bytes' SHA-256, which is also its stored name.
    nonisolated static func exampleImageMessage(
        address: String, registryID: String, imageHash: String, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-example-image:\(address):\(registryID):\(imageHash):\(nonce):\(timestamp)"
    }

    nonisolated static func examplesMessage(
        address: String, registryID: String, bodyHash: String, nonce: String, timestamp: Int
    ) -> String {
        "osaurus-workflow-examples:\(address):\(registryID):\(bodyHash):\(nonce):\(timestamp)"
    }

    nonisolated static func readMessage(address: String, registryID: String, nonce: String, timestamp: Int)
        -> String
    {
        "osaurus-workflow-read:\(address):\(registryID):\(nonce):\(timestamp)"
    }

    nonisolated static func listMessage(address: String, nonce: String, timestamp: Int) -> String {
        "osaurus-workflow-list:\(address):\(nonce):\(timestamp)"
    }

    nonisolated static func reviewWatchMessage(address: String, nonce: String, timestamp: Int) -> String {
        "osaurus-review-watch:\(address):\(nonce):\(timestamp)"
    }

    nonisolated static func signature(_ message: String, key: Data) throws -> String {
        "0x" + (try signEIP191Message(message, privateKey: key)).hexEncodedString
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
