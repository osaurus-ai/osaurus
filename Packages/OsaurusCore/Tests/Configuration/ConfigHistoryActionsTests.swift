//
//  ConfigHistoryActionsTests.swift
//  OsaurusCoreTests
//
//  `osaurus_config` history, diff, and revert; the planner's diff on the
//  approval card and the phone list; `ConfigDiff` itself.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - ConfigDiff

struct ConfigDiffTests {

    @Test
    func unifiedTextAndPathsComeFromOneComputation() {
        let tail = "chat:\n  auto_titles: true\n  enter_to_send: true\n  show_tokens: true\n  spell_check: true\nversion: 1\n"
        let before = "agents:\n- name: alpha\n  model: a\n- name: beta\n  model: b\n" + tail
        let after = "agents:\n- name: alpha\n  model: c\n- name: gamma\n  model: g\n" + tail
        let diff = ConfigDiff.compute(before: before, after: after, fromLabel: "version 1", toLabel: "current")
        #expect(diff.unified.hasPrefix("--- version 1\n+++ current\n"))
        #expect(diff.unified.contains("-  model: a"))
        #expect(diff.unified.contains("+  model: c"))
        #expect(diff.unified.contains("-- name: beta"))
        #expect(diff.unified.contains("+- name: gamma"))
        #expect(!diff.unified.contains("spell_check"), "unchanged lines beyond the context stay out")
        #expect(Set(diff.changes.map(\.row)) == [
            ["path": "agents[alpha].model", "change": "changed"],
            ["path": "agents[beta]", "change": "removed"],
            ["path": "agents[gamma]", "change": "added"],
        ])
    }

    @Test
    func identicalDocumentsHaveNoDiff() {
        let yaml = "chat:\n  spell_check: true\nversion: 1\n"
        let diff = ConfigDiff.compute(before: yaml, after: yaml)
        #expect(diff.isEmpty)
        #expect(diff.lineCount == 0)
    }

    @Test
    func thePreviewMergesLikeTheApplier() throws {
        let current = "agents:\n- model: a\n  name: alpha\nchat:\n  auto_titles: true\n  spell_check: true\nversion: 1\n"
        var desired = OsaurusConfigDocument()
        var chat = ChatSection()
        chat.spellCheck = false
        desired.chat = chat
        let preview = try #require(ConfigDiff.preview(currentYAML: current, desired: desired, prune: false))
        #expect(preview.contains("-  spell_check: true"))
        #expect(preview.contains("+  spell_check: false"))
        let changed = preview.split(separator: "\n").filter {
            ($0.hasPrefix("+") || $0.hasPrefix("-")) && !$0.hasPrefix("+++") && !$0.hasPrefix("---")
        }
        #expect(changed.count == 2, "\(preview)")
        #expect(!changed.contains { $0.contains("auto_titles") }, "a section merge keeps keys the document leaves out")
        #expect(!changed.contains { $0.contains("alpha") }, "sections the document leaves out are untouched")
    }

    /// The card's diff for a change is the diff the apply actually makes.
    /// Other suites may move unrelated settings meanwhile, so the landed
    /// diff is compared on the lines this change touches.
    @Test
    func theCardDiffMatchesTheLandedChange() async throws {
        try await ConfigHistoryLiveLock.withDatabase { _ in
            let (document, before, preview): (OsaurusConfigDocument, String, String) = try await MainActor.run {
                var document = OsaurusConfigDocument()
                var chat = ChatSection()
                chat.spellCheck = !(ConfigExporter.export().chat?.spellCheck ?? false)
                document.chat = chat
                let before = try ConfigYAML.canonical(ConfigExporter.export())
                let plan = try ConfigPlanner.plan(document: document, prune: false)
                return (document, before, try #require(plan.diffText))
            }
            _ = await ConfigApplier.apply(document: document, prune: false)
            let after = try await MainActor.run { try ConfigYAML.canonical(ConfigExporter.export()) }
            let landed = ConfigDiff.compute(before: before, after: after).unified
            func changedLines(_ text: String) -> Set<String> {
                Set(text.split(separator: "\n").map(String.init).filter {
                    ($0.hasPrefix("+") || $0.hasPrefix("-")) && !$0.hasPrefix("+++") && !$0.hasPrefix("---")
                })
            }
            let previewLines = changedLines(preview)
            #expect(previewLines.count == 2, "\(preview)")
            #expect(previewLines.allSatisfy { $0.contains("spell_check") })
            #expect(previewLines.isSubset(of: changedLines(landed)))
        }
    }

    /// Every section the exporter writes can be previewed on the card.
    @Test @MainActor
    func everyExportedSectionHasACardDiff() throws {
        let exported = ConfigExporter.export()
        let current = try ConfigYAML.canonical(exported)
        let empty = try ConfigYAML.canonical(OsaurusConfigDocument())
        for spec in ConfigManifest.sections {
            let only = exported.filtered(to: [spec.id])
            guard try ConfigYAML.canonical(only) != empty else { continue }
            #expect(
                ConfigDiff.preview(currentYAML: current, desired: only, prune: false) != nil,
                "section \(spec.id.rawValue) has no card diff")
        }
    }

    @Test @MainActor
    func thePhoneListCutsALongDiffOnALineBoundary() {
        let short = "--- a\n+++ b\n-x\n+y"
        #expect(ConfigApprovalQueue.phoneDiffText(short) == short)

        let long = (0 ..< 400).map { "+  line number \($0) of a long change" }.joined(separator: "\n")
        let cut = ConfigApprovalQueue.phoneDiffText(long)
        #expect(cut.utf8.count <= ConfigApprovalQueue.phoneDiffLimitBytes)
        #expect(cut.hasSuffix(ConfigApprovalQueue.phoneDiffTruncationMarker))
        let body = cut.dropLast(ConfigApprovalQueue.phoneDiffTruncationMarker.count)
        for line in body.split(separator: "\n") {
            #expect(line.hasPrefix("+  line number "), "a line was cut mid-way: \(line)")
            #expect(line.hasSuffix(" of a long change"))
        }
    }
}

// MARK: - history / diff / revert

@Suite(.serialized)
struct ConfigHistoryActionTests {

    private static func withDatabase<T: Sendable>(
        _ body: @escaping @Sendable (ConfigHistoryDatabase) async throws -> T
    ) async throws -> T {
        try await ConfigHistoryLiveLock.withDatabase(body)
    }

    private static func call(_ args: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: args)
        return try parse(await callRaw(String(decoding: data, as: UTF8.self)))
    }

    private static func callRaw(_ argumentsJSON: String) async throws -> String {
        try await ChatExecutionContext.$currentAgentId.withValue(Agent.configuratorId) {
            try await OsaurusConfigTool().execute(argumentsJSON: argumentsJSON)
        }
    }

    private static func parse(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private static func spellCheck(_ value: Bool) -> OsaurusConfigDocument {
        var document = OsaurusConfigDocument()
        var chat = ChatSection()
        chat.spellCheck = value
        document.chat = chat
        return document
    }

    private static func currentSpellCheck() async -> Bool {
        await MainActor.run { ConfigExporter.export().chat?.spellCheck ?? false }
    }

    @Test
    func seededHistoryHasOneVersionPerStepWithItsCallerLabelAndAge() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let now = Date()
            try await ConfigHistoryFixtures.seed(
                [
                    .init(
                        yaml: "chat:\n  spell_check: \(!original)\n", caller: .configurator(sessionId: "seed"),
                        requestText: "flip spell check", label: "flipped", takenAt: now.addingTimeInterval(-48 * 3600)),
                    .init(
                        yaml: "chat:\n  spell_check: \(original)\n", caller: .observed(noticedAt: .beforeApply),
                        takenAt: now.addingTimeInterval(-6 * 3600)),
                ],
                foundAt: now.addingTimeInterval(-72 * 3600), foundLabel: "as found")

            let rows = Array(try database.list(limit: 10).reversed())
            #expect(rows.count == 3, "\(rows.map { ($0.sequence, $0.caller) })")
            #expect(rows.first?.caller == .observed(noticedAt: .launch))
            #expect(rows.first?.label == "as found")
            #expect(rows.dropFirst().first?.caller == .configurator(sessionId: "seed"))
            #expect(rows.dropFirst().first?.label == "flipped")
            #expect(rows.dropFirst().first?.requestText == "flip spell check")
            #expect(rows.dropFirst().first?.sectionsChanged == [.chat])
            #expect(abs((rows.last?.takenAt.timeIntervalSince(now) ?? 0) + 6 * 3600) < 1)
            #expect(rows.last?.label == nil)
            let latest = await MainActor.run { ConfigHistoryRecorder.latestSequence }
            #expect(latest == rows.last?.sequence)

            await #expect(throws: ConfigHistoryFixtures.SeedError.self, "a step that changes nothing") {
                try await ConfigHistoryFixtures.seed(
                    [.init(yaml: "chat:\n  spell_check: \(original)\n", caller: .adminAPI, takenAt: now)],
                    foundAt: now.addingTimeInterval(-60))
            }
            await ConfigHistoryFixtures.clear()
            #expect(try database.latest() == nil)
        }
    }

    @Test
    func historyListsVersionsWithWhoAndWhatAndWhatItDoesNotCover() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            await ConfigApplier.noticeConfigDrift(.launch)
            _ = await ConfigApplier.apply(document: Self.spellCheck(!original), prune: false, caller: .adminAPI)

            let envelope = try await Self.call(["action": "history"])
            #expect(envelope["ok"] as? Bool == true)
            let result = try #require(envelope["result"] as? [String: Any])
            let versions = try #require(result["versions"] as? [[String: Any]])
            #expect(result["configuration_version"] as? Int == versions.first?["version"] as? Int)
            let applied = try #require(versions.first { $0["changed_by"] as? String != "Changed in Settings" })
            #expect(applied["changed_by"] as? String == "Command line or admin API")
            #expect((applied["sections_changed"] as? [String])?.contains("chat") == true)
            #expect(versions.last?["note"] != nil, "version 0 says it is the configuration as first found")
            #expect((result["not_covered"] as? [String])?.isEmpty == false)

            let filtered = try await Self.call(["action": "history", "section": "chat", "limit": 1])
            let rows = try #require((filtered["result"] as? [String: Any])?["versions"] as? [[String: Any]])
            #expect(rows.count == 1)

            let bad = try await Self.call(["action": "history", "section": "chatt"])
            #expect(bad["ok"] as? Bool == false)
            #expect((bad["message"] as? String)?.contains("`chat`") == true)
            #expect(try database.count() >= 2)
        }
    }

    @Test
    func diffNamesWhatChangedBetweenVersionsAndAgainstCurrent() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let base = try #require(await ConfigApplier.noticeConfigDrift(.launch))
            _ = await ConfigApplier.apply(document: Self.spellCheck(!original), prune: false, caller: .adminAPI)
            let changed = try #require(try ConfigHistoryLiveLock.latestApply(database))
            try database.setLabel("flipped", sequence: changed.sequence)

            let envelope = try await Self.call(["action": "diff", "from": base.sequence, "to": "flipped"])
            let result = try #require(envelope["result"] as? [String: Any])
            #expect(result["to"] as? String == "version \(changed.sequence) “flipped”")
            let changes = try #require(result["changes"] as? [[String: String]])
            #expect(changes.contains(["path": "chat.spell_check", "change": "changed"]))
            #expect((result["diff"] as? String)?.contains("spell_check: \(!original)") == true)

            let none = try await Self.call(["action": "diff", "from": "version \(changed.sequence)", "to": "flipped"])
            #expect((none["result"] as? [String: Any])?["diff"] as? String == "no differences")
            let current = try await Self.call(["action": "diff", "from": base.sequence])
            #expect((current["result"] as? [String: Any])?["to"] as? String == "current")

            let unknown = try await Self.call(["action": "diff", "from": 99_999])
            #expect(unknown["ok"] as? Bool == false)
            #expect((unknown["message"] as? String)?.contains("history") == true)
        }
    }

    /// Revert is an ordinary apply: it raises the card with the diff, and a
    /// landed revert is credited to the Configurator with what was asked.
    @Test
    func revertRaisesTheCardAndLandsAsAConfiguratorChange() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let base = try #require(await ConfigApplier.noticeConfigDrift(.launch))
            _ = await ConfigApplier.apply(document: Self.spellCheck(!original), prune: false, caller: .adminAPI)

            await MainActor.run { ConfigApprovalQueue.shared.surfaceDidMount() }
            let arguments = #"{"action":"revert","to":\#(base.sequence),"sections":["chat"]}"#
            let revert = Task {
                try await ChatExecutionContext.$currentSessionId.withValue("session-revert") {
                    try await Self.callRaw(arguments)
                }
            }
            var card: ConfigApprovalRequest?
            for _ in 0 ..< 250 {
                card = await MainActor.run { ConfigApprovalQueue.shared.pending.first { !$0.fromPairedPhone } }
                if card != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            await MainActor.run { ConfigApprovalQueue.shared.surfaceDidUnmount() }
            let raised = try #require(card, "revert never raised a card")
            #expect(raised.plan.notes.first == "Reverting to version \(base.sequence) (chat only).")
            #expect(raised.plan.diffText?.contains("spell_check") == true)
            await MainActor.run { ConfigApprovalQueue.shared.resolve(id: raised.id, outcome: .approved) }
            let envelope = try Self.parse(try await revert.value)
            #expect(envelope["ok"] as? Bool == true, "\(envelope)")

            #expect(await Self.currentSpellCheck() == original)
            let row = try #require(try ConfigHistoryLiveLock.latestApply(database))
            #expect(row.caller == .configurator(sessionId: "session-revert"))
            #expect(row.requestText == "Revert to version \(base.sequence) (chat only)")
            #expect(row.approvalId == raised.id)
        }
    }

    @Test
    func aDeclinedRevertChangesNothing() async throws {
        try await Self.withDatabase { database in
            let original = await Self.currentSpellCheck()
            let base = try #require(await ConfigApplier.noticeConfigDrift(.launch))
            _ = await ConfigApplier.apply(document: Self.spellCheck(!original), prune: false, caller: .adminAPI)
            let rows = try database.count()

            let envelope = try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                try await Self.call(["action": "revert", "to": base.sequence])
            }
            #expect(envelope["ok"] as? Bool == false)
            #expect(await Self.currentSpellCheck() == !original)
            #expect(try database.count() == rows)
        }
    }

    @Test
    func thePhoneCannotStartARevert() async throws {
        try await Self.withDatabase { _ in
            let base = try #require(await ConfigApplier.noticeConfigDrift(.launch))
            let envelope = try await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
                try await Self.call(["action": "revert", "to": base.sequence])
            }
            #expect(envelope["ok"] as? Bool == false)
            #expect((envelope["message"] as? String)?.contains("on the Mac") == true)
            let pending = await MainActor.run { ConfigApprovalQueue.shared.pending.count }
            #expect(pending == 0)
        }
    }

    @Test
    func revertNamesAnUnknownVersionOrSection() async throws {
        try await Self.withDatabase { _ in
            await ConfigApplier.noticeConfigDrift(.launch)
            let missing = try await Self.call(["action": "revert", "to": "no such label"])
            #expect(missing["ok"] as? Bool == false)
            #expect((missing["message"] as? String)?.contains("no such label") == true)
            let current = try await Self.call(["action": "revert", "to": "current"])
            #expect(current["ok"] as? Bool == false)
            let section = try await Self.call(["action": "revert", "to": 0, "sections": ["agentz"]])
            #expect((section["message"] as? String)?.contains("agentz") == true)
        }
    }
}
