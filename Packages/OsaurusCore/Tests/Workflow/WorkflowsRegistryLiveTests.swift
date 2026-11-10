//
//  WorkflowsRegistryLiveTests.swift
//  osaurusTests
//
//  End-to-end run against a real workflows-registry deployment. Skipped
//  unless OSAURUS_WORKFLOWS_REGISTRY_LIVE_URL names one, e.g.
//  https://osaurus-registry.fly.dev. Each run signs with a fresh random key,
//  so it never collides with an earlier run's author or quota.
//

import Foundation
import Security
import Testing

@testable import OsaurusCore

private let liveRegistryURL: URL? = ProcessInfo.processInfo.environment["OSAURUS_WORKFLOWS_REGISTRY_LIVE_URL"]
    .flatMap { $0.isEmpty ? nil : URL(string: $0) }
/// The registry's REGISTRY_ADMIN_TOKEN; the review run decides as a moderator.
private let liveAdminToken: String? = ProcessInfo.processInfo.environment["OSAURUS_WORKFLOWS_REGISTRY_ADMIN_TOKEN"]
    .flatMap { $0.isEmpty ? nil : $0 }

@Suite(.serialized, .enabled(if: liveRegistryURL != nil))
@MainActor
struct WorkflowsRegistryLiveTests {
    private static func randomKey() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        try #require(status == errSecSuccess)
        return bytes
    }

    @Test
    func shareUpdateInstallUnpublishAndReshare() async throws {
        let base = try #require(liveRegistryURL)
        let key = try Self.randomKey()
        let address = try deriveOsaurusId(from: key).lowercased()
        let api = WorkflowsRegistryAPIClient(baseURL: base)

        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("workflow-share-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            let records = WorkflowRegistryRecordStore()
            let service = WorkflowShareService(
                api: api, records: records, readKey: { key }, readReceiptKey: { key }, identityExists: { true })

            var template = WF.template(WF.intake())
            template.name = "Osaurus Live Proof \(address.suffix(6))"
            template = template.sealed()
            print("[live] registry=\(base.absoluteString) address=\(address) template=\(template.id)")

            let first = try await service.share(template, authorName: "Osaurus Live Proof")
            print("[live] first share version=\(first.published.version) created=\(first.published.created) url=\(first.published.url)")
            #expect(first.published.created)
            #expect(first.published.version == template.version)
            #expect(records.record(for: template.id, registry: base)?.registryID == first.published.id)
            #expect(TemplateImportRouter.remoteURL(from: first.published.deepLink, registry: base) == first.published.rawURL)
            #expect(TemplateImportRouter.remoteURL(from: first.published.deepLink) == nil || base == WorkflowsRegistryAPIClient.productionBaseURL)

            let again = try await service.share(template, authorName: "Osaurus Live Proof")
            print("[live] identical re-share version=\(again.published.version) created=\(again.published.created)")
            #expect(!again.published.created)
            #expect(again.published.id == first.published.id)

            var edited = template
            edited.summary = "Edited for the live proof."
            edited = edited.sealed()
            do {
                _ = try await service.share(edited, authorName: "Osaurus Live Proof")
                Issue.record("changed content at the same version should be refused")
            } catch let error as WorkflowShareError {
                guard case .versionNotNewer(let latest) = error else {
                    Issue.record("unexpected \(error)")
                    return
                }
                print("[live] edited at same version -> version_not_newer latest=\(latest)")
                #expect(latest == template.version)
            }

            edited.version = template.version + 1
            edited = edited.sealed()
            let second = try await service.share(edited, authorName: "Osaurus Live Proof")
            print("[live] next version=\(second.published.version) created=\(second.published.created) raw=\(second.published.rawURL)")
            #expect(second.published.version == template.version + 1)
            #expect(second.published.id == first.published.id)
            #expect(second.published.slug == first.published.slug)

            let fetched = try await TemplateImportRouter.fetch(second.published.rawURL).text
            let parsed = try Template.parse(fetched)
            #expect(parsed.contentHash == second.published.contentHash)
            #expect(parsed.author?.address?.lowercased() == address)
            let firstVersionText = try await TemplateImportRouter.fetch(first.published.rawURL).text
            #expect(!firstVersionText.isEmpty, "old versions stay downloadable")

            let firstSource = try #require(RegistryImportSource(templateURL: first.published.rawURL, registry: base))
            let secondSource = try #require(RegistryImportSource(templateURL: second.published.rawURL, registry: base))
            let counted = await service.recordInstall(firstSource)
            let updated = await service.recordInstall(secondSource)
            print("[live] install receipt v\(firstSource.version) counted=\(String(describing: counted)) update v\(secondSource.version) counted=\(String(describing: updated))")
            #expect(counted == true)
            #expect(updated == false, "an update lands on the same install")
            let missing = RegistryImportSource(
                workflowID: firstSource.workflowID, version: secondSource.version + 5, origin: firstSource.origin)
            #expect(await service.recordInstall(missing) == nil, "a version the registry doesn't have")

            // The owner's read sees the page and its numbers; the public one too.
            let owned = try await service.refreshOwned(templateID: template.id)
            print("[live] owner read installs=\(owned.detail.installCount) latest=\(owned.detail.latestVersion) handle=\(owned.authorHandle) banned=\(owned.banned) owned=\(records.records(registry: base).count)")
            #expect(owned.detail.id == first.published.id)
            #expect(owned.detail.latestVersion == second.published.version)
            #expect(owned.detail.installCount >= 1, "the receipt above counted")
            #expect(owned.detail.visibility == .public)
            #expect(owned.record.registryLatestVersion == second.published.version)
            #expect(await service.refreshStats(templateID: template.id, force: true) == true)

            try await service.unpublish(templateID: template.id)
            #expect(records.record(for: template.id, registry: base)?.takenDown == true)
            do {
                _ = try await TemplateImportRouter.fetch(second.published.rawURL).text
                Issue.record("an unpublished workflow should not download")
            } catch let error as TemplateImportRouter.FetchError {
                print("[live] fetch after unpublish -> \(error)")
                #expect(error == .status(410))
            }

            let restored = try await service.share(edited, authorName: "Osaurus Live Proof")
            print("[live] re-share after unpublish version=\(restored.published.version) slug=\(restored.published.slug)")
            #expect(restored.published.id == first.published.id)
            #expect(restored.published.slug == first.published.slug)
            let restoredText = try await TemplateImportRouter.fetch(restored.published.rawURL).text
            #expect(restoredText == fetched)
            #expect(records.record(for: template.id, registry: base)?.isLive == true)

            try await service.unpublish(templateID: template.id)
        }
    }

    /// Who can see it: publish Unlisted, go Password, then Public; the
    /// public read answers 403 only while a password is set, the owner's
    /// signed read always answers, and `/me/workflows` lists it throughout.
    @Test
    func visibilityUnlistedPasswordPublic() async throws {
        let base = try #require(liveRegistryURL)
        let key = try Self.randomKey()
        let address = try deriveOsaurusId(from: key).lowercased()
        let api = WorkflowsRegistryAPIClient(baseURL: base)

        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("workflow-visibility-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            let records = WorkflowRegistryRecordStore()
            let service = WorkflowShareService(
                api: api, records: records, readKey: { key }, readReceiptKey: { key }, identityExists: { true })

            var template = WF.template(WF.intake())
            template.name = "Osaurus Visibility Proof \(address.suffix(6))"
            template = template.sealed()
            print("[live] registry=\(base.absoluteString) address=\(address) template=\(template.id)")

            let unlisted = try await service.share(template, authorName: "Osaurus Live Proof", visibility: .hidden)
            print("[live] published unlisted id=\(unlisted.published.id) visibility=\(unlisted.published.visibility) url=\(unlisted.published.url)")
            #expect(unlisted.published.visibility == .hidden)
            #expect(unlisted.visibilityError == nil)
            let publicRead = try await api.fetchDetail(id: unlisted.published.id)
            #expect(publicRead.visibility == .hidden, "unlisted still answers by id")

            let locked = try await service.setVisibility(templateID: template.id, visibility: .password, password: "proof-2026")
            print("[live] -> password visibility=\(locked.visibility)")
            #expect(locked.visibility == .password)
            do {
                _ = try await api.fetchDetail(id: unlisted.published.id)
                Issue.record("a password-protected page should refuse the public read")
            } catch let error as WorkflowsRegistryAPIError {
                print("[live] public read while password -> \(error)")
                #expect(error == .passwordRequired)
            }
            #expect(await service.refreshStats(templateID: template.id, force: true) == false, "left to the owner read")
            let owned = try await service.refreshOwned(templateID: template.id)
            print("[live] owner read visibility=\(owned.detail.visibility) handle=\(owned.authorHandle)")
            #expect(owned.detail.visibility == .password)
            #expect(owned.record.visibility == .password && owned.record.isLive)

            do {
                _ = try await service.setVisibility(templateID: template.id, visibility: .password, password: "short")
                Issue.record("a short password must be refused")
            } catch let error as WorkflowShareError {
                #expect(error == .invalidPassword)
            }

            let opened = try await service.setVisibility(templateID: template.id, visibility: .public)
            print("[live] -> public visibility=\(opened.visibility)")
            #expect(opened.visibility == .public)
            #expect(try await api.fetchDetail(id: unlisted.published.id).visibility == .public)

            try await service.unpublish(templateID: template.id)
            let afterTakeDown = try await service.refreshOwned(templateID: template.id)
            print("[live] after take down status=\(afterTakeDown.detail.status) removal=\(String(describing: afterTakeDown.detail.removal?.by))")
            #expect(afterTakeDown.detail.isRemoved && !afterTakeDown.detail.removedByAdmin)
            #expect(afterTakeDown.record.takenDown && !afterTakeDown.record.isLive)
        }
    }

    /// An agent template with a bundled workflow publishes to `/a/`, lists
    /// under `kind=agent` only, downloads intact, counts an install, and
    /// comes back from the owner's reconcile as an agent record.
    @Test
    func agentTemplatePublishInstallAndTakeDown() async throws {
        let base = try #require(liveRegistryURL)
        let key = try Self.randomKey()
        let address = try deriveOsaurusId(from: key).lowercased()
        let api = WorkflowsRegistryAPIClient(baseURL: base)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("RegistryFixtures/agent-template-inbox-desk.json")

        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-share-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            // Listings are keyed by (owner, template id); the fresh key
            // keeps the fixture's id from colliding with earlier runs.
            var template = try Template.parse(String(decoding: try Data(contentsOf: fixture), as: UTF8.self))
            template.name = "Osaurus Agent Proof \(address.suffix(6))"
            template = template.sealed()
            #expect(template.kind == .agent && template.bundled.count == 1)

            let records = WorkflowRegistryRecordStore()
            let service = WorkflowShareService(
                api: api, records: records, readKey: { key }, readReceiptKey: { key }, identityExists: { true },
                knownTemplateIDs: { [template.id] })
            print("[live] registry=\(base.absoluteString) address=\(address) agent template=\(template.id)")

            let shared = try await service.share(template, authorName: "Osaurus Live Proof")
            print("[live] agent share version=\(shared.published.version) kind=\(shared.published.kind) url=\(shared.published.url)")
            #expect(shared.published.created && shared.published.kind == .agent)
            #expect(shared.published.url.path.hasPrefix("/a/"))
            let record = try #require(records.record(for: template.id, registry: base))
            #expect(record.kind == .agent)
            #expect(records.liveRecords(registry: base, kind: .workflow).isEmpty)

            let fetched = try Template.parse(try await TemplateImportRouter.fetch(shared.published.rawURL).text)
            #expect(fetched.kind == .agent && fetched.contentHash == shared.published.contentHash)
            #expect(fetched.bundled.map(\.id) == template.bundled.map(\.id), "the bundled workflow travels")
            #expect(fetched.author?.address?.lowercased() == address)

            let detail = try await api.fetchDetail(id: shared.published.id)
            #expect(detail.kind == .agent)

            let source = try #require(RegistryImportSource(templateURL: shared.published.rawURL, registry: base))
            let counted = await service.recordInstall(source)
            print("[live] agent install receipt counted=\(String(describing: counted))")
            #expect(counted == true)

            // A workflow from the same ID; its owner read lists both kinds
            // and rebuilds the agent's record after it is forgotten.
            var workflow = WF.template(WF.intake())
            workflow.name = "Osaurus Agent Proof Workflow \(address.suffix(6))"
            workflow = workflow.sealed()
            let sharedWorkflow = try await service.share(workflow, authorName: "Osaurus Live Proof")
            #expect(sharedWorkflow.published.kind == .workflow && sharedWorkflow.published.url.path.hasPrefix("/w/"))
            service.forget(templateID: template.id)
            #expect(records.record(for: template.id, registry: base) == nil)
            _ = try await service.refreshOwned(templateID: workflow.id)
            let rebuilt = try #require(records.record(for: template.id, registry: base), "reconcile rebuilds it")
            print("[live] reconciled agent record kind=\(rebuilt.kind) installs=\(String(describing: rebuilt.installCount))")
            #expect(rebuilt.kind == .agent && rebuilt.registryID == shared.published.id)
            #expect(records.record(for: workflow.id, registry: base)?.kind == .workflow)
            #expect(records.liveRecords(registry: base, kind: .agent).count == 1)
            #expect(records.liveRecords(registry: base, kind: .workflow).count == 1)

            try await service.unpublish(templateID: template.id)
            try await service.unpublish(templateID: workflow.id)
            #expect(records.record(for: template.id, registry: base)?.takenDown == true)
        }
    }

    private static func decide(
        _ base: URL, token: String, id: String, version: Int, _ decision: String, message: String? = nil
    ) async throws {
        var request = URLRequest(
            url: base.appendingPathComponent("admin/workflows/\(id)/versions/\(version)/\(decision)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("live-proof@osaurus.ai", forHTTPHeaderField: "X-Admin-Actor")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: message.map { ["message": $0] } ?? [:])
        let (_, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200, "admin \(decision) v\(version)")
    }

    /// A Public submission against a registry with review on: it is
    /// unlisted until approved, the share call leaves a watch token behind,
    /// and the watcher hears a moderator's change request and approval in
    /// about a second each, without another signature.
    @Test(.enabled(if: liveAdminToken != nil))
    func reviewIsWatchedLive() async throws {
        let base = try #require(liveRegistryURL)
        let adminToken = try #require(liveAdminToken)
        let key = try Self.randomKey()
        let address = try deriveOsaurusId(from: key).lowercased()
        let api = WorkflowsRegistryAPIClient(baseURL: base)

        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("workflow-review-live-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            let records = WorkflowRegistryRecordStore()
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            let service = WorkflowShareService(
                api: api, records: records, readKey: { key }, readReceiptKey: { key }, identityExists: { true },
                watchTokens: tokens)
            var decisions: [PublishReviewDecision] = []
            let watcher = RegistryReviewWatcher(
                api: api, records: records, tokens: tokens, onDecision: { decisions.append($0) })
            watcher.start()
            defer { watcher.stop() }

            var template = WF.template(WF.intake())
            template.name = "Osaurus Review Proof \(address.suffix(6))"
            template = template.sealed()
            let first = try await service.share(template, authorName: "Osaurus Live Proof")
            let submitted = try #require(records.record(for: template.id, registry: base))
            let state = PublishReviewState(record: submitted)
            print("[live] submitted review=\(String(describing: submitted.review?.status)) listed=\(String(describing: submitted.listed)) headline=\(state.headline)")
            try #require(first.published.review?.status == .pending, "the registry must run with PUBLIC_REVIEW on")
            #expect(submitted.listed == false && state.isUnlistedUntilApproved)
            #expect(tokens.token(for: base) != nil, "the share call fetched a watch token")
            #expect(await Self.eventually { watcher.isWatching })
            #expect(await Self.eventually { watcher.lastHeardAt != nil }, "the first read answered")

            let rejectAt = Date()
            try await Self.decide(
                base, token: adminToken, id: first.published.id, version: 1, "reject",
                message: "Name the steps after what they do.")
            #expect(await Self.eventually(seconds: 10) { decisions.count == 1 })
            print("[live] change request heard after \(Int(Date().timeIntervalSince(rejectAt) * 1000)) ms")
            let rejected = try #require(decisions.first)
            #expect(rejected.changesRequested && rejected.body == "Name the steps after what they do.")
            let afterReject = try #require(records.record(for: template.id, registry: base))
            #expect(PublishReviewState(record: afterReject).phase == .changesRequested && afterReject.hasUnseenDecision)
            #expect(await Self.eventually { !watcher.isWatching }, "nothing pending: the watcher rests")

            var fixed = template
            fixed.version = template.version + 1
            fixed.summary = "Steps renamed for review."
            fixed = fixed.sealed()
            let second = try await service.share(fixed, authorName: "Osaurus Live Proof")
            #expect(second.published.review?.status == .pending)
            #expect(await Self.eventually { watcher.isWatching }, "a resubmission wakes the watcher")
            try await Task.sleep(for: .seconds(1))

            let approveAt = Date()
            try await Self.decide(base, token: adminToken, id: first.published.id, version: fixed.version, "approve")
            #expect(await Self.eventually(seconds: 10) { decisions.count == 2 })
            print("[live] approval heard after \(Int(Date().timeIntervalSince(approveAt) * 1000)) ms")
            let approved = try #require(decisions.last)
            #expect(!approved.changesRequested && approved.listed)
            let listed = try #require(records.record(for: template.id, registry: base))
            print("[live] approved listed=\(String(describing: listed.listed)) live=\(String(describing: listed.liveVersion)) phase=\(PublishReviewState(record: listed).phase)")
            #expect(listed.isListed && listed.liveVersion == fixed.version)
            #expect(PublishReviewState(record: listed).phase == .listed)

            try await service.unpublish(templateID: template.id)
        }
    }

    private static func eventually(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
