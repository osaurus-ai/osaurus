//
//  ConfigHistoryTests.swift
//  OsaurusCoreTests
//
//  Configuration history: canonical snapshots, one row per landed change
//  credited to its caller, drift noticed outside applies, retention across
//  a relaunch, and no secret value in any row.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Store

@Suite(.serialized)
struct ConfigHistoryStoreTests {

    private static func memoryDatabase() throws -> ConfigHistoryDatabase {
        let database = ConfigHistoryDatabase()
        try database.openInMemory()
        return database
    }

    private static func yaml(_ n: Int) -> String {
        "chat:\n  spell_check: \(n % 2 == 0)\nversion: 1\nagents:\n- name: probe-\(n)\n"
    }

    @Test
    func canonicalYAMLIsSortedAndByteStable() throws {
        var document = OsaurusConfigDocument()
        var chat = ChatSection()
        chat.spellCheck = true
        chat.autoTitles = false
        document.chat = chat
        var tools = ToolsSection()
        tools.policies = ["zeta_tool": "ask", "alpha_tool": "auto", "mid_tool": "deny"]
        document.tools = tools

        let first = try ConfigYAML.canonical(document)
        for _ in 0 ..< 5 { #expect(try ConfigYAML.canonical(document) == first) }
        let alpha = try #require(first.range(of: "alpha_tool"))
        let zeta = try #require(first.range(of: "zeta_tool"))
        #expect(alpha.lowerBound < zeta.lowerBound)
        #expect(try ConfigYAML.decode(first) == document.withVersion())
    }

    @Test
    func anUnchangedDocumentWritesNoRowAndSectionsAreDiffed() throws {
        let database = try Self.memoryDatabase()
        let first = try #require(try database.append(yaml: Self.yaml(0), caller: .observed(noticedAt: .launch)))
        #expect(first.sequence == 0)
        #expect(Set(first.sectionsChanged) == [.chat, .agents])

        #expect(try database.append(yaml: Self.yaml(0), caller: .adminAPI) == nil)
        #expect(try database.count() == 1)

        let changed = "chat:\n  spell_check: false\nversion: 1\nagents:\n- name: probe-0\n"
        let second = try #require(try database.append(yaml: changed, caller: .adminAPI))
        #expect(second.sequence == 1)
        #expect(second.sectionsChanged == [.chat])
        #expect(try database.snapshot(before: 1)?.sequence == 0)
    }

    @Test
    func callersRoundTripThroughTheirColumns() throws {
        let database = try Self.memoryDatabase()
        let callers: [ConfigChangeCaller] = [
            .configurator(sessionId: "s-1"), .observed(noticedAt: .beforeApply), .observed(noticedAt: .launch),
            .observed(noticedAt: .historyOpened), .templateInstall(templateId: "sub-agent"), .fileImport,
            .pairedPhone(deviceKey: "phone-1"), .adminAPI, .other("cli"),
        ]
        let approval = UUID()
        for (index, caller) in callers.enumerated() {
            try database.append(yaml: Self.yaml(index), caller: caller, approvalId: approval, requestText: "asked")
        }
        let rows = try database.list(limit: 50).reversed()
        #expect(rows.map(\.caller) == callers)
        for row in rows {
            #expect(row.approvalId == approval)
            // The store records what it knows: an observed change has no request.
            #expect(row.requestText == (row.caller.isObserved ? nil : "asked"))
        }
    }

    @Test
    func retentionKeepsTwoHundredUnlabeledPlusLabeledPlusSequenceZeroAcrossARelaunch() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-history-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let database = ConfigHistoryDatabase()
        try database.openForTests(path: path)
        try database.append(yaml: Self.yaml(0), caller: .observed(noticedAt: .launch))
        for n in 1 ... 10 { try database.append(yaml: Self.yaml(n), caller: .adminAPI) }
        try database.setLabel("before the trip", sequence: 3)
        try database.setLabel("Known good", sequence: 7)
        #expect(throws: ConfigHistoryDatabaseError.labelTaken("known good")) {
            try database.setLabel("known good", sequence: 8)
        }
        for n in 11 ... 250 { try database.append(yaml: Self.yaml(n), caller: .adminAPI) }
        database.close()

        let relaunched = ConfigHistoryDatabase()
        try relaunched.openForTests(path: path)
        defer { relaunched.close() }
        #expect(try relaunched.count() == ConfigHistoryDatabase.retainedUnlabeled + 2 + 1)
        #expect(try relaunched.snapshot(sequence: 0) != nil)
        #expect(try relaunched.snapshot(label: "KNOWN GOOD")?.sequence == 7)
        #expect(try relaunched.snapshot(label: "before the trip")?.sequence == 3)
        #expect(try relaunched.latest()?.sequence == 250)
        let unlabeled = try relaunched.list(limit: 500).filter { $0.label == nil && $0.sequence != 0 }
        #expect(unlabeled.count == ConfigHistoryDatabase.retainedUnlabeled)
        #expect(unlabeled.last?.sequence == 51)
    }

    @Test
    func listFiltersBySectionAndTime() throws {
        let database = try Self.memoryDatabase()
        let start = Date(timeIntervalSince1970: 1_000)
        try database.append(yaml: Self.yaml(0), caller: .adminAPI, takenAt: start)
        try database.append(
            yaml: "chat:\n  spell_check: false\nversion: 1\nagents:\n- name: probe-0\n", caller: .adminAPI,
            takenAt: start.addingTimeInterval(60))
        try database.append(
            yaml: "chat:\n  spell_check: false\nversion: 1\nagents:\n- name: renamed\n", caller: .adminAPI,
            takenAt: start.addingTimeInterval(120))
        #expect(try database.list(section: .agents).map(\.sequence) == [2, 0])
        #expect(try database.list(section: .chat).map(\.sequence) == [1, 0])
        #expect(try database.list(since: start.addingTimeInterval(30)).map(\.sequence) == [2, 1])
    }
}

extension OsaurusConfigDocument {
    fileprivate func withVersion() -> OsaurusConfigDocument {
        var copy = self
        if copy.version == nil { copy.version = 1 }
        return copy
    }
}

// MARK: - Live-store serialization

/// One history test at a time against the live (test-root) document, across
/// suites, with chat spell check put back before the next one starts. It
/// also holds the storage and sandbox locks, since the document includes
/// `AgentManager.shared`'s agents. Suites outside those locks may still move
/// the document, so assertions find this test's own rows by caller rather
/// than taking the latest.
actor ConfigHistoryLiveLock {
    static let shared = ConfigHistoryLiveLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    static func withDatabase<T: Sendable>(
        _ body: @escaping @Sendable (ConfigHistoryDatabase) async throws -> T
    ) async throws -> T {
        try await SandboxTestLock.runWithStoragePaths { try await locked(body) }
    }

    private static func locked<T: Sendable>(
        _ body: @Sendable (ConfigHistoryDatabase) async throws -> T
    ) async throws -> T {
        await shared.acquire()
        let original = await MainActor.run { ConfigExporter.export().chat?.spellCheck ?? false }
        let database = ConfigHistoryDatabase()
        do {
            try database.openInMemory()
            let result = try await ConfigHistoryRecorder.$databaseOverride.withValue(database) {
                try await body(database)
            }
            await restore(spellCheck: original)
            return result
        } catch {
            await restore(spellCheck: original)
            throw error
        }
    }

    private static func restore(spellCheck: Bool) async {
        var document = OsaurusConfigDocument()
        var chat = ChatSection()
        chat.spellCheck = spellCheck
        document.chat = chat
        _ = await ConfigApplier.apply(document: document, prune: false)
        await shared.release()
    }

    /// The newest row a caller other than drift wrote.
    static func latestApply(_ database: ConfigHistoryDatabase) throws -> ConfigSnapshot? {
        try database.list(limit: 50).first { !$0.caller.isObserved }
    }
}

// MARK: - Recorder

@Suite(.serialized)
struct ConfigHistoryRecorderTests {

    private static func withDatabase<T: Sendable>(
        _ body: @escaping @Sendable (ConfigHistoryDatabase) async throws -> T
    ) async throws -> T {
        try await ConfigHistoryLiveLock.withDatabase(body)
    }

    private static func spellCheckDocument(_ value: Bool) -> OsaurusConfigDocument {
        var document = OsaurusConfigDocument()
        var chat = ChatSection()
        chat.spellCheck = value
        document.chat = chat
        return document
    }

    private static func currentSpellCheck() async -> Bool {
        await MainActor.run { ConfigExporter.export().chat?.spellCheck ?? false }
    }

    private static func toolApply(yaml: String, extra: [String: Any] = [:]) async throws -> String {
        var args: [String: Any] = ["action": "apply", "yaml": yaml]
        args.merge(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: args)
        return try await ChatExecutionContext.$currentAgentId.withValue(Agent.configuratorId) {
            try await OsaurusConfigTool().execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
    }

    @Test
    func everyProductionApplyNamesItsCaller() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected: [String: String] = [
            "Networking/HTTPHandler.swift": "caller: .adminAPI",
            "Services/Import/PendingImportProcessor.swift": "caller: .fileImport",
            "Views/Event/EventsView.swift": "caller: .fileImport",
            "Configuration/Declarative/OsaurusConfigTool.swift": "caller: caller",
        ]
        var seen: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let path = url.path
            guard path.hasSuffix(".swift"), !path.contains("/Tests/"), !path.contains("/.build/") else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            var search = source.startIndex ..< source.endIndex
            while let hit = source.range(of: "ConfigApplier.apply(", range: search) {
                let call = String(source[hit.lowerBound...].prefix(400))
                let relative = String(path.dropFirst(root.path.count + 1))
                let closing = call.firstIndex(of: ")").map { String(call[..<$0]) } ?? call
                #expect(closing.contains("caller:"), "\(relative) applies without a history caller")
                if let want = expected[relative] {
                    #expect(closing.contains(want), "\(relative) should pass \(want)")
                    seen.insert(relative)
                }
                search = hit.upperBound ..< source.endIndex
            }
        }
        #expect(seen == Set(expected.keys))
    }

    @Test
    func aConfiguratorApplyIsCreditedToItsSessionAndRequest() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let result = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                try await ChatExecutionContext.$currentSessionId.withValue("session-hist") {
                    try await ChatExecutionContext.$currentUserRequest.withValue("turn spell check the other way") {
                        try await Self.toolApply(yaml: "chat:\n  spell_check: \(!original)\n")
                    }
                }
            }
            #expect(result.contains("\"applied\""), "\(result)")
            let row = try #require(try ConfigHistoryLiveLock.latestApply(database))
            #expect(row.caller == .configurator(sessionId: "session-hist"))
            #expect(row.requestText == "turn spell check the other way")
            #expect(row.approvalId == nil, "auto-approved: no card gated it")
            #expect(row.sectionsChanged.contains(.chat))
            #expect(try row.document().chat?.spellCheck == !original)

            _ = await ConfigApplier.apply(document: Self.spellCheckDocument(original), prune: false)
        }
    }

    @Test
    func aPairedPhoneApprovalIsCreditedToThePhoneWithItsCard() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let apply = Task {
                try await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                    try await ChatExecutionContext.$syncReviewerScope.withValue("phone-conversation") {
                        try await Self.toolApply(yaml: "chat:\n  spell_check: \(!original)\n")
                    }
                }
            }
            var cardId: UUID?
            for _ in 0 ..< 200 {
                cardId = await MainActor.run { ConfigApprovalQueue.shared.pending.first { $0.fromPairedPhone }?.id }
                if cardId != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let id = try #require(cardId)
            let answered = await MainActor.run { ConfigApprovalQueue.shared.resolveFromPairedPhone(id: id, apply: true) }
            #expect(answered)
            _ = try await apply.value

            let row = try #require(try ConfigHistoryLiveLock.latestApply(database))
            #expect(row.caller == .pairedPhone(deviceKey: "phone-conversation"))
            #expect(row.approvalId == id)

            _ = await ConfigApplier.apply(document: Self.spellCheckDocument(original), prune: false)
        }
    }

    @Test
    func aTemplateInstallIsCreditedToTheTemplate() async throws {
        try await Self.withDatabase { database in
            let name = "zz-history-template-\(UUID().uuidString.prefix(8))"
            let result = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                try await Self.toolApply(yaml: "{}", extra: ["template": "Sub Agent", "overrides": ["name": name]])
            }
            defer {
                Task { @MainActor in
                    if let agent = AgentManager.shared.agents.first(where: { $0.name == name }) {
                        _ = await AgentManager.shared.delete(id: agent.id)
                    }
                }
            }
            #expect(!result.contains("\"ok\":false") && !result.contains("\"ok\": false"), "\(result)")
            let row = try #require(try database.list(limit: 5).first { !$0.caller.isObserved })
            #expect(row.caller == .templateInstall(templateId: Template.slug(for: "Sub Agent")))
            #expect(row.sectionsChanged.contains(.agents))
            #expect(row.yaml.contains(name))
        }
    }

    @Test
    func theToolMapsPhoneAndTemplateBeforeConfigurator() async throws {
        #expect(
            ChatExecutionContext.$currentSessionId.withValue("s") { OsaurusConfigTool.historyCaller(template: nil) }
                == .configurator(sessionId: "s"))
        #expect(
            ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                ChatExecutionContext.$syncReviewerScope.withValue("p") { OsaurusConfigTool.historyCaller(template: nil) }
            } == .pairedPhone(deviceKey: "p"))
    }

    @Test
    func aChangeOutsideAnyApplyIsObservedBeforeTheNextApply() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            await ConfigApplier.noticeConfigDrift(.launch)
            let baseline = try #require(try database.latest())

            // A Settings edit: the store changes and no apply records it.
            _ = await ConfigApplier.apply(document: Self.spellCheckDocument(!original), prune: false)
            #expect(try database.latest()?.sequence == baseline.sequence)

            var autoTitles = OsaurusConfigDocument()
            var chat = ChatSection()
            chat.spellCheck = !original
            chat.autoTitles = !(await MainActor.run { ConfigExporter.export().chat?.autoTitles ?? true })
            autoTitles.chat = chat
            _ = await ConfigApplier.apply(document: autoTitles, prune: false, caller: .adminAPI)

            let rows = try database.list(limit: 10).filter { $0.sequence > baseline.sequence }.reversed()
            let observed = try #require(rows.first)
            #expect(observed.caller == .observed(noticedAt: .beforeApply))
            #expect(observed.requestText == nil)
            #expect(try observed.document().chat?.spellCheck == !original)
            #expect(rows.last?.caller == .adminAPI)

            _ = await ConfigApplier.apply(document: Self.spellCheckDocument(original), prune: false)
        }
    }

    @Test
    func driftChecksWriteOnlyWhenTheDocumentMoved() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let first = try #require(await ConfigApplier.noticeConfigDrift(.launch))
            #expect(first.sequence == 0, "first history run takes the document as found")
            #expect(await ConfigApplier.noticeConfigDrift(.historyOpened) == nil)

            _ = await ConfigApplier.apply(document: Self.spellCheckDocument(!original), prune: false)
            let noticed = try #require(await ConfigApplier.noticeConfigDrift(.historyOpened))
            #expect(noticed.caller == .observed(noticedAt: .historyOpened))
            #expect(noticed.sectionsChanged.contains(.chat))
            #expect(try database.count() >= 2)

            _ = await ConfigApplier.apply(document: Self.spellCheckDocument(original), prune: false)
        }
    }

    @Test
    func anUnchangedOrFailedApplyWritesNoRow() async throws {
        try await Self.withDatabase { database in
            let current = await Self.currentSpellCheck()
            await ConfigApplier.noticeConfigDrift(.launch)
            _ = await ConfigApplier.apply(
                document: Self.spellCheckDocument(current), prune: false, caller: .other("unchanged"))
            let rows = try database.list(limit: 10)
            #expect(rows.allSatisfy { $0.caller != .other("unchanged") })

            #expect(!ConfigHistoryRecorder.landed([.init(section: "agents", target: "x", status: .failed)]))
            #expect(!ConfigHistoryRecorder.landed([.init(section: "mcp_servers", target: "x", status: .needsUserAction)]))
            #expect(ConfigHistoryRecorder.landed([.init(section: "models", target: "x", status: .started)]))
            let none = await ConfigHistoryRecorder.recordApply(
                [.init(section: "agents", target: "x", status: .failed)], caller: .adminAPI, approvalId: nil,
                requestText: nil)
            #expect(none == nil)
        }
    }

    @Test
    func aDeniedCardWritesNoRow() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            await ConfigApplier.noticeConfigDrift(.launch)
            let before = try database.count()
            let result = try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                try await Self.toolApply(yaml: "chat:\n  spell_check: \(!original)\n")
            }
            #expect(result.contains("Nothing was applied"), "\(result)")
            #expect(try database.count() == before)
        }
    }

    @Test
    func noRowHoldsASecretValue() async throws {
        try await Self.withDatabase { database in
            let bearer = "sk-hist-bearer-\(UUID().uuidString)"
            let header = "hdr-hist-secret-\(UUID().uuidString)"
            let apiKey = "sk-hist-provider-\(UUID().uuidString)"
            let mcp = MCPProvider(
                name: "zz-history-secret-\(UUID().uuidString.prefix(6))", url: "https://mcp.example.invalid/sse",
                enabled: false, customHeaders: ["X-Api-Key": header], autoConnect: false,
                secretHeaderKeys: ["X-Api-Key"])
            var remote = RemoteProvider(
                name: "zz-history-remote-\(UUID().uuidString.prefix(6))", host: "api.example.invalid",
                providerProtocol: .https, port: nil, basePath: "/v1", authType: .apiKey, providerType: .openaiLegacy)
            remote.enabled = false
            let remoteId = remote.id
            await MainActor.run { [remote] in
                MCPProviderManager.shared.addProvider(mcp, token: bearer)
                RemoteProviderManager.shared.addProvider(remote, apiKey: apiKey)
            }
            defer {
                Task { @MainActor in
                    MCPProviderManager.shared.removeProvider(id: mcp.id)
                    RemoteProviderManager.shared.removeProvider(id: remoteId)
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            await ConfigApplier.noticeConfigDrift(.historyOpened)

            let documents = try database.allDocuments()
            #expect(!documents.isEmpty)
            #expect(documents.contains { $0.contains(mcp.name) }, "the provider itself is versioned")
            for yaml in documents {
                for secret in [bearer, header, apiKey] {
                    #expect(!yaml.contains(secret), "a snapshot holds a secret value")
                }
                for forbidden in ["api_key:", "access_token", "refresh_token", "password:"] {
                    #expect(!yaml.lowercased().contains(forbidden))
                }
            }
        }
    }

    @Test
    func theOrchestratorFingerprintAndStatusCarryTheVersion() async throws {
        try await Self.withDatabase { _ in
            let original = await Self.currentSpellCheck()
            let before = await MainActor.run { SessionToolState.orchestratorConfigComponent() }
            _ = await ConfigApplier.apply(
                document: Self.spellCheckDocument(!original), prune: false, caller: .adminAPI)
            let version = try #require(await MainActor.run { ConfigHistoryRecorder.latestSequence })
            let after = await MainActor.run { SessionToolState.orchestratorConfigComponent() }
            #expect(after != before)
            #expect(after.hasSuffix("/ver:\(version)"))

            // `latestSequence` is process-wide: another suite's recorded apply
            // may move it, so status is checked against the value read with it.
            let status = try await StatusTool().execute(argumentsJSON: "{}")
            let current = try #require(await MainActor.run { ConfigHistoryRecorder.latestSequence })
            #expect(status.contains("\"configuration_version\":\(current)"), "\(status)")
        }
    }
}
