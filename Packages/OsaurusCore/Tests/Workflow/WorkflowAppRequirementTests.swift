//
//  WorkflowAppRequirementTests.swift
//  OsaurusCoreTests
//
//  Declared apps: the model and its JSON (omitted when none), template
//  format 6, the `declare_app` op, the validator's rules and hints,
//  requirements and diffs, setup items, the share summary, and the
//  Architect's `workflow_discover` `apps` lookup.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowAppRequirementTests {

    private static let finalCut = AppRequirement(
        bundleID: "com.apple.FinalCut",
        name: "Final Cut Pro",
        help: "Exports the edit",
        url: "macappstore://apps.apple.com/app/id424389933"
    )

    private static func scriptStep(_ script: String = #"tell application "Final Cut Pro" to activate"#) -> WorkflowNode
    {
        WorkflowNode(
            id: "drive",
            name: "Drive the app",
            kind: .tool(ToolNodeSpec(tool: ToolRef(name: "computer_use"))),
            input: .object(["goal": script]),
            outputSchema: .object([:])
        )
    }

    private static func definition(apps: [AppRequirement] = [finalCut], step: WorkflowNode = scriptStep())
        -> WorkflowDefinition
    {
        var def = WorkflowDefinition(inputSchema: WF.object([:]), nodes: [step], output: .object([:]))
        def.apps = apps
        return def
    }

    // MARK: - Model, JSON and format

    @Test
    func app_roundTripsThroughJSON_isOmittedWhenNone_andNeedsFormat6() throws {
        let def = Self.definition()
        let data = try JSONEncoder().encode(def)
        let json = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self))?.objectValue)
        let first = try #require(json["apps"]?.arrayValue?.first?.objectValue)
        #expect(first["bundle_id"] == .string("com.apple.FinalCut"))
        #expect(first["optional"] == nil)
        #expect(try JSONDecoder().decode(WorkflowDefinition.self, from: data).apps == [Self.finalCut])

        let plain = try #require(
            JSONValue.parse(String(decoding: try JSONEncoder().encode(WF.intake()), as: UTF8.self))?.objectValue
        )
        #expect(plain["apps"] == nil)
        #expect(WF.intake().requiredFormatVersion < 6)

        #expect(def.requiredFormatVersion == 6)
        #expect(WF.template(def).formatVersion == 6)
        let sealed = WF.template(def).sealed()
        #expect(sealed.requirements.apps == [Self.finalCut])
    }

    @Test
    func app_validatesBundleIDNameAndURL() {
        #expect(Self.finalCut.issues.isEmpty)
        #expect(AppRequirement.isValidBundleID("com.apple.shortcuts"))
        #expect(!AppRequirement.isValidBundleID("Shortcuts"))
        #expect(!AppRequirement.isValidBundleID("com..apple"))
        #expect(!AppRequirement(bundleID: "com.x.y", name: "").issues.isEmpty)
        #expect(!AppRequirement(bundleID: "com.x.y", name: "Y", url: "http://example.com").issues.isEmpty)
        #expect(AppRequirement(bundleID: "com.x.y", name: "Y", url: "https://example.com").downloadURL != nil)
        #expect(Self.finalCut.downloadURL?.scheme == "macappstore")
    }

    // MARK: - declare_app

    @Test
    func declareApp_parsesUpsertsAndRemoves() throws {
        let op = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_app"), "bundle_id": .string("com.apple.FinalCut"),
                "name": .string("Final Cut Pro"), "help": .string("  "), "optional": .bool(true),
            ])
        )
        guard case .declareApp(let app) = op else {
            Issue.record("expected declareApp, got \(op)")
            return
        }
        #expect(app.optional)
        #expect(app.help == nil)

        var def = WorkflowDefinition()
        def = try WorkflowDraftPatcher.apply([op], to: def).definition
        #expect(def.apps.map(\.bundleID) == ["com.apple.FinalCut"])
        var renamed = app
        renamed.name = "Final Cut"
        renamed.bundleID = "COM.APPLE.FINALCUT"
        def = try WorkflowDraftPatcher.apply([.declareApp(renamed)], to: def).definition
        #expect(def.apps.count == 1)
        #expect(def.apps.first?.name == "Final Cut")

        let remove = try WorkflowDraftOp.parse(
            .object(["op": .string("declare_app"), "bundle_id": .string("com.apple.finalcut"), "remove": .bool(true)])
        )
        def = try WorkflowDraftPatcher.apply([remove], to: def).definition
        #expect(def.apps.isEmpty)
        #expect(throws: WorkflowDraftPatcher.Failure.self) { try WorkflowDraftPatcher.apply([remove], to: def) }

        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(
                .object(["op": .string("declare_app"), "bundle_id": .string("Final Cut"), "name": .string("X")])
            )
        }
        #expect(WorkflowDraftOp.names.contains("declare_app"))
    }

    // MARK: - Validator

    @Test
    func validator_refusesDuplicateOrInvalidApps() {
        #expect(WorkflowValidator.validate(Self.definition(), allowPlaceholders: false).isEmpty)
        let duplicate = WorkflowValidator.validate(
            Self.definition(apps: [Self.finalCut, Self.finalCut]),
            allowPlaceholders: false
        )
        #expect(duplicate.contains { $0.message.contains("more than once") })
        let invalid = WorkflowValidator.validate(
            Self.definition(apps: [AppRequirement(bundleID: "finalcut", name: "Final Cut")]),
            allowPlaceholders: false
        )
        #expect(invalid.contains { $0.message.contains("reverse-DNS") })
    }

    @Test
    func warnings_hintWhenAStepDrivesAnUndeclaredApp() {
        let declared = WorkflowValidator.warnings(Self.definition())
        #expect(!declared.contains { $0.message.contains("declare_app") })

        let undeclared = WorkflowValidator.warnings(Self.definition(apps: []))
        #expect(undeclared.contains { $0.nodeID == "drive" && $0.message.contains("\"Final Cut Pro\"") })

        let builtIn = WorkflowValidator.warnings(
            Self.definition(apps: [], step: Self.scriptStep(#"tell application "Notes" to make new note"#))
        )
        #expect(!builtIn.contains { $0.message.contains("declare_app") })

        let unnamed = WorkflowValidator.warnings(
            Self.definition(apps: [], step: Self.scriptStep("Export the open project as a movie"))
        )
        #expect(unnamed.contains { $0.nodeID == "drive" && $0.message.contains("if it drives an app") })
        let unnamedBuiltIn = WorkflowValidator.warnings(
            Self.definition(apps: [], step: Self.scriptStep("Read the front Safari tab's URL"))
        )
        #expect(!unnamedBuiltIn.contains { $0.message.contains("declare_app") })
        let unnamedDeclared = WorkflowValidator.warnings(
            Self.definition(step: Self.scriptStep("Export the open project as a movie"))
        )
        #expect(!unnamedDeclared.contains { $0.message.contains("declare_app") })

        #expect(WorkflowValidator.scriptedAppNames(in: #"tell app "Xcode" … tell application "xcode""#) == ["Xcode"])
    }

    // MARK: - Requirements and setup

    @Test
    func requirements_carryApps_mergeByID_andDiffNewOnes() {
        let reqs = WorkflowRequirementsDeriver.derive(Self.definition())
        #expect(reqs.apps == [Self.finalCut])
        #expect(reqs.items.contains { $0.kind == .app && $0.value == "com.apple.FinalCut" })

        let shortcuts = AppRequirement(bundleID: "com.apple.shortcuts", name: "Shortcuts")
        let other = TemplateRequirements(apps: [shortcuts])
        #expect(reqs.merged(with: other).apps.map(\.bundleID) == ["com.apple.FinalCut", "com.apple.shortcuts"])
        #expect(reqs.merged(with: reqs).apps.count == 1)

        let diff = TemplateDiff.newRequirements(from: reqs, to: reqs.merged(with: other))
        #expect(diff.apps == ["com.apple.shortcuts"])
        #expect(!diff.isEmpty)
        #expect(
            diff.contains(
                SetupItem(kind: .app, severity: .blocking, title: "S", detail: "", value: "com.apple.Shortcuts")
            )
        )
        #expect(
            !diff.contains(
                SetupItem(kind: .app, severity: .blocking, title: "F", detail: "", value: "com.apple.FinalCut")
            )
        )
    }

    @Test
    func setup_blocksOnAMissingApp_unlessOptional() {
        var env = SetupChecker.Environment(
            registeredToolNames: ["computer_use"],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true },
            bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true }
        )
        env.appInstalled = { _ in false }

        let missing = SetupChecker.check(
            WF.template(Self.definition()),
            bindings: InstallBindings(),
            subjectId: UUID(),
            environment: env
        )
        let item = missing.items.first { $0.kind == .app }
        #expect(item?.isBlocking == true)
        #expect(item?.value == "com.apple.FinalCut")
        #expect(item?.title == "Final Cut Pro")

        var optional = Self.finalCut
        optional.optional = true
        let advisory = SetupChecker.check(
            WF.template(Self.definition(apps: [optional])),
            bindings: InstallBindings(),
            subjectId: UUID(),
            environment: env
        )
        #expect(advisory.items.first { $0.kind == .app }?.isBlocking == false)

        env.appInstalled = { $0 == "com.apple.FinalCut" }
        let installed = SetupChecker.check(
            WF.template(Self.definition()),
            bindings: InstallBindings(),
            subjectId: UUID(),
            environment: env
        )
        #expect(!installed.items.contains { $0.kind == .app })
    }

    @Test @MainActor
    func setupWizard_showsTheAppsStepOnlyWhenAppsAreDeclared() {
        func subject(_ def: WorkflowDefinition) -> WorkflowSetupSubject {
            WorkflowSetupSubject(mode: .install, template: WF.template(def), bindings: InstallBindings(), name: "W")
        }
        let steps = WorkflowSetupWizardView.steps(
            for: subject(Self.definition()),
            report: SetupReport(subjectId: UUID(), items: []),
            newRequirements: nil
        )
        #expect(steps.contains(.apps))
        let plain = subject(Self.definition(apps: []))
        #expect(
            !WorkflowSetupWizardView.steps(
                for: plain,
                report: SetupReport(subjectId: UUID(), items: []),
                newRequirements: nil
            ).contains(.apps)
        )
    }

    @Test
    func shareSummary_listsDeclaredAndAppleApps() {
        var def = Self.definition()
        def.nodes.append(
            WorkflowNode(
                id: "note",
                name: "Note",
                kind: .tool(ToolNodeSpec(tool: ToolRef(name: "notes_create"))),
                outputSchema: .object([:])
            )
        )
        let names = WorkflowShareSummary.accessNames(WF.template(def))
        #expect(names.contains("Final Cut Pro"))
        #expect(names.contains(AppleApp.notes.displayName))
    }

    // MARK: - workflow_discover apps

    @Test
    func discoverApps_findsByName_withTheDeclareOp() throws {
        let installed = [
            InstalledMacApp(bundleID: "com.apple.shortcuts", name: "Shortcuts", url: URL(fileURLWithPath: "/S.app")),
            InstalledMacApp(
                bundleID: "com.apple.FinalCut",
                name: "Final Cut Pro",
                url: URL(fileURLWithPath: "/F.app"),
                version: "11.0"
            ),
            InstalledMacApp(bundleID: "com.example.cutter", name: "Cutter", url: URL(fileURLWithPath: "/C.app")),
        ]
        #expect(MacAppLocator.search("final cut", in: installed).map(\.name) == ["Final Cut Pro"])
        #expect(MacAppLocator.search("cut", in: installed).first?.name == "Cutter")

        let raw = WorkflowDiscoverTool.apps(
            query: "final cut",
            limit: 10,
            installed: installed,
            tool: "workflow_discover"
        )
        let result = try #require(JSONValue.parse(raw)?.objectValue?["result"]?.objectValue)
        let app = try #require(result["apps"]?.arrayValue?.first?.objectValue)
        #expect(app["bundle_id"] == .string("com.apple.FinalCut"))
        #expect(app["version"] == .string("11.0"))
        #expect(app["declare"]?.objectValue?["op"] == .string("declare_app"))

        let none = WorkflowDiscoverTool.apps(
            query: "photoshop",
            limit: 10,
            installed: installed,
            tool: "workflow_discover"
        )
        let empty = try #require(JSONValue.parse(none)?.objectValue?["result"]?.objectValue)
        #expect(empty["count"] == .number(0))
        #expect(empty["hint"]?.stringValue?.contains("bundle id") == true)
    }

    @Test
    func locator_readsInfoFromAnAppBundle() throws {
        let root = WF.tempDir()
        let app = root.appendingPathComponent("Fake.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.fake", "CFBundleName": "Fake", "CFBundleShortVersionString": "1.2",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        let vendor = root.appendingPathComponent("Vendor/Nested.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let nested: [String: Any] = ["CFBundleIdentifier": "com.example.nested", "CFBundleName": "Nested"]
        try PropertyListSerialization.data(fromPropertyList: nested, format: .xml, options: 0)
            .write(to: vendor.appendingPathComponent("Info.plist"))

        let apps = MacAppLocator.installedApps(in: [root])
        #expect(apps.map(\.bundleID) == ["com.example.fake", "com.example.nested"])
        #expect(apps.first?.version == "1.2")
    }
}
