//
//  TeamSeederTests.swift
//  OsaurusCoreTests
//
//  The Onboarding agent first run's team: the bundled teammates and
//  default workflows, the developer-Mac signal, the Privacy Filter file,
//  and creating the team through `ConfigApplier`.
//

import AppKit
import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite("Team worker summaries")
struct TeamWorkerSummaryTests {
    @Test
    func filesWorkerSummary_namesKeepersLane_onlyBesideKeeper() {
        let line = "not for reading Downloads or Notes"
        #expect(!BuiltInWorker.files.summary.contains(line))
        #expect(!BuiltInWorker.files.summary(beside: [.planner, .courier, .scout]).contains(line))
        #expect(BuiltInWorker.files.summary(beside: [.keeper]).contains(line))
        #expect(BuiltInWorker.research.summary(beside: [.keeper]) == BuiltInWorker.research.summary)
    }
}

@Suite("Bundled team and default workflows")
@MainActor
struct BundledTeamTests {
    static let readOnlyTools: Set<String> = [
        "calendar_events", "reminders_fetch", "mail_list", "mail_read", "mail_search", "notes_search",
        "file_search", "file_read", "search_and_extract", "git_status", "git_diff", "git_log",
    ]

    private func entry(_ teammate: Teammate) throws -> AgentEntry {
        try #require(TeamSeeder.template(for: teammate)).agent
    }

    @Test
    func everyTeammate_parses_withItsFixedId_andAvatar() throws {
        for teammate in Teammate.allCases {
            let template = try #require(TeamSeeder.template(for: teammate))
            #expect(template.id == teammate.templateID)
            #expect(template.kind == .agent)
            #expect(template.agent.orchestratorSpawnable == true)
            #expect(template.agent.capabilities?.clarifyEnabled == true)
        }
        #expect(Teammate.allCases.map(\.avatar) == [.orange, .purple, .yellow, .red, .blue])
        #expect(Set(Teammate.allCases.map(\.avatar)).count == Teammate.allCases.count)
        #expect(!Teammate.allCases.contains { $0.avatar.rawValue == Agent.defaultAgentStockAvatar })
    }

    /// SwiftPM does not compile asset catalogs, so this reads the source
    /// catalog rather than the bundle.
    @Test
    func everyTeammateAvatarShipsItsArtwork() {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets.xcassets")
        for teammate in Teammate.allCases {
            let name = teammate.avatar.assetName
            let image = catalog.appendingPathComponent("\(name).imageset/\(name)@2x.png")
            #expect(NSImage(contentsOf: image) != nil, "\(teammate)")
        }
    }

    @Test
    func aRetiredCostumeId_readsAsTheTeammatesStockDino() {
        let costumes = ["trice-beret", "rex-purse", "bronto-scarf", "trice-backpack", "rex-mecha"]
        #expect(costumes.compactMap(AgentMascot.init(storedID:)) == Teammate.allCases.map(\.avatar))
        #expect(costumes.allSatisfy { AgentMascot(rawValue: $0) == nil })
        #expect(AgentMascot(storedID: "green") == .green)
        #expect(AgentMascot(storedID: "not-a-mascot") == nil)
    }

    @Test
    func teammateSwitches_matchTheTeamSettings() throws {
        let apps: [Teammate: [String]] = [
            .planner: ["calendar", "reminders"], .courier: ["mail"], .keeper: ["notes"], .scout: [], .builder: [],
        ]
        for teammate in Teammate.allCases {
            let caps = try #require(try entry(teammate).capabilities)
            #expect(caps.appleApps == apps[teammate], "\(teammate)")
            #expect(caps.webSearchEnabled == (teammate == .scout), "only Scout has the web")
            #expect(caps.memoryEnabled == (teammate == .planner || teammate == .builder), "\(teammate)")
            #expect(caps.relayEnabled == false)
            #expect(caps.selfSchedulingEnabled == false)
            #expect(caps.searchMemoryEnabled == false)
            #expect(caps.redactionToolsEnabled == false, "Keeper's redaction is a discovery")
            #expect(caps.computerUseEnabled == false && caps.browserUseEnabled == false)
            #expect(caps.applescriptEnabled == false && caps.calculatorEnabled == false)
            #expect(try entry(teammate).subagents?.enabled == false)
        }
        let keeper = try entry(.keeper)
        #expect(keeper.workingFolder == .value("~/Downloads"))
        #expect(keeper.workingFolderReadOnly == true)
        let builder = try entry(.builder)
        #expect(builder.sandbox?.enabled == true)
        #expect(builder.sandbox?.networkEnabled == false)
        #expect(builder.sandbox?.pluginCreate == false)
        #expect(builder.sandbox?.backgroundProcessEnabled == false)
        #expect(builder.skills == .null, "Builder sees every skill")
        #expect(try entry(.planner).skills == .value([]))
    }

    @Test
    func routingLines_openWithTheDomain_andSayWhatTheyAreNotFor() throws {
        #expect(try entry(.keeper).description?.hasPrefix("Files in Downloads and the Notes app.") == true)
        #expect(try entry(.keeper).description?.contains("Not for writing, editing, or moving files") == true)
        #expect(try entry(.planner).description?.hasPrefix("Calendar and reminders.") == true)
        #expect(try entry(.courier).description?.hasPrefix("Email in Mail") == true)
        #expect(try entry(.scout).description?.hasPrefix("The web.") == true)
        #expect(try entry(.builder).description?.hasPrefix("Code in a project folder.") == true)
        for teammate in Teammate.allCases {
            #expect(try entry(teammate).description?.contains("Not for") == true, "\(teammate)")
        }
    }

    @Test
    func sevenDefaultWorkflows_eachSmall_readOnly_andKeyedToTeammatesByUUID() throws {
        let workflows = TeamSeeder.bundledDefaultWorkflows()
        #expect(
            workflows.map(\.name) == [
                "Morning Brief", "Meeting Prep", "Mail Triage", "New Download", "End of Day", "Research Brief",
                "Repo Digest",
            ]
        )
        let teammateIDs = Set(Teammate.allCases.map(\.templateID.uuidString))
        for template in workflows {
            let def = try #require(template.workflow, "\(template.name)")
            #expect(def.nodes.count <= 6, "\(template.name) has \(def.nodes.count) nodes")
            #expect(template.formatVersion == 5, "\(template.name)")
            let refs = def.nodes.flatMap(\.calledTools)
            #expect(!refs.isEmpty)
            for ref in refs {
                let agent = try #require(ref.agent, "\(template.name): \(ref.name) names no teammate")
                #expect(teammateIDs.contains(agent), "\(template.name): \(agent) is not a teammate UUID")
                #expect(Self.readOnlyTools.contains(ref.name), "\(template.name) calls \(ref.name)")
                if let app = AppleApp.app(forTool: ref.name) {
                    let teammate = try #require(Teammate.teammate(forTemplateID: UUID(uuidString: agent)))
                    let apps = try entry(teammate).capabilities?.appleApps ?? []
                    #expect(apps.contains(app.rawValue), "\(template.name): \(teammate) lacks \(app)")
                }
            }
            #expect(def.modelSlots.map(\.locality) == [.localOnly], "\(template.name)")
            let required = def.inputSchema.objectValue?["required"]?.arrayValue ?? []
            #expect(required.isEmpty == (template.name != "Research Brief"), "\(template.name)")
        }
    }

    @Test
    func teamResources_stayOutOfTheTemplateGallery() {
        let builtInIDs = Set(TemplateStore.shared.builtIn.map(\.id))
        for teammate in Teammate.allCases { #expect(!builtInIDs.contains(teammate.templateID)) }
        for template in TeamSeeder.bundledDefaultWorkflows() { #expect(!builtInIDs.contains(template.id)) }
    }

    @Test
    func repoDigest_onlyOnADeveloperMac_andTheWriterAllowsTheCloud_offALocalBrain() throws {
        let plain = TeamSeeder.defaultWorkflowTemplates(.init(developerMac: false, brainIsLocal: true))
        #expect(plain.count == 6)
        #expect(!plain.contains { $0.id == TeamSeeder.repoDigestTemplateID })
        #expect(TeamSeeder.defaultWorkflowTemplates(.init(developerMac: true, brainIsLocal: true)).count == 7)
        let cloud = TeamSeeder.defaultWorkflowTemplates(.init(developerMac: false, brainIsLocal: false))
        for template in cloud {
            #expect(try #require(template.workflow).modelSlots.map(\.locality) == [.cloudAllowed])
        }
        #expect(TeamSeeder.teammates(developerMac: false) == [.planner, .courier, .keeper, .scout])
        #expect(TeamSeeder.teammates(developerMac: true).last == .builder)
    }

    /// Bundles name teammates by these raw values; the CLI checks them
    /// against its own copy of the list.
    @Test
    func bundleTeammateNames_matchTheTeam() {
        #expect(Teammate.allCases.map(\.rawValue) == BundleTeammates.names)
    }

    @Test
    func aBundleExclusion_dropsItsTeammates_andTheWorkflowsThatRunAsThem() throws {
        let noKeeper = TeamSeeder.Options(developerMac: true, brainIsLocal: true, excludedTeammates: .names(["keeper"]))
        #expect(noKeeper.teammates == [.planner, .courier, .scout, .builder])
        let names = TeamSeeder.defaultWorkflowTemplates(noKeeper).map(\.name)
        #expect(names == ["Morning Brief", "Mail Triage", "End of Day", "Research Brief", "Repo Digest"])

        let noPlannerOrScout = TeamSeeder.Options(
            developerMac: false, brainIsLocal: true, excludedTeammates: .names(["planner", "scout"]))
        #expect(noPlannerOrScout.teammates == [.courier, .keeper])
        #expect(TeamSeeder.defaultWorkflowTemplates(noPlannerOrScout).map(\.name) == ["Mail Triage", "New Download"])

        let none = TeamSeeder.Options(developerMac: true, brainIsLocal: true, excludedTeammates: .all)
        #expect(none.teammates.isEmpty)
        #expect(TeamSeeder.defaultWorkflowTemplates(none).isEmpty)

        let everyone = TeamSeeder.Options(developerMac: false, brainIsLocal: true)
        #expect(everyone.teammates == TeamSeeder.teammates(developerMac: false))
        #expect(TeamSeeder.defaultWorkflowTemplates(everyone).count == 6)
    }
}

@Suite("Developer Mac signal")
struct DeveloperMacSignalTests {
    private func probe(app: Bool = false, files: Set<String> = []) -> DeveloperMacSignal.Probe {
        DeveloperMacSignal.Probe(
            appInstalled: { _ in app },
            fileExists: { files.contains($0) },
            homeDirectory: "/Users/u"
        )
    }

    @Test
    func anyOfXcode_theCommandLineTools_orAGitConfig_isADeveloperMac() {
        #expect(!DeveloperMacSignal.isDeveloperMac(probe: probe()))
        #expect(DeveloperMacSignal.isDeveloperMac(probe: probe(app: true)))
        #expect(DeveloperMacSignal.isDeveloperMac(probe: probe(files: ["/Library/Developer/CommandLineTools"])))
        #expect(DeveloperMacSignal.isDeveloperMac(probe: probe(files: ["/Users/u/.gitconfig"])))
    }
}

@Suite("Team seeding", .serialized)
@MainActor
struct TeamSeedingTests {
    private func withIsolatedTeam(_ body: @MainActor @Sendable (URL) async throws -> Void) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("team-seed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await Self.removeTeammates()
            do {
                try await TeamSeeder.$workingFolderOverrideForTests.withValue(folder.path) { try await body(folder) }
            } catch {
                await Self.removeTeammates()
                throw error
            }
            await Self.removeTeammates()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func removeTeammates() async {
        for agent in AgentManager.shared.agents where agent.teammate != nil || agent.name.hasPrefix("Planner") {
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    private func teammates() -> [Agent] { AgentManager.shared.agents.filter { $0.teammate != nil } }

    @Test
    func createTeam_makesEachTeammate_once_withItsIdAvatarAndPoolSeat() async throws {
        try await withIsolatedTeam { folder in
            let created = await TeamSeeder.createTeam(developerMac: false)
            #expect(created.map(\.name) == ["Planner", "Courier", "Keeper", "Scout"])
            for agent in created {
                let teammate = try #require(agent.teammate)
                #expect(agent.avatar == teammate.avatar.rawValue)
                #expect(agent.sourceTemplateName == teammate.rawValue.capitalized)
                #expect(
                    agent.chatQuickActions?.map(\.prompt)
                        == TeamSeeder.template(for: teammate)?.quickActions?.map(\.prompt)
                )
                #expect((agent.chatQuickActions?.count ?? 0) >= 3)
            }
            let keeper = try #require(created.first { $0.teammate == .keeper })
            #expect(keeper.settings.workingFolderReadOnly)
            #expect(keeper.workingFolderPath == folder.path)
            #expect(keeper.settings.enabledAppleApps == [.notes])
            let pool = Set(SubagentConfigurationStore.load()?.spawnableAgentIDs ?? [])
            #expect(created.allSatisfy { pool.contains($0.id) } == true)

            #expect(await TeamSeeder.createTeam(developerMac: false).isEmpty, "a teammate is made once")
            let withBuilder = await TeamSeeder.createTeam(developerMac: true)
            #expect(withBuilder.map(\.teammate) == [.builder])
        }
    }

    @Test
    func createTeam_isCreditedToTheTeammateTemplates_inConfigurationHistory() async throws {
        try await withIsolatedTeam { _ in
            let database = ConfigHistoryDatabase()
            try database.openInMemory()
            try await ConfigHistoryRecorder.$databaseOverride.withValue(database) {
                #expect(await TeamSeeder.createTeam(developerMac: false).count == 4)
                let rows = try database.list(limit: 10)
                #expect(
                    rows.contains { $0.caller == .templateInstall(templateId: "planner, courier, keeper, scout") },
                    "\(rows.map(\.caller))")
            }
        }
    }

    @Test
    func aRenamedTeammate_stillCounts_andATakenName_neverPatchesSomeoneElsesAgent() async throws {
        try await withIsolatedTeam { _ in
            let mine = AgentManager.shared.create(name: "Planner", description: "Mine", systemPrompt: "My own prompt")
            let created = await TeamSeeder.createTeam(developerMac: false)
            let planner = try #require(created.first { $0.teammate == .planner })
            #expect(planner.name == "Planner 2")
            let untouched = try #require(AgentManager.shared.agent(for: mine.id))
            #expect(untouched.systemPrompt == "My own prompt")
            #expect(untouched.teammate == nil)

            var renamed = planner
            renamed.name = "My Day"
            AgentManager.shared.update(renamed)
            #expect(await TeamSeeder.createTeam(developerMac: false).isEmpty)
        }
    }

    @Test
    func seedFreshInstall_runsOnce_andADeletedTeammateIsNeverRecreated() async throws {
        try await withIsolatedTeam { folder in
            let defaults = try #require(UserDefaults(suiteName: "team-seed-\(UUID().uuidString)"))
            PrivacyFilterStore.setOverrideDirectory(folder)
            defer { PrivacyFilterStore.setOverrideDirectory(nil) }
            let before = Set(InstalledWorkflowStore.shared.workflows.map(\.id))

            let first = await TeamSeeder.seedFreshInstall(
                .init(developerMac: false, brainIsLocal: true),
                defaults: defaults
            )
            #expect(first.count == 4)
            #expect(TeamSeeder.hasSeeded(defaults))

            let installed = InstalledWorkflowStore.shared.workflows.filter { !before.contains($0.id) }
            #expect(Set(installed.map(\.name)).isSuperset(of: ["Morning Brief", "Research Brief", "New Download"]))
            #expect(!installed.contains { $0.templateID == TeamSeeder.repoDigestTemplateID })
            #expect(installed.allSatisfy { $0.orchestratorVisible })

            let filter = try #require(PrivacyFilterStore.load())
            #expect(filter.enabled)
            #expect(!filter.aiDetectionEnabled)
            #expect(!filter.alwaysApproveByDefault)

            let scout = try #require(first.first { $0.teammate == .scout })
            _ = await AgentManager.shared.delete(id: scout.id)
            #expect(
                await TeamSeeder.seedFreshInstall(.init(developerMac: false, brainIsLocal: true), defaults: defaults)
                    .isEmpty
            )
            #expect(!teammates().contains { $0.teammate == .scout })

            for workflow in installed { InstalledWorkflowStore.shared.delete(id: workflow.id) }
        }
    }

    @Test
    func seedFreshInstall_withABundleExclusion_leavesThoseTeammatesAndTheirWorkflowsOut() async throws {
        try await withIsolatedTeam { folder in
            let defaults = try #require(UserDefaults(suiteName: "team-seed-\(UUID().uuidString)"))
            PrivacyFilterStore.setOverrideDirectory(folder)
            defer { PrivacyFilterStore.setOverrideDirectory(nil) }
            let before = Set(InstalledWorkflowStore.shared.workflows.map(\.id))

            let created = await TeamSeeder.seedFreshInstall(
                .init(developerMac: false, brainIsLocal: true, excludedTeammates: .names(["keeper"])),
                defaults: defaults)
            #expect(created.compactMap(\.teammate) == [.planner, .courier, .scout])
            #expect(!teammates().contains { $0.teammate == .keeper })
            let installed = InstalledWorkflowStore.shared.workflows.filter { !before.contains($0.id) }
            #expect(!installed.contains { $0.name == "New Download" || $0.name == "Meeting Prep" })
            #expect(installed.contains { $0.name == "Morning Brief" })
            for workflow in installed { InstalledWorkflowStore.shared.delete(id: workflow.id) }
        }
    }

    @Test
    func seedFreshInstall_excludingAll_makesNoTeamAndNoWorkflows_butStillWritesThePrivacyFilter() async throws {
        try await withIsolatedTeam { folder in
            let defaults = try #require(UserDefaults(suiteName: "team-seed-\(UUID().uuidString)"))
            PrivacyFilterStore.setOverrideDirectory(folder)
            defer { PrivacyFilterStore.setOverrideDirectory(nil) }
            let before = Set(InstalledWorkflowStore.shared.workflows.map(\.id))

            let created = await TeamSeeder.seedFreshInstall(
                .init(developerMac: true, brainIsLocal: true, excludedTeammates: .all), defaults: defaults)
            #expect(created.isEmpty)
            #expect(teammates().isEmpty)
            #expect(InstalledWorkflowStore.shared.workflows.allSatisfy { before.contains($0.id) })
            #expect(PrivacyFilterStore.load()?.enabled == true)
            #expect(TeamSeeder.hasSeeded(defaults), "a later launch does not seed the team after all")
        }
    }

    /// Bookmarking Downloads raises macOS's dialog, so the seed records the
    /// path alone and Keeper's Downloads ask adds the bookmark. The grant is
    /// shown on a temporary folder, which macOS does not guard.
    @Test
    func theSeedLeavesAGuardedFolderUnbookmarked_untilTheFirstRunReadsIt() async throws {
        #expect(TeamSeeder.guardedFolder("~/Downloads") != nil)
        #expect(TeamSeeder.guardedFolder("~/Documents/") != nil)
        #expect(TeamSeeder.guardedFolder(NSTemporaryDirectory()) == nil)
        let downloads = try #require(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
            .standardizedFileURL.path
        try await withIsolatedTeam { folder in
            let created = await TeamSeeder.$workingFolderOverrideForTests.withValue(downloads) {
                await TeamSeeder.create([.keeper], bookmarkingGuardedFolders: false)
            }
            let keeper = try #require(created.first)
            #expect(keeper.workingFolderPath == downloads)
            #expect(keeper.workingFolderBookmark == nil)
            #expect(keeper.settings.workingFolderReadOnly)

            AgentManager.shared.updateWorkingFolder(for: keeper.id, bookmark: nil, path: folder.path)
            TeamSeeder.bookmarkWaitingFolders(at: folder)
            #expect(AgentManager.shared.agent(for: keeper.id)?.workingFolderBookmark != nil)
            #expect(AgentManager.shared.agent(for: keeper.id)?.workingFolderPath == folder.path)
        }
    }

    /// The schema a wrapper run sees: a `.delegation` session in the
    /// teammate's folder. Domain tools are the app, folder, and web tools the
    /// budget counts; the rest is the baseline every teammate carries
    /// (`capabilities`, `get_current_time`), plus Scout's `share_artifact`.
    private static func wrapperSchema(_ agent: Agent, folder: URL) -> Set<String> {
        let mode: ExecutionMode =
            agent.workingFolderPath == nil
            ? .none
            : .hostFolder(
                FolderContext(
                    rootPath: folder,
                    projectType: .unknown,
                    tree: "./\n",
                    manifest: nil,
                    gitStatus: nil,
                    isGitRepo: false
                )
            )
        return ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
            Set(SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: mode).map(\.function.name))
        }
    }

    @Test
    func eachTeammatesRealSchema_staysWithinTheToolBudget() async throws {
        FolderToolManager.shared.ensureFolderToolsRegistered()
        try await withIsolatedTeam { folder in
            let created = await TeamSeeder.createTeam(developerMac: false)
            @MainActor func schema(_ teammate: Teammate) throws -> Set<String> {
                Self.wrapperSchema(try #require(created.first { $0.teammate == teammate }), folder: folder)
            }
            let baseline: Set<String> = ["capabilities", "get_current_time"]
            let domain: [Teammate: Set<String>] = [
                .planner: AppleApp.toolNames(for: [.calendar, .reminders]),
                .courier: AppleApp.toolNames(for: [.mail]),
                // `file_read` lists a folder; there is no separate `file_tree`.
                .keeper: AppleApp.toolNames(for: [.notes]).union(["file_read", "file_search"]),
                .scout: ["web_search", "search_and_extract", "share_artifact"],
            ]
            #expect(domain.mapValues(\.count) == [.planner: 13, .courier: 9, .keeper: 9, .scout: 3])
            for (teammate, tools) in domain {
                let real = try schema(teammate)
                #expect(real == tools.union(baseline), "\(teammate): \(real.sorted())")
                #expect(real.subtracting(baseline).count <= 13, "\(teammate) is over the day-one budget")
            }
            #expect(try schema(.planner).count == 15, "Planner's real schema")
            #expect(!(try schema(.keeper)).contains { ToolRegistry.redactionToolNames.contains($0) })
            #expect(!(try schema(.courier)).contains { $0.hasPrefix("messages_") }, "Messages is a discovery")

            var courier = try #require(created.first { $0.teammate == .courier })
            courier.settings.enabledAppleApps = [.mail, .messages]
            AgentManager.shared.update(courier)
            let connected = try schema(.courier).subtracting(baseline)
            #expect(connected == AppleApp.toolNames(for: [.mail, .messages]))
            #expect(connected.count == 14, "Courier with Messages connected")

            var keeper = try #require(created.first { $0.teammate == .keeper })
            keeper.settings.redactionToolsEnabled = true
            AgentManager.shared.update(keeper)
            let detecting = try schema(.keeper).subtracting(baseline)
            #expect(detecting == domain[.keeper]!.union(["detect_pii"]), "redact_file writes, so read-only drops it")
        }
    }

    @Test
    func privacyFilterFile_isWrittenOnlyWhenNoneExists_andFreshInstallStaysOff() throws {
        #expect(PrivacyFilterConfiguration.freshInstall().enabled == false)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PrivacyFilterStore.setOverrideDirectory(folder)
        defer {
            PrivacyFilterStore.setOverrideDirectory(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        var chosen = PrivacyFilterConfiguration()
        chosen.enabled = false
        PrivacyFilterStore.save(chosen)
        TeamSeeder.writePrivacyFilterIfMissing()
        #expect(PrivacyFilterStore.load()?.enabled == false, "a choice already on disk stands")
    }
}
