//
//  WorkflowDependencyTests.swift
//  OsaurusCoreTests
//
//  Declared dependencies: the model and its JSON (stable content hashes
//  when none are declared), the requirements derived from a definition,
//  the validator's rules, the `declare_dependency` draft op, the setup
//  checker's dependency items, the environment status rules, and the
//  run-time routing a sandbox workflow gets (execution surface, shell
//  exit 127, granted paths, workspace under the share).
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowDependencyTests {

    private static let ytdlp = WorkflowDependency(manager: .pip, packages: ["yt-dlp"], binaries: ["yt-dlp"])

    private static func shellStep(_ command: String, id: String = "download") -> WorkflowNode {
        WorkflowNode(
            id: id, name: id.capitalized, kind: .tool(ToolNodeSpec(tool: ToolRef(name: "shell_run"))),
            input: .object(["command": command]), outputSchema: .object([:]))
    }

    private static func definition(
        dependencies: [WorkflowDependency] = [ytdlp], steps: [WorkflowNode]? = nil
    ) -> WorkflowDefinition {
        var def = WorkflowDefinition(
            inputSchema: WF.object(["url": WF.string], required: ["url"]),
            nodes: steps ?? [shellStep("yt-dlp -o out.mp4 {{input.url}}")],
            output: .object(["text": "{{nodes.download.output.text}}"]))
        def.dependencies = dependencies
        return def
    }

    // MARK: - Model and JSON

    @Test
    func dependency_roundTripsThroughJSON_andOmitsEmptyBinaries() throws {
        let data = try JSONEncoder().encode(Self.ytdlp)
        let json = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self))?.objectValue)
        #expect(json["manager"] == .string("pip"))
        #expect(json["packages"] == .array([.string("yt-dlp")]))
        #expect(json["binaries"] == .array([.string("yt-dlp")]))
        #expect(try JSONDecoder().decode(WorkflowDependency.self, from: data) == Self.ytdlp)

        let library = WorkflowDependency(manager: .npm, packages: ["marked"])
        let libraryJSON = try #require(
            JSONValue.parse(String(decoding: try JSONEncoder().encode(library), as: UTF8.self))?.objectValue)
        #expect(libraryJSON["binaries"] == nil)
    }

    @Test
    func definitionAndRequirements_omitDependenciesWhenNone_soContentHashesAreStable() throws {
        let plain = WF.intake()
        let defJSON = try #require(JSONValue.parse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self))?.objectValue)
        #expect(defJSON["dependencies"] == nil)
        #expect(!plain.usesSandbox)

        let reqs = WorkflowRequirementsDeriver.derive(plain)
        let reqJSON = try #require(JSONValue.parse(String(decoding: try JSONEncoder().encode(reqs), as: UTF8.self))?.objectValue)
        #expect(reqJSON["dependencies"] == nil)
        #expect(!reqs.usesSandbox)

        let withDeps = Self.definition()
        let decoded = try JSONDecoder().decode(WorkflowDefinition.self, from: try JSONEncoder().encode(withDeps))
        #expect(decoded.dependencies == [Self.ytdlp])
        #expect(decoded.usesSandbox)
    }

    @Test
    func deriver_carriesDependenciesIntoRequirements_asRowsPerPackage() {
        let reqs = WorkflowRequirementsDeriver.derive(Self.definition())
        #expect(reqs.dependencies == [Self.ytdlp])
        #expect(reqs.usesSandbox)
        let rows = reqs.items.filter { $0.kind == .dependency }
        #expect(rows.map(\.value) == ["pip:yt-dlp"])
        #expect(rows.first?.label?.contains("yt-dlp") == true)
    }

    @Test
    func mergedRequirements_unionPackagesPerManager() {
        let a = WorkflowRequirementsDeriver.derive(Self.definition())
        var other = Self.definition(dependencies: [
            WorkflowDependency(manager: .pip, packages: ["ffmpeg-python"], binaries: []),
            WorkflowDependency(manager: .npm, packages: ["marked"], binaries: ["marked"]),
        ])
        other.nodes = [Self.shellStep("marked README.md")]
        let b = WorkflowRequirementsDeriver.derive(other)
        let merged = a.merged(with: b)
        #expect(merged.dependencies.count == 2)
        let pip = merged.dependencies.first { $0.manager == .pip }
        #expect(Set(pip?.packages ?? []) == ["yt-dlp", "ffmpeg-python"])
        #expect(pip?.binaries == ["yt-dlp"])
        #expect(merged.dependencies.contains { $0.manager == .npm && $0.packages == ["marked"] })
    }

    @Test
    func upserting_replacesTheManagerEntry_andEmptyPackagesRemovesIt() {
        var deps = WorkflowDependency.upserting(Self.ytdlp, in: [])
        #expect(deps == [Self.ytdlp])
        let replacement = WorkflowDependency(manager: .pip, packages: ["yt-dlp", "mutagen"], binaries: ["yt-dlp"])
        deps = WorkflowDependency.upserting(replacement, in: deps)
        #expect(deps == [replacement])
        deps = WorkflowDependency.upserting(WorkflowDependency(manager: .pip, packages: []), in: deps)
        #expect(deps.isEmpty)
    }

    @Test
    func issues_rejectBadSpecifiersAndNonBareBinaries() {
        #expect(Self.ytdlp.issues.isEmpty)
        let bad = WorkflowDependency(manager: .pip, packages: ["yt-dlp; rm -rf /"], binaries: ["/usr/bin/yt-dlp"])
        // A path in the specifier, a shell fragment, and a non-bare binary.
        #expect(bad.issues.count == 3)
        #expect(WorkflowDependency(manager: .npm, packages: []).issues.count == 1)
    }

    // MARK: - Validator

    @Test
    func validator_acceptsADeclaredDependencyUsedByAShellStep() {
        let issues = WorkflowValidator.validate(Self.definition(), allowPlaceholders: false)
        #expect(issues.isEmpty, "\(issues)")
    }

    @Test
    func validator_flagsInstallCommandsInShellSteps() {
        let def = Self.definition(steps: [
            Self.shellStep("pip install yt-dlp && yt-dlp {{input.url}}")
        ])
        let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
        #expect(issues.contains { $0.message.contains("declare_dependency") }, "\(issues)")
        #expect(WorkflowValidator.containsInstallCommand("npm install -g marked"))
        #expect(WorkflowValidator.containsInstallCommand("brew install ffmpeg"))
        #expect(WorkflowValidator.containsInstallCommand("apk add ffmpeg"))
        #expect(!WorkflowValidator.containsInstallCommand("yt-dlp --version"))
        #expect(!WorkflowValidator.containsInstallCommand("echo 'pip install' > notes.txt"), "quoted text is not a command")
    }

    @Test
    func validator_flagsDependenciesNoShellStepUses_exceptWhilePlanning() {
        let def = Self.definition(steps: [WF.code("summarize")])
        #expect(!WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
        #expect(WorkflowValidator.validate(def, allowPlaceholders: true).filter { $0.message.contains("shell_run") }.isEmpty)
    }

    @Test
    func validator_flagsDuplicateManagersAndBadSpecifiers() {
        var def = Self.definition()
        def.dependencies = [Self.ytdlp, WorkflowDependency(manager: .pip, packages: ["mutagen"])]
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).contains { $0.message.contains("once") })
        def.dependencies = [WorkflowDependency(manager: .pip, packages: ["yt-dlp; rm -rf /"])]
        #expect(!WorkflowValidator.validate(def, allowPlaceholders: false).isEmpty)
    }

    // MARK: - Draft op

    @Test
    func declareDependencyOp_parsesAndUpsertsOnTheDefinition() throws {
        let op = try WorkflowDraftOp.parse(
            .object([
                "op": .string("declare_dependency"), "manager": .string("pip"),
                "packages": .array([.string("yt-dlp")]), "binaries": .array([.string("yt-dlp")]),
            ]))
        #expect(op == .declareDependency(Self.ytdlp))
        let result = try WorkflowDraftPatcher.apply([op], to: WF.intake())
        #expect(result.definition.dependencies == [Self.ytdlp])
        #expect(result.definition.usesSandbox)

        #expect(throws: (any Error).self) {
            try WorkflowDraftOp.parse(
                .object(["op": .string("declare_dependency"), "manager": .string("brew"), "packages": .array([.string("x")])]))
        }
        #expect(throws: (any Error).self) {
            try WorkflowDraftOp.parse(
                .object([
                    "op": .string("declare_dependency"), "manager": .string("pip"),
                    "packages": .array([.string("yt-dlp; rm -rf /")]),
                ]))
        }
    }

    // MARK: - Environment status

    @Test
    func environmentStatus_followsTheManifestBackendAndImage() {
        let manifest = WorkflowSandboxManifest(
            backend: "virtualMachine", imageDigest: "sha256:abc",
            installed: [.init(manager: .pip, packages: ["yt-dlp"], binaries: ["yt-dlp"])], installedAt: Date())
        func status(_ dep: WorkflowDependency, _ m: WorkflowSandboxManifest?, backend: String = "virtualMachine", image: String = "sha256:abc")
            -> WorkflowDependencyStatus
        {
            WorkflowSandboxEnvironment.status(of: dep, manifest: m, backend: backend, imageDigest: image)
        }
        #expect(status(Self.ytdlp, manifest) == .installed)
        #expect(status(Self.ytdlp, nil) == .notInstalled)
        #expect(status(WorkflowDependency(manager: .pip, packages: ["yt-dlp", "mutagen"]), manifest) == .notInstalled)
        #expect(status(Self.ytdlp, manifest, image: "sha256:def") == .stale)
        #expect(status(Self.ytdlp, manifest, backend: "seatbelt") == .stale)
        #expect(status(WorkflowDependency(manager: .apk, packages: ["ffmpeg"]), nil, backend: "seatbelt") == .unsupportedHere)
        #expect(status(WorkflowDependency(manager: .apk, packages: ["ffmpeg"]), nil) == .notInstalled)
    }

    @Test
    func rootfsEviction_marksApkForReinstallAndKeepsPip() {
        let ffmpeg = WorkflowDependency(manager: .apk, packages: ["ffmpeg"])
        let manifest = WorkflowSandboxManifest(
            backend: "virtualMachine", imageDigest: "sha256:abc",
            installed: [
                .init(manager: .pip, packages: ["yt-dlp"], binaries: ["yt-dlp"]),
                .init(manager: .apk, packages: ["ffmpeg"], binaries: []),
            ],
            installedAt: Date())
        let evicted = manifest.afterRootfsEviction()
        func status(_ dep: WorkflowDependency, image: String = "sha256:abc") -> WorkflowDependencyStatus {
            WorkflowSandboxEnvironment.status(of: dep, manifest: evicted, backend: "virtualMachine", imageDigest: image)
        }
        #expect(status(Self.ytdlp) == .installed)
        #expect(status(ffmpeg) == .reinstallOnRun)
        // A new image means the eviction record is no longer trustworthy.
        #expect(status(ffmpeg, image: "sha256:def") == .notInstalled)
        // Evicting again does not duplicate the record.
        #expect(evicted.afterRootfsEviction().evicted?.count == 1)
    }

    @Test
    func reinstallOnRun_isAdvisoryNotBlocking() {
        let template = WF.template(Self.definition())
        let report = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment { _ in .reinstallOnRun })
        let dependencyItems = report.items.filter { $0.kind == .dependency }
        #expect(!dependencyItems.isEmpty)
        #expect(dependencyItems.allSatisfy { !$0.isBlocking })
    }

    // MARK: - Setup checker

    private static func environment(
        sandbox: ContainerStatus = .running, network: String = "outbound",
        status: @escaping (WorkflowDependency) -> WorkflowDependencyStatus
    ) -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: ["shell_run"],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.sandboxStatus = sandbox
        env.sandboxNetworkMode = network
        env.dependencyStatus = { _, dep in status(dep) }
        return env
    }

    @Test
    func setupChecker_blocksOnMissingDependencies_andIsCleanOnceInstalled() {
        let template = WF.template(Self.definition())
        let missing = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(), environment: Self.environment { _ in .notInstalled })
        let items = missing.items.filter { $0.kind == .dependency }
        #expect(items.count == 1)
        #expect(items.first?.value == "pip")
        #expect(items.first?.isBlocking == true)
        #expect(items.first?.detail.contains("Dependencies step") == true)

        let installed = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(), environment: Self.environment { _ in .installed })
        #expect(installed.items.filter { $0.kind == .dependency }.isEmpty)
    }

    @Test
    func setupChecker_reportsSandboxNotProvisioned_noNetwork_andUnsupportedManagers() {
        let template = WF.template(Self.definition())
        let notProvisioned = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(sandbox: .notProvisioned) { _ in .notInstalled })
        #expect(notProvisioned.items.contains { $0.kind == .dependency && $0.value == "sandbox" && $0.isBlocking })

        let noNetwork = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(network: "none") { _ in .notInstalled })
        #expect(noNetwork.items.contains { $0.value == "sandbox-network" && $0.isBlocking })

        let proxied = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(network: "proxy") { _ in .notInstalled })
        #expect(proxied.items.contains { $0.value == "sandbox-network" && !$0.isBlocking })

        // Installed already: the network does not matter.
        let installedNoNetwork = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment(network: "none") { _ in .installed })
        #expect(!installedNoNetwork.items.contains { $0.value == "sandbox-network" })

        var apk = Self.definition(dependencies: [WorkflowDependency(manager: .apk, packages: ["ffmpeg"], binaries: ["ffmpeg"])])
        apk.nodes = [Self.shellStep("ffmpeg -i in.mp4 out.mp3")]
        let unsupported = SetupChecker.check(
            WF.template(apk), bindings: InstallBindings(), subjectId: UUID(),
            environment: Self.environment { _ in .unsupportedHere })
        #expect(unsupported.items.contains { $0.kind == .dependency && $0.value == "apk" && $0.detail.contains("Linux sandbox") })
    }

    @Test
    func setupChecker_keysDependencyStatusByTemplateID() {
        let template = WF.template(Self.definition())
        var asked: [UUID] = []
        var env = Self.environment { _ in .installed }
        env.dependencyStatus = { id, _ in
            asked.append(id)
            return .installed
        }
        _ = SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: env)
        #expect(asked == [template.id])
    }

    @Test
    func templateDiff_namesNewOrGrownDependencies() {
        let old = WorkflowRequirementsDeriver.derive(Self.definition())
        var grown = Self.definition(dependencies: [
            WorkflowDependency(manager: .pip, packages: ["yt-dlp", "mutagen"], binaries: ["yt-dlp"]),
            WorkflowDependency(manager: .npm, packages: ["marked"]),
        ])
        grown.nodes = [Self.shellStep("yt-dlp {{input.url}} && marked")]
        let new = WorkflowRequirementsDeriver.derive(grown)
        #expect(TemplateDiff.newRequirements(from: old, to: new).dependencies == ["pip", "npm"])
        #expect(TemplateDiff.newRequirements(from: old, to: old).dependencies.isEmpty)
    }

    // MARK: - Run-time routing

    @Test
    func executionSurface_routesShellIntoTheWorkflowSandbox_evenWithAFolderRoot() {
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "shell_run", pathArgument: nil, hasSandboxBridge: true, hasFolderRoot: true,
                hasWorkflowSandbox: true) == .sandboxVM)
        #expect(
            ToolExecutionSurface.forContextRoutedTool(
                name: "shell_run", pathArgument: nil, hasSandboxBridge: false, hasFolderRoot: true,
                hasWorkflowSandbox: false) != .sandboxVM)
    }

    @Test
    func shellExit127_failsTheStepAsCommandNotFound() async {
        let spec = ToolNodeSpec(tool: ToolRef(name: "shell_run"))
        let node = WorkflowNode(
            id: "download", name: "Download", kind: .tool(spec),
            input: .object(["command": "yt-dlp {{input.url}}"]), outputSchema: .object([:]))
        let input: JSONValue = .object(["url": .string("https://example.com/v")])
        let context = WorkflowNodeContext(
            runID: UUID(), workflowID: UUID(), workflowName: "Downloader", node: node, input: input,
            bindings: BindingContext(input: input), model: nil, secretAccounts: [:],
            caller: WorkflowCaller(kind: .user), workspace: WF.tempDir(), attempt: 1, timeout: 60)
        let runtime = ToolNodeExecutor.Runtime(
            resolve: { name in
                ToolNodeExecutor.Resolved(
                    spec: Tool(type: "function", function: ToolFunction(name: name, description: name, parameters: nil)),
                    outputSchema: nil)
            },
            execute: { name, _, _ in
                ToolEnvelope.success(
                    tool: name,
                    result: ["exit_code": 127, "stdout": "", "stderr": "sh: yt-dlp: not found\n", "cwd": "/workspace/x"])
            })
        do {
            _ = try await ToolNodeExecutor.run(spec: spec, context: context, runtime: runtime)
            Issue.record("expected a failure")
        } catch let failure as RecordedNodeFailure {
            guard case WorkflowNodeError.toolFailed(let tool, let kind, let message, let retryable)? =
                failure.underlying as? WorkflowNodeError
            else {
                Issue.record("unexpected \(failure.underlying)")
                return
            }
            #expect(tool == "shell_run")
            #expect(kind == "command_not_found")
            #expect(message.contains("yt-dlp: not found"))
            #expect(message.contains("dependency"))
            #expect(!retryable)
            #expect(failure.toolCallRecords.count == 1)
        } catch {
            Issue.record("unexpected \(error)")
        }
        // A clean exit is not touched.
        #expect(
            ToolNodeExecutor.commandNotFoundFailure(
                tool: "shell_run", envelope: ToolEnvelope.success(tool: "shell_run", result: ["exit_code": 0])) == nil)
        #expect(
            ToolNodeExecutor.commandNotFoundFailure(
                tool: "file_write", envelope: ToolEnvelope.success(tool: "file_write", result: ["exit_code": 127])) == nil)
    }

    @Test
    func grantedPaths_comeFromFolderAndFileFieldsOfTheInputAndDialogs() {
        let schema = WF.object([
            "url": WF.string,
            "dest": .object(["type": .string("string"), "format": .string("folder")]),
            "cover": .object(["type": .string("string"), "format": .string("file")]),
            "note": WF.string,
        ])
        let dialog = WorkflowNode(
            id: "ask", name: "Ask",
            kind: .dialog(
                DialogSpec(
                    title: "Where?",
                    fields: [
                        DialogField(key: "out", label: "Folder", type: .folder),
                        DialogField(key: "name", label: "Name", type: .text),
                    ])))
        let def = WorkflowDefinition(inputSchema: schema, nodes: [dialog])
        let paths = WorkflowRunner.grantedPaths(
            input: .object([
                "url": .string("/not/a/granted/path"), "dest": .string("/Users/me/Movies"),
                "cover": .string("/Users/me/cover.jpg"), "note": .string("/etc"),
            ]),
            inputSchema: schema, definition: def,
            outputs: ["ask": .object(["out": .string("/Users/me/Downloads"), "name": .string("/tmp")])])
        #expect(
            Set(paths.map(\.path)) == ["/Users/me/Movies", "/Users/me/cover.jpg", "/Users/me/Downloads"])
    }

    @Test
    func formFields_mapFolderAndFileFormats_andDialogSchemasEmitThem() {
        let fields = WorkflowFormFields.fields(
            fromInputSchema: WF.object([
                "dest": .object(["type": .string("string"), "format": .string("folder")]),
                "cover": .object(["type": .string("string"), "format": .string("file")]),
            ]))
        #expect(fields.first { $0.key == "dest" }?.type == .folder)
        #expect(fields.first { $0.key == "cover" }?.type == .file)
        #expect(DialogFieldType.folder.schema(options: nil).objectValue?["format"] == .string("folder"))
        #expect(DialogFieldType.file.schema(options: nil).objectValue?["format"] == .string("file"))
        #expect(DialogFieldType.text.schema(options: nil).objectValue?["format"] == nil)
    }

    @Test
    func resolvePath_acceptsGrantedWorkflowPaths_andNothingElse() throws {
        let root = WF.tempDir()
        let granted = WF.tempDir()
        let file = granted.appendingPathComponent("out.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let other = WF.tempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: granted)
            try? FileManager.default.removeItem(at: other)
        }
        try ChatExecutionContext.$workflowGrantedPaths.withValue([granted]) {
            let resolved = try FolderToolHelpers.resolvePath(file.path, rootPath: root)
            #expect(resolved.standardized.path == file.standardized.path)
            let newFile = granted.appendingPathComponent("sub/new.txt").path
            #expect(try FolderToolHelpers.resolvePath(newFile, rootPath: root).path.hasSuffix("sub/new.txt"))
            #expect(throws: (any Error).self) {
                try FolderToolHelpers.resolvePath(other.appendingPathComponent("x").path, rootPath: root)
            }
        }
        // Without a workflow grant the same path is outside the root.
        #expect(throws: (any Error).self) {
            try FolderToolHelpers.resolvePath(file.path, rootPath: root)
        }
        // A granted file covers itself only.
        try ChatExecutionContext.$workflowGrantedPaths.withValue([file]) {
            _ = try FolderToolHelpers.resolvePath(file.path, rootPath: root)
            #expect(throws: (any Error).self) {
                try FolderToolHelpers.resolvePath(granted.appendingPathComponent("other.mp4").path, rootPath: root)
            }
        }
    }

    @Test
    func shellCommand_hostSharePathsAreMappedToTheVMMount() {
        let host = OsaurusPaths.containerWorkspace().standardized.path
        let command = "yt-dlp -o '\(host)/agents/wf-x/runs/r/out.mp4' https://example.com"
        #expect(ShellRunTool.mappingShareToVM(command) == "yt-dlp -o '/workspace/agents/wf-x/runs/r/out.mp4' https://example.com")
        #expect(ShellRunTool.mappingShareToVM("yt-dlp -o out.mp4 https://example.com") == "yt-dlp -o out.mp4 https://example.com")
    }

    @Test
    func sandboxToolRequestContext_resolvesToTheWorkflowIdentity() async {
        let environmentID = UUID()
        let context = WorkflowSandboxContext.forRun(environmentID: environmentID, runID: UUID())
        let resolved = await ChatExecutionContext.$workflowSandbox.withValue(context) {
            await SandboxToolRequestContext.resolve(fallbackAgentId: "default")
        }
        #expect(resolved.agentName == OsaurusPaths.workflowSandboxAgentName(environmentID: environmentID))
        #expect(resolved.agentId == resolved.agentName)
        #expect(resolved.agentUUID == nil)
        #expect(resolved.home == OsaurusPaths.inContainerAgentHome(resolved.agentName))
        #expect(resolved.config?.enabled == true)
        #expect(resolved.isRequestBound)
        #expect(context.inVMWorkingDirectory.hasPrefix(resolved.home + "/runs/"))
    }

    @Test
    func runner_putsASandboxRunWorkspaceUnderTheShare_andBindsTheSandbox() async {
        let template = WF.template(Self.definition())
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Downloader", template: template,
            caller: WorkflowCaller(kind: .test), input: .object(["url": .string("https://example.com/v")]))
        #expect(request.usesSandbox)
        let seen = NodeContextBox()
        // No VM in the test harness: provisioning is a no-op here.
        let previous = await MainActor.run { WorkflowSandboxEnvironment.shared.provisionIdentity }
        await MainActor.run { WorkflowSandboxEnvironment.shared.provisionIdentity = { _ in } }
        let run = await WorkflowRunner(
            request: request,
            executor: ClosureExecutor { context, _ in
                await seen.set(context)
                return WorkflowNodeOutcome(output: .object(["text": .string("ok")]))
            }
        ).execute()
        await MainActor.run { WorkflowSandboxEnvironment.shared.provisionIdentity = previous }
        #expect(run.status == .completed, Comment(rawValue: String(describing: run.error)))
        let context = await seen.value
        let expectedWorkspace = OsaurusPaths.workflowSandboxRunWorkspace(environmentID: template.id, runID: request.runID)
        #expect(context?.workspace.standardized.path == expectedWorkspace.standardized.path)
        #expect(context?.sandbox?.environmentID == template.id)
        #expect(
            context?.sandbox?.inVMWorkingDirectory
                == OsaurusPaths.workflowSandboxRunWorkspaceInContainer(environmentID: template.id, runID: request.runID))
        try? FileManager.default.removeItem(at: OsaurusPaths.containerAgentDir(OsaurusPaths.workflowSandboxAgentName(environmentID: template.id)))
    }

    @Test
    func runner_withoutDependencies_doesNotUseTheSandbox() {
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Intake", template: WF.template(WF.intake()),
            caller: WorkflowCaller(kind: .test), input: .object(["client": .string("Ada")]))
        #expect(!request.usesSandbox)
    }

    @Test
    func shellSteps_runInTheSandbox_evenWithoutDependencies() {
        let shellOnly = Self.definition(dependencies: [])
        #expect(shellOnly.usesSandbox)
        #expect(shellOnly.hasSandboxSteps)
        #expect(!shellOnly.hasPythonNodes)
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: "Shell", template: WF.template(shellOnly),
            caller: WorkflowCaller(kind: .test), input: .object(["url": .string("x")]))
        #expect(request.usesSandbox)

        func agentic(_ tools: [ToolRef]) -> WorkflowNode {
            WorkflowNode(
                id: "agent", name: "Agent",
                kind: .inference(
                    InferenceSpec(modelSlot: "main", instructions: "go", mode: .agentic(tools: tools, maxSteps: 4))),
                input: .object([:]), outputSchema: .object([:]))
        }
        #expect(agentic([ToolRef(name: "shell_run")]).needsSandbox)
        // An MCP or plugin tool that happens to share the name is not Osaurus's shell.
        #expect(!agentic([ToolRef(name: "shell_run", server: "remote")]).needsSandbox)
        #expect(!agentic([ToolRef(name: "file_read")]).needsSandbox)
    }

    // MARK: - Commands that cannot work in the Linux sandbox

    private static let folderInput: JSONValue = .object([
        "type": .string("string"), "format": .string("folder"), "title": .string("Folder with SVGs"),
    ])

    private static func sandboxIssues(_ command: String, folderInput: Bool = false) -> [String] {
        var def = Self.definition(dependencies: [], steps: [Self.shellStep(command)])
        if folderInput {
            def.inputSchema = WF.object(["url": WF.string, "svgs": Self.folderInput], required: ["url", "svgs"])
        }
        return WorkflowValidator.validate(def, allowPlaceholders: false).map(\.message)
    }

    @Test
    func validator_flagsMacOnlyPrograms_whereACommandStarts() {
        for command in [
            #"cd in && for f in *.svg; do qlmanage -t -s 800 -o ../out "$f"; done"#,
            "sips -s format png a.svg --out a.png",
            "/usr/bin/sips -z 10 10 a.png",
            "ls *.svg | xargs osascript",
            "cat notes.txt | pbcopy",
            "find . -name '*.svg' -exec qlmanage -t {} \\;",
            "echo done\nopen out.png",
        ] {
            #expect(Self.sandboxIssues(command).contains { $0.contains("a macOS program") }, "\(command)")
        }
        #expect(WorkflowValidator.macOnlyProgram(in: "for f in *; do sips $f; done") == "sips")
        for command in [
            "echo 'open the file'", "python3 -c 'import opencv'", "rsvg-convert -o out.png in.svg",
            "ffmpeg -i in.mp4 out.mp3", "openssl rand -hex 4", "magick in.svg out.png",
        ] {
            #expect(!Self.sandboxIssues(command).contains { $0.contains("a macOS program") }, "\(command)")
        }
    }

    @Test
    func validator_flagsAMacPathAnywhereInACommand_butNotSandboxPaths() {
        let mac = Self.sandboxIssues(#"cd "/Users/strayrayz/Downloads/dinos" && rsvg-convert -o a.png a.svg"#)
        #expect(mac.contains { $0.contains("/Users/strayrayz/Downloads/dinos") }, "\(mac)")
        #expect(Self.sandboxIssues("cp /Volumes/Backup/a.svg in/").contains { $0.contains("folder on this Mac") })
        #expect(!Self.sandboxIssues("ls /workspace/agents/x && cat ~/notes.txt").contains { $0.contains("folder on this Mac") })
    }

    @Test
    func validator_flagsPickedAndDeclaredFoldersPassedToACommand() {
        let picked = Self.sandboxIssues("rsvg-convert {{input.svgs}}/a.svg", folderInput: true)
        #expect(picked.contains { $0.contains("{{input.svgs}}") && $0.contains("file_copy") }, "\(picked)")
        #expect(Self.sandboxIssues("ls {{folders.inbox}}").contains { $0.contains("{{folders.inbox}}") })
        // A plain text input is the command's own data.
        #expect(Self.sandboxIssues("yt-dlp -o out.mp4 {{input.url}}", folderInput: true).isEmpty)
    }

    @Test
    func validator_checksMapBodies_andRunsAndImportsSkipTheSandboxChecks() throws {
        let step: JSONValue = .object([
            "name": .string("Convert"), "kind": .string("tool"), "tool": .object(["name": .string("shell_run")]),
            "input": .object(["command": .string("sips -s format png {{item.name}}")]),
            "output_schema": .object([:]),
        ])
        let def = Self.definition(
            dependencies: [],
            steps: [
                WorkflowNode(
                    id: "download", name: "Each",
                    kind: .map(MapSpec(items: "{{input.url}}", step: step)))
            ])
        let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
        #expect(issues.contains { $0.nodeID == "download" && $0.message.contains("`sips`") }, "\(issues)")
        #expect(
            !WorkflowValidator.validate(def, allowPlaceholders: false, checkSandboxCommands: false)
                .contains { $0.message.contains("macOS program") })
    }

    @Test
    func validator_acceptsFilesCopiedInConvertedAndCopiedBack() {
        func mapCopy(_ id: String, items: String, destination: String) -> WorkflowNode {
            let step: JSONValue = .object([
                "name": .string("Copy"), "kind": .string("tool"), "tool": .object(["name": .string("file_copy")]),
                "input": .object(["source": .string("{{item.path}}"), "destination": .string(destination)]),
                "output_schema": .object([:]),
            ])
            return WorkflowNode(id: id, name: id, kind: .map(MapSpec(items: items, step: step)))
        }
        func search(_ id: String, path: String) -> WorkflowNode {
            WorkflowNode(
                id: id, name: id, kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_search"))),
                input: .object(["path": path, "target": "files", "pattern": "*.svg"]), outputSchema: .object([:]))
        }
        var def = WorkflowDefinition(
            inputSchema: WF.object(["svgs": Self.folderInput], required: ["svgs"]),
            nodes: [
                search("find", path: "{{input.svgs}}"),
                mapCopy("bring_in", items: "{{nodes.find.output.entries}}", destination: "{{run.workspace}}/in/{{item.name}}"),
                Self.shellStep("mkdir -p out && for f in in/*.svg; do rsvg-convert -o \"out/$(basename \"$f\" .svg).png\" \"$f\"; done", id: "convert"),
                search("found", path: "{{run.workspace}}/out"),
                mapCopy("deliver", items: "{{nodes.found.output.entries}}", destination: "{{input.svgs}}/png/{{item.name}}"),
            ],
            edges: [
                WorkflowEdge(from: "find", to: "bring_in"), WorkflowEdge(from: "bring_in", to: "convert"),
                WorkflowEdge(from: "convert", to: "found"), WorkflowEdge(from: "found", to: "deliver"),
            ],
            output: .object([:]))
        def.dependencies = [WorkflowDependency(manager: .apk, packages: ["librsvg"], binaries: ["rsvg-convert"])]
        let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
        #expect(issues.isEmpty, "\(issues.map(\.message))")
    }

    @Test
    func commandNotFound_namesAMacOnlyProgram() {
        let message = ToolNodeExecutor.commandNotFoundFailure(
            tool: "shell_run",
            envelope: ToolEnvelope.success(
                tool: "shell_run", result: ["exit_code": 127, "stderr": "sh: qlmanage: not found\n"]))
        #expect(message?.contains("`qlmanage` is a macOS program") == true, "\(message ?? "")")
        let other = ToolNodeExecutor.commandNotFoundFailure(
            tool: "shell_run",
            envelope: ToolEnvelope.success(tool: "shell_run", result: ["exit_code": 127, "stderr": "sh: yt-dlp: not found"]))
        #expect(other?.contains("macOS") == false)
    }
}

private actor NodeContextBox {
    var value: WorkflowNodeContext?
    func set(_ context: WorkflowNodeContext) { value = context }
}
