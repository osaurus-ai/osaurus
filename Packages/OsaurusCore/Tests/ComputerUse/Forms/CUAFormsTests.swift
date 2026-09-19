import Foundation
import Testing

@testable import OsaurusCore

@Suite("CUA Forms context")
struct CUAFormContextTests {
    @Test func defaultsAreOffAndUnshared() {
        let config = CUAFormsConfiguration()
        #expect(!config.enabled)
        #expect(config.profiles.isEmpty)
        #expect(config.modelDirectory == nil)
        #expect(config.agentGrants == nil)
    }

    @Test func formActionIsOnlyAdvertisedWithAGrant() {
        func verbs(_ tool: Tool) -> [JSONValue]? {
            guard case .object(let root) = tool.function.parameters,
                case .object(let properties) = root["properties"],
                case .object(let verb) = properties["verb"],
                case .array(let values) = verb["enum"]
            else { return nil }
            return values
        }
        #expect(verbs(AgentAction.toolSpec)?.contains(.string("fill_form")) == false)
        #expect(verbs(AgentAction.toolSpec(formsEnabled: true))?.contains(.string("fill_form")) == true)
        #expect(!BrowserChildTools.all.contains { $0.function.name == "browser_fill_form" })
        #expect(BrowserChildTools.fillForm.function.name == "browser_fill_form")
    }

    @Test func oldConfigDoesNotGrantAgentAccess() throws {
        let data = Data(#"{"version":1,"enabled":true,"profiles":[]}"#.utf8)
        let config = try JSONDecoder().decode(CUAFormsConfiguration.self, from: data)
        #expect(config.agentGrants == nil)
        #expect(try CUAFormsRunContext.resolve(configuration: config, agentID: UUID()) == nil)
    }

    @Test func grantsArePerRecipientAndSnapshotsCannotChangeProfile() throws {
        let parent = UUID(), child = UUID(), sibling = UUID()
        let first = CUAFormProfile(name: "First", entities: [CUAFormEntity(label: "Name", value: "Avery")])
        let second = CUAFormProfile(name: "Second", entities: [CUAFormEntity(label: "Name", value: "Blair")])
        var config = CUAFormsConfiguration(
            enabled: true,
            modelDirectory: "/scorer",
            profiles: [first, second],
            agentGrants: [
                CUAFormAgentGrant(agentID: child, profileID: first.id),
                CUAFormAgentGrant(agentID: sibling, profileID: second.id),
            ]
        )
        let run = try #require(try CUAFormsRunContext.resolve(configuration: config, agentID: child))
        #expect(run.profile == first)
        #expect(try CUAFormsRunContext.resolve(configuration: config, agentID: sibling)?.profile == second)
        #expect(try CUAFormsRunContext.resolve(configuration: config, agentID: parent) == nil)
        try run.validateCurrent(config)
        config.agentGrants?[0].profileID = second.id
        #expect(throws: CUAFormsError.self) { try run.validateCurrent(config) }
        #expect(run.profile == first)
    }

    @Test func disableRevokeContentAndScorerChangesInvalidateRun() throws {
        let agent = UUID()
        let profile = CUAFormProfile(name: "Work", entities: [CUAFormEntity(label: "Name", value: "Avery")])
        let config = CUAFormsConfiguration(
            enabled: true,
            modelDirectory: "/scorer",
            profiles: [profile],
            agentGrants: [CUAFormAgentGrant(agentID: agent, profileID: profile.id)]
        )
        let run = try #require(try CUAFormsRunContext.resolve(configuration: config, agentID: agent))
        var disabled = config; disabled.enabled = false
        var revoked = config; revoked.agentGrants = []
        var edited = config; edited.profiles[0].entities[0].value = "Another person"
        var repinned = config; repinned.modelDirectory = "/other-scorer"
        for changed in [disabled, revoked, edited, repinned] {
            #expect(throws: CUAFormsError.self) { try run.validateCurrent(changed) }
        }
        var duplicate = config; duplicate.agentGrants?.append(CUAFormAgentGrant(agentID: agent, profileID: profile.id))
        #expect(throws: CUAFormsError.self) { try duplicate.validate() }
    }

    @Test func extractionIsReviewableExactPairsOnly() throws {
        let result = try CUAFormContextImport.candidates(
            from:
                "Contact record\nName: Avery Stone\nEmail: a@example.test\nEmail: a@example.test\nEmail: b@example.test\nNo inference here",
            source: "fixture.pdf"
        )
        #expect(result.map(\.value) == ["Avery Stone", "a@example.test", "b@example.test"])
        #expect(result.allSatisfy { $0.source == "fixture.pdf" })
        let profile = CUAFormProfile(name: "Review", entities: result)
        #expect(throws: CUAFormsError.self) { try profile.validatedEntities() }
    }

    @Test func emptyAndOversizedImportsRefuse() {
        #expect(throws: CUAFormsError.self) { try CUAFormContextImport.candidates(from: "no fields", source: "x") }
        #expect(throws: CUAFormsError.self) {
            try CUAFormContextImport.candidates(from: "Name: " + String(repeating: "a", count: 1025), source: "x")
        }
        #expect(throws: CUAFormsError.self) {
            try CUAFormContextImport.candidates(
                from: (0 ..< 65).map { "Field\($0): Value\($0)" }.joined(separator: "\n"),
                source: "x"
            )
        }
    }

    @Test func profileRejectsEncodedCollisionsAndNewlines() {
        let prefix = String(repeating: "a", count: 100)
        let collision = CUAFormProfile(
            name: "x",
            entities: [
                CUAFormEntity(label: prefix + "1", value: "one"), CUAFormEntity(label: prefix + "2", value: "two"),
            ]
        )
        #expect(throws: CUAFormsError.self) { try collision.validatedEntities() }
        #expect(throws: CUAFormsError.self) {
            try CUAFormProfile(name: "x", entities: [CUAFormEntity(label: "Name", value: "a\nb")]).validatedEntities()
        }
    }

    @Test func roundTripAndDeleteArePrivateAndExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CUAFormContextStore(directory: directory)
        #expect(try await store.load() == CUAFormsConfiguration())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let profile = CUAFormProfile(name: "Work", entities: [CUAFormEntity(label: "Name", value: "Avery Stone")])
        let config = CUAFormsConfiguration(
            enabled: true,
            modelDirectory: "/local/scorer",
            selectedProfileID: profile.id,
            profiles: [profile]
        )
        try await store.save(config)
        #expect(try await CUAFormContextStore(directory: directory).load() == config)
        let mode =
            try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("profiles.json").path)[
                .posixPermissions
            ] as? Int
        #expect(mode == 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        try await store.save(CUAFormsConfiguration())
        #expect(try await CUAFormContextStore(directory: directory).load().profiles.isEmpty)
    }

    @Test func corruptOrNewerConfigDoesNotSilentlyReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("profiles.json")
        try Data("not json".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await CUAFormContextStore(directory: directory).load() }
        var unsupported = CUAFormsConfiguration()
        unsupported.version = 2
        #expect(throws: CUAFormsError.self) { try unsupported.validate() }
    }

    @Test func boundedReadRejectsSymlinksAndExcessBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("data")
        let link = directory.appendingPathComponent("link")
        try Data("abcd".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try CUAFormsFile.read(file, limit: 4) == Data("abcd".utf8))
        #expect(throws: CUAFormsError.self) { try CUAFormsFile.read(file, limit: 3) }
        #expect(throws: CUAFormsError.self) { try CUAFormsFile.read(link, limit: 4) }
        #expect(throws: CUAFormsError.self) { try CUAFormsFile.read(directory, limit: 4) }
    }
}

@Suite("CUA Forms planner and executor")
struct CUAFormsPlanTests {
    private let app = CUAppListing(
        pid: 4242,
        bundleId: "org.example.fixture",
        name: "Form Fixture",
        active: true,
        hidden: false
    )
    private let window = CUWindowInfo(
        windowId: 7,
        title: "Registration",
        focused: true,
        minimized: false,
        x: 0,
        y: 0,
        w: 800,
        h: 600
    )
    private let entity = CUAFormEntity(label: "Name", value: "Avery Stone")

    private func field(_ id: String = "s1-1", value: String = "", x: Int = 20, role: String = "textfield") -> CUElement
    {
        CUElement(
            id: id,
            role: role,
            label: "Name",
            value: value,
            path: "Window/Name",
            windowId: 7,
            x: x,
            y: 20,
            w: 200,
            h: 24
        )
    }

    private func snapshot(_ elements: [CUElement], truncated: Bool = false, title: String = "Registration")
        -> CUSnapshot
    {
        CUSnapshot(
            snapshotId: 1,
            pid: 4242,
            app: "Form Fixture",
            focusedWindow: title,
            tier: .ax,
            truncated: truncated,
            windows: [CUWindowSummary(id: 7, title: title, focused: true, x: 0, y: 0, w: 800, h: 600)],
            elements: elements,
            image: nil
        )
    }

    private func driver(_ snapshots: [CUSnapshot]) -> MockMacDriver {
        MockMacDriver(apps: [app], windowsByPid: [4242: [window]], snapshots: [4242: snapshots])
    }

    private func decision(_ element: CUElement, action: CUAFormAction? = nil, probability: Float = 1) -> CUAFormDecision
    {
        CUAFormDecision(id: UUID(), element: element, action: action ?? .fill(entity), probability: probability)
    }

    private func plan(_ decisions: [CUAFormDecision]) -> CUAFormPlan {
        CUAFormPlan(
            target: CUAFormTarget(app: app, window: window),
            profileName: "Fixture",
            decisions: decisions,
            scoringSeconds: 0
        )
    }

    private struct Scores: CUAFormsScoring {
        let rows: [[Float]]
        func probabilities(contexts: [String], options: [String]) async throws -> [[Float]] { rows }
    }

    @Test func upstreamCheckboxAndUnicodeContextContract() {
        let checkbox = CUElement(id: "x", role: "AXCheckBox", label: "Agree", value: "1")
        #expect(CUAFormsPlanner.context(for: checkbox, title: "Form").hasSuffix("ELEMENT CheckBox \"Agree\" checked"))
        let combining = String(repeating: "e\u{301}", count: 40)
        let rendered = CUAFormsPlanner.context(for: field(), title: combining)
        #expect(rendered.contains("FORM " + String(repeating: "e\u{301}", count: 32) + "\n"))
        #expect(CUAFormsPlanner.role("AXSecureTextField") == nil)
    }

    @Test func byteTruncationUsesUTF8PlusOne() {
        #expect(CUAFormsScorer.byteIDs("éx", limit: 1) == [196])
        #expect(CUAFormsScorer.byteIDs("éx", limit: 3) == [196, 170, 121])
        #expect(CUAFormsScorer.byteIDs("", limit: 224).isEmpty)
    }

    @Test func previewNeverMutatesAndOnlyScoresChosenWindow() async throws {
        let unrelated = CUElement(id: "other", role: "textfield", label: "Secret", windowId: 9)
        let driver = driver([snapshot([field(), unrelated])])
        let plan = try await CUAFormsPlanner.preview(
            profile: CUAFormProfile(name: "Fixture", entities: [entity]),
            target: CUAFormTarget(app: app, window: window),
            driver: driver,
            scorer: Scores(rows: [[1, 0, 0, 0]])
        )
        #expect(plan.decisions.count == 1)
        #expect(await driver.elementActions.isEmpty)
        #expect(await driver.coordinateActions.isEmpty)
    }

    @Test func invalidScoresAreRejected() async {
        let invalid: [[[Float]]] = [[], [[Float.nan, 0, 0, 0]], [[0.1, 0.1, 0.1, 0.1]], [[1, 0]]]
        for rows in invalid {
            await #expect(throws: CUAFormsError.self) {
                try await CUAFormsPlanner.preview(
                    profile: CUAFormProfile(name: "Fixture", entities: [entity]),
                    target: CUAFormTarget(app: app, window: window),
                    driver: driver([snapshot([field()])]),
                    scorer: Scores(rows: rows)
                )
            }
        }
    }

    @Test func eligibleActionsExcludeSubmitSecureUnknownAndLowConfidence() {
        #expect(!decision(field(role: "button"), action: .click).canApply)
        #expect(!decision(field(role: "securetextfield")).canApply)
        #expect(!decision(field(role: "combobox")).canApply)
        #expect(!decision(field(), probability: 0.49).canApply)
        #expect(!decision(field(value: "", role: "checkbox"), action: .check).canApply)
        #expect(!decision(field(value: "1", role: "checkbox"), action: .check).canApply)
        #expect(decision(field(value: "0", role: "checkbox"), action: .check).canApply)
    }

    @Test func applyUsesFreshIDAndVerifiesActualValue() async {
        let item = decision(field())
        let driver = driver([snapshot([field("s2-9")]), snapshot([field("s3-2", value: entity.value)])])
        let report = await CUAFormsExecutor.apply(
            plan: plan([item]),
            selected: [item.id],
            confirmed: true,
            driver: driver,
            enabled: { true },
            policy: { .defaultPolicy }
        )
        #expect(report.completed == 1)
        #expect(report.stoppedReason == nil)
        let actions = await driver.elementActions
        #expect(actions.count == 1)
        if case .setValue(let id, let value) = actions.first {
            #expect(id == "s2-9")
            #expect(value == entity.value)
        } else {
            Issue.record("Expected an AX setValue with the fresh snapshot target")
        }
        #expect(await driver.captureCount == 2)
        #expect(await driver.coordinateActions.isEmpty)
    }

    @Test func lackOfConfirmationDisabledAndForeignSelectionDoNothing() async {
        let item = decision(field())
        for (confirmed, enabled, selected) in [
            (false, true, Set([item.id])), (true, false, Set([item.id])), (true, true, Set([UUID()])),
        ] {
            let driver = driver([snapshot([field()])])
            let report = await CUAFormsExecutor.apply(
                plan: plan([item]),
                selected: selected,
                confirmed: confirmed,
                driver: driver,
                enabled: { enabled },
                policy: { .defaultPolicy }
            )
            #expect(report.completed == 0)
            #expect(report.stoppedReason != nil)
            #expect(await driver.elementActions.isEmpty)
        }
    }

    @Test func staleValueMovedAmbiguousAndTruncatedTargetsDoNothing() async {
        let item = decision(field())
        for snap in [
            snapshot([field(value: "User edit")]), snapshot([field(x: 80)]),
            snapshot([field(), field("duplicate")]), snapshot([field()], truncated: true),
            snapshot([field()], title: "Different page"),
        ] {
            let driver = driver([snap])
            let report = await CUAFormsExecutor.apply(
                plan: plan([item]),
                selected: [item.id],
                confirmed: true,
                driver: driver,
                enabled: { true },
                policy: { .defaultPolicy }
            )
            #expect(report.stoppedReason != nil)
            #expect(await driver.elementActions.isEmpty)
        }
    }

    @Test func readOnlyAndAppAllowlistRemainAuthoritative() async {
        let item = decision(field())
        for policy in [AutonomyPolicy(globalPreset: .readOnly), AutonomyPolicy(allowlist: ["Other app"])] {
            let driver = driver([snapshot([field()])])
            let report = await CUAFormsExecutor.apply(
                plan: plan([item]),
                selected: [item.id],
                confirmed: true,
                driver: driver,
                enabled: { true },
                policy: { policy }
            )
            #expect(report.stoppedReason != nil)
            #expect(await driver.elementActions.isEmpty)
        }
    }

    @Test func missingPermissionAndChangedAppAreRejected() async {
        let driver = driver([snapshot([field()])])
        await driver.setAvailability(MacDriverAvailability(accessibility: false, screenRecording: true, skyLight: true))
        await #expect(throws: MacDriverError.self) {
            try await CUAFormsPlanner.capture(target: CUAFormTarget(app: app, window: window), driver: driver)
        }
        await driver.setAvailability(MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true))
        await driver.setApps([
            CUAppListing(pid: 4242, bundleId: "replacement", name: app.name, active: true, hidden: false)
        ])
        await #expect(throws: CUAFormsError.self) {
            try await CUAFormsPlanner.capture(target: CUAFormTarget(app: app, window: window), driver: driver)
        }
        #expect(await driver.captureCount == 0)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["CUA_FORMS_REFERENCE_DIR"] != nil),
        arguments: ["apply", "revoke", "interrupt", "unverified", "readOnly", "permissionRevoked"]
    )
    func realS1DesktopRunUsesGateGrantAndVerifiedValue(mode: String) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CUA_FORMS_REFERENCE_DIR"]))
        let agent = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s1-ax-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = CUAFormProfile(name: "Synthetic", entities: [entity])
        let config = CUAFormsConfiguration(
            enabled: true,
            modelDirectory: root.appendingPathComponent("scorer").path,
            profiles: [profile],
            agentGrants: [CUAFormAgentGrant(agentID: agent, profileID: profile.id)]
        )
        let store = CUAFormContextStore(directory: directory)
        try await store.save(config)
        let context = try #require(try CUAFormsRunContext.resolve(configuration: config, agentID: agent))
        let interrupt = InterruptToken(), permissionRevoked = InterruptToken()
        let run = CUAFormsAgentRun(
            context: context,
            store: store,
            executionAllowed: { !permissionRevoked.isInterrupted }
        )
        let before = snapshot([field()])
        let after = snapshot([field("fresh-id", value: mode == "unverified" ? "" : entity.value)])
        let driver = driver([before, before, before, after])
        let policy = mode == "readOnly" ? AutonomyPolicy(globalPreset: .readOnly) : .defaultPolicy
        let report = await run.fill(
            snapshot: before,
            driver: driver,
            gate: ComputerUseGate(policy: policy),
            confirm: { _ in
                if mode == "revoke" {
                    var revoked = config; revoked.agentGrants = []
                    try? await store.save(revoked)
                }
                if mode == "interrupt" { interrupt.interrupt() }
                if mode == "permissionRevoked" { permissionRevoked.interrupt() }
                return true
            },
            isInterrupted: { interrupt.isInterrupted },
            feed: SubagentFeed(toolCallId: "s1-ax", kindId: "computer_use", title: "Test")
        )
        #expect(report.completed == (mode == "apply" ? 1 : 0))
        #expect((report.stoppedReason == nil) == (mode == "apply"))
        #expect(await driver.elementActions.count == (["apply", "unverified"].contains(mode) ? 1 : 0))
        #expect(await driver.coordinateActions.isEmpty)
        let receipt = try #require(await run.receipt())
        #expect(receipt.scoredFields == 1)
        #expect(receipt.appliedFields == report.completed)
    }

    @Test func unverifiedEffectAndDriverFailureNeverReportSuccess() async {
        let item = decision(field())
        for result in [CUActionResult.ok(), .failure("unsupported"), CUActionResult(success: true, stale: true)] {
            let driver = driver([snapshot([field()])])
            await driver.enqueueActionResults([result])
            let report = await CUAFormsExecutor.apply(
                plan: plan([item]),
                selected: [item.id],
                confirmed: true,
                driver: driver,
                enabled: { true },
                policy: { .defaultPolicy }
            )
            #expect(report.completed == 0)
            #expect(report.stoppedReason != nil)
            #expect(await driver.elementActions.count == 1)
            #expect(await driver.coordinateActions.isEmpty)
        }
    }

    @Test func cancellationKeepsAccuratePartialCount() async {
        let first = decision(field()), second = decision(field("second", x: 250))
        let driver = driver([
            snapshot([field(), second.element]), snapshot([field(value: entity.value), second.element]),
        ])
        let plan = plan([first, second])
        let task = Task {
            await CUAFormsExecutor.apply(
                plan: plan,
                selected: [first.id, second.id],
                confirmed: true,
                driver: driver,
                enabled: { true },
                policy: { .defaultPolicy },
                progress: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        let report = await task.value
        #expect(report.completed == 1)
        #expect(report.requested == 2)
        #expect(report.stoppedReason?.contains("Cancelled") == true)
        #expect(await driver.elementActions.count == 1)
    }
}

@Suite("CUA Forms native reference parity", .serialized)
struct CUAFormsNativeParityTests {
    private static var evidencePath: String? { ProcessInfo.processInfo.environment["CUA_FORMS_REFERENCE_DIR"] }

    struct Golden: Decodable {
        struct Row: Decodable {
            let name: String
            let contexts: [String]
            let options: [String]
            let probabilities: [[Float]]
        }
        struct Schema: Decodable {
            let title: String
            let role: String
            let label: String
            let value: String
            let checked: Bool?
            let placeholder: String
            let context: String
        }
        let cases: [Row]
        let schema: [Schema]
    }

    @Test(.enabled(if: evidencePath != nil, "Provide output of scripts/live-proof/prepare_cua_forms.py"))
    func publishedCheckpointAndUpstreamFP32Probabilities() async throws {
        let directory = URL(fileURLWithPath: try #require(Self.evidencePath))
        let golden = try JSONDecoder().decode(
            Golden.self,
            from: Data(contentsOf: directory.appendingPathComponent("goldens.json"))
        )
        let scorer = try CUAFormsScorer(directory: directory.appendingPathComponent("scorer"))
        var decisions = 0, probabilities = 0
        var maximumError: Float = 0
        for row in golden.cases {
            let start = ContinuousClock.now
            let actual = try await scorer.probabilities(contexts: row.contexts, options: row.options)
            let duration = start.duration(to: .now)
            #expect(actual.count == row.probabilities.count)
            for (native, reference) in zip(actual, row.probabilities) {
                #expect(native.count == reference.count)
                #expect(
                    native.indices.max(by: { native[$0] < native[$1] })
                        == reference.indices.max(by: { reference[$0] < reference[$1] })
                )
                for (a, b) in zip(native, reference) {
                    maximumError = max(maximumError, abs(a - b))
                    #expect(abs(a - b) <= 0.0001, "FP32 parity \(row.name): \(a) versus \(b)")
                    probabilities += 1
                }
                decisions += 1
            }
            print(
                "CUA_FORMS_NATIVE case=\(row.name) decisions=\(actual.count) duration=\(duration) tokens_per_second=not_applicable"
            )
        }
        for row in golden.schema {
            let value = row.checked.map { $0 ? "1" : "0" } ?? row.value
            let element = CUElement(
                id: "schema",
                role: row.role,
                label: row.label,
                value: value,
                placeholder: row.placeholder
            )
            #expect(CUAFormsPlanner.context(for: element, title: row.title) == row.context)
        }
        print(
            "CUA_FORMS_PARITY decisions=\(decisions) probabilities=\(probabilities) maximum_absolute_error=\(maximumError) schema_rows=\(golden.schema.count)"
        )
    }

    @Test(.enabled(if: evidencePath != nil, "Provide safe converted checkpoint for integrity checks"))
    func mismatchedTamperedAndTruncatedCheckpointsRefuse() throws {
        let directory = URL(fileURLWithPath: try #require(Self.evidencePath)).appendingPathComponent("scorer")
        let config = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let weights = try Data(contentsOf: directory.appendingPathComponent("model.safetensors"))
        _ = try CUAFormsCheckpoint(configData: config, weightsData: weights)
        var tampered = weights
        tampered[tampered.count - 1] ^= 1
        #expect(throws: CUAFormsError.self) { try CUAFormsCheckpoint(configData: config, weightsData: tampered) }
        #expect(throws: (any Error).self) {
            try CUAFormsCheckpoint(configData: config, weightsData: weights.prefix(20))
        }
        var object = try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
        var dimensions = try #require(object["config"] as? [String: Any])
        dimensions["width"] = 999_999
        object["config"] = dimensions
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CUAFormsError.self) { try CUAFormsCheckpoint(configData: invalid, weightsData: weights) }
    }
}
