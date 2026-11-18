import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct RetainedToolResultStoreTests {
    private let owner = RetainedToolResultStore.Owner(session: "session-a", agent: UUID())

    private func fixture(
        policy: RetainedToolResultStore.Policy = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws -> (RetainedToolResultStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RetainedToolResultStore(directory: { root }, policy: policy, now: now), root)
    }

    enum TextFixture: String, CaseIterable, Sendable {
        case ascii, unicodeAndControls, singleLineJSON
        var text: String {
            switch self {
            case .ascii: return String(repeating: "a", count: 116_845)
            case .unicodeAndControls: return String(repeating: "🦖漢字e\u{0301}\n\"\\\u{0001}", count: 12_000)
            case .singleLineJSON: return "{\"single_line\":\"" + String(repeating: "v", count: 160_000) + "\"}"
            }
        }
    }

    @Test(arguments: TextFixture.allCases)
    func pagesReconstructExactNormalizedBytes(_ fixtureKind: TextFixture) throws {
        let text = fixtureKind.text
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try store.retain(text, tool: "fetch", owner: owner)
        var next = 1
        var reconstructed = ""
        var byteOffset = 0
        repeat {
            let raw = store.read(
                path: reference.path,
                owner: owner,
                arguments: ["start_line": next, "max_chars": 60_000]
            )
            #expect(raw.utf8.count <= 60_000)
            #expect(ToolEnvelope.isSuccess(raw))
            let payload = try #require(ToolEnvelope.successPayload(raw) as? [String: Any])
            let hasMore = try #require(payload["has_more"] as? Bool)
            #expect(payload["truncated"] as? Bool == hasMore)
            let envelope = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            if hasMore {
                #expect((envelope["warnings"] as? [String])?.first?.contains("Partial saved result") == true)
            } else {
                #expect(envelope["warnings"] == nil)
            }
            let content = try #require(payload["content"] as? String)
            for line in content.split(separator: "\n") {
                let record = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                #expect(record["start_byte"] as? Int == byteOffset)
                let part = try #require(record["text"] as? String)
                reconstructed += part
                byteOffset += part.utf8.count
                #expect(record["end_byte_exclusive"] as? Int == byteOffset)
            }
            if let read = payload["next_read"] as? [String: Any], let args = read["arguments"] as? [String: Any] {
                let later = try #require(args["start_line"] as? Int)
                #expect(later > next)
                next = later
            } else {
                break
            }
        } while next <= reference.lines
        #expect(Data(reconstructed.utf8) == Data(text.utf8))
        #expect(reference.sha256 == SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    @Test func sessionAndAgentMustBothMatch() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.retain("private result", tool: "fetch", owner: owner)
        for other in [
            nil, .init(session: "another-session", agent: owner.agent),
            .init(session: owner.session, agent: UUID()),
        ] as [RetainedToolResultStore.Owner?] {
            #expect(ToolEnvelope.isError(store.read(path: ref.path, owner: other, arguments: [:])))
        }
        #expect(ToolEnvelope.isSuccess(store.read(path: ref.path, owner: owner, arguments: [:])))
    }

    @Test func expiryAndMalformedReferencesFailWithoutReadingOtherFiles() throws {
        let (store, root) = try fixture(policy: .init(lifetime: -1))
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.retain("expired result", tool: "fetch", owner: owner)
        for path in [ref.path, RetainedToolResultStore.scheme + "../../secret", ref.path + "/extra"] {
            #expect(ToolEnvelope.isError(store.read(path: path, owner: owner, arguments: [:])))
        }
    }

    @Test func tamperedPayloadAndSymlinkCannotBeRead() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.retain("original text", tool: "fetch", owner: owner)
        let id = String(ref.path.dropFirst(RetainedToolResultStore.scheme.count))
        let file = root.appendingPathComponent(id + ".jsonl")
        var data = try Data(contentsOf: file)
        data[10] ^= 1
        try data.write(to: file)
        #expect(ToolEnvelope.isError(store.read(path: ref.path, owner: owner, arguments: [:])))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: root.appendingPathComponent(id + ".json")
        )
        #expect(ToolEnvelope.isError(store.read(path: ref.path, owner: owner, arguments: [:])))
    }

    @Test func quotaIncludesOrphanedPayloadAndEvictsOnlyOwnedEntries() throws {
        let (store, root) = try fixture(policy: .init(entryBytes: 10_000, quotaBytes: 6_000))
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data(repeating: 65, count: 5_000).write(to: orphan)
        let ref = try store.retain(String(repeating: "x", count: 2_000), tool: "fetch", owner: owner)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(ToolEnvelope.isSuccess(store.read(path: ref.path, owner: owner, arguments: [:])))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(bytes <= 6_000)
    }

    @Test func retentionFailureDoesNotPretendFullResultWasSaved() throws {
        let (store, root) = try fixture(policy: .init(entryBytes: 1))
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = String(repeating: "x", count: 116_845)
        let normalized = ToolRegistry.normalizeToolResult(raw, tool: "fetch", retainingFor: owner, store: store)
        let payload = try #require(ToolEnvelope.successPayload(normalized) as? [String: Any])
        #expect(payload["full_result"] == nil)
        #expect(payload["full_result_retained"] as? Bool == false)
        #expect(payload["truncated"] as? Bool == true)
    }

    @Test func recoverablePreviewIsSmallAndErrorsRemainErrors() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = String(repeating: "x", count: 116_845)
        let preview = ToolRegistry.normalizeToolResult(raw, tool: "fetch", retainingFor: owner, store: store)
        #expect(preview.utf8.count < 10_000)
        #expect(ToolEnvelope.isSuccess(preview))
        let payload = try #require(ToolEnvelope.successPayload(preview) as? [String: Any])
        #expect(payload["full_result"] != nil)
        let error = ToolEnvelope.failure(kind: .executionError, message: raw, tool: "fetch")
        #expect(
            ToolEnvelope.isError(
                ToolRegistry.normalizeToolResult(
                    error,
                    tool: "fetch",
                    retainingFor: owner,
                    store: store
                )
            )
        )
        #expect(
            ToolRegistry.normalizeToolResult("small output", tool: "fetch", retainingFor: owner, store: store)
                == ToolRegistry.normalizeToolResult("small output", tool: "fetch")
        )
    }

    @Test func explicitTinyPageBudgetIsRejectedRatherThanSilentlyRaised() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.retain("some text", tool: "fetch", owner: owner)
        #expect(ToolEnvelope.isError(store.read(path: ref.path, owner: owner, arguments: ["max_chars": 5])))
    }

    @Test func explicitLineRangesAndTailAreHonored() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try store.retain(String(repeating: "abc", count: 10_000), tool: "fetch", owner: owner)
        let range = try #require(ToolEnvelope.successPayload(store.read(
            path: ref.path, owner: owner,
            arguments: ["start_line": "3", "end_line": "4", "max_chars": 20_000]
        )) as? [String: Any])
        #expect(range["start_line"] as? Int == 3)
        #expect(range["end_line"] as? Int == 4)
        let tail = try #require(ToolEnvelope.successPayload(store.read(
            path: ref.path, owner: owner,
            arguments: ["tail_lines": 2, "start_line": 1, "max_chars": 20_000]
        )) as? [String: Any])
        #expect(tail["start_line"] as? Int == ref.lines - 1)
        #expect(tail["end_line"] as? Int == ref.lines)
        #expect(tail["has_more"] as? Bool == false)
        #expect(tail["next_read"] == nil)
        #expect(ToolEnvelope.isError(store.read(
            path: ref.path, owner: owner, arguments: ["mode": "structure"]
        )))
    }

    @Test @MainActor func recoveryMetadataSurvivesTheSummaryTextClipAndBatching() throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ToolRegistry.normalizeToolResult(
            String(repeating: "a", count: 116_845), tool: "fetch", retainingFor: owner, store: store
        )
        let payload = try #require(ToolEnvelope.successPayload(preview) as? [String: Any])
        let ref = try #require(payload["full_result"] as? [String: Any])
        let path = try #require(ref["path"] as? String)
        let transcript = ContextCompactionService.renderTranscript(
            covered: [ChatTurn(role: .tool, content: preview)], existingSummary: nil, charBudget: 20_000
        )
        #expect(transcript.contains("[Tool result recovery metadata]"))
        let previewMetadata = try #require(RetainedToolResultStore.compactionContext(preview))
        #expect(transcript.contains("[Tool result recovery metadata]: " + previewMetadata))
        let previewJSON = try #require(try JSONSerialization.jsonObject(with: Data(previewMetadata.utf8)) as? [String: Any])
        let previewReferences = try #require(previewJSON["retained_results"] as? [[String: Any]])
        #expect(previewReferences.first?["path"] as? String == path)
        let page = store.read(path: path, owner: owner, arguments: ["max_chars": 8_000])
        let pagePayload = try #require(ToolEnvelope.successPayload(page) as? [String: Any])
        let batch = ToolEnvelope.success(tool: "file_read", result: ["files": [pagePayload]])
        let metadata = try #require(RetainedToolResultStore.compactionContext(batch))
        let batchJSON = try #require(try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
        let batchReferences = try #require(batchJSON["retained_results"] as? [[String: Any]])
        #expect(batchReferences.first?["path"] as? String == path)
        let next = try #require(pagePayload["next_read"] as? [String: Any])
        let arguments = try #require(next["arguments"] as? [String: Any])
        #expect(metadata.contains("\"start_line\":\(arguments["start_line"] as? Int ?? -1)"))
        #expect(RetainedToolResultStore.compactionContext("ordinary output") == nil)
    }

    @Test @MainActor func asyncRegistryAndFileReadKeepIdentityRootAndPermissions() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = UUID()
            let scope = ToolExecutionScope(exposed: [])
            let raw = String(repeating: "payload ", count: 16_000)
            try await ChatExecutionContext.$currentSessionId.withValue("retention-integration") {
                try await ChatExecutionContext.$currentAgentId.withValue(agent) {
                    let unexposed = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                        try await ToolRegistry.normalizeExecutedToolResult(raw, tool: "fetch")
                    }
                    #expect(unexposed == ToolRegistry.normalizeToolResult(raw, tool: "fetch"))
                    scope.activate(["file_read"])
                    let normalized = try await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                        try await ToolRegistry.normalizeExecutedToolResult(raw, tool: "fetch")
                    }
                    let payload = try #require(ToolEnvelope.successPayload(normalized) as? [String: Any])
                    let reference = try #require(payload["full_result"] as? [String: Any])
                    let path = try #require(reference["path"] as? String)
                    let data = try JSONSerialization.data(withJSONObject: ["path": path, "max_chars": 8_000])
                    let args = String(decoding: data, as: UTF8.self)
                    let result = try await FileReadTool().execute(argumentsJSON: args)
                    #expect(ToolEnvelope.isSuccess(result))
                    let folder = try #require(OsaurusPaths.overrideRoot)
                    try "ordinary file".write(to: folder.appendingPathComponent("ordinary.txt"), atomically: true, encoding: .utf8)
                    let batchArgs = try JSONSerialization.data(withJSONObject: [
                        "paths": [path, "ordinary.txt", "missing.txt"], "max_chars": 8_000,
                    ])
                    let batch = try await ChatExecutionContext.$currentFolderRoot.withValue(folder) {
                        try await FileReadTool().execute(argumentsJSON: String(decoding: batchArgs, as: UTF8.self))
                    }
                    let batchPayload = try #require(ToolEnvelope.successPayload(batch) as? [String: Any])
                    let files = try #require(batchPayload["files"] as? [[String: Any]])
                    #expect(files.count == 3)
                    #expect(files[0]["kind"] as? String == "tool_result_page")
                    #expect(files[0]["ok"] as? Bool == true)
                    #expect(files[1]["ok"] as? Bool == true)
                    #expect(files[2]["ok"] as? Bool == false)
                    let forbidden = try await ChatExecutionContext.$currentSessionId.withValue("other") {
                        try await FileReadTool().execute(argumentsJSON: args)
                    }
                    #expect(ToolEnvelope.isError(forbidden))
                    let cancelled = Task {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return try await FileReadTool().execute(argumentsJSON: args)
                    }
                    do {
                        _ = try await cancelled.value
                        Issue.record("cancelled cache read returned a successful result")
                    } catch is CancellationError {}
                }
            }
        }
    }

    @Test func unknownQuotaFilesAreNeverRemoved() throws {
        let (store, root) = try fixture(policy: .init(entryBytes: 10_000, quotaBytes: 6_000))
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("not-a-cache-entry.jsonl")
        try Data(repeating: 65, count: 5_000).write(to: unrelated)
        #expect(throws: RetainedToolResultStore.StoreError.self) {
            try store.retain(String(repeating: "x", count: 2_000), tool: "fetch", owner: owner)
        }
        #expect(try Data(contentsOf: unrelated).count == 5_000)
    }
}
