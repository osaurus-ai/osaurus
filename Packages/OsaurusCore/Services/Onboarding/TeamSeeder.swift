//
//  TeamSeeder.swift
//  osaurus
//
//  Creates the day-one team and installs its default workflows. A fresh
//  install is seeded once, at the end of the onboarding window; a flag in
//  UserDefaults records it, so a teammate the person deletes is never
//  recreated. Settings' Create Starter Agents calls `createTeam` to make
//  the same team on purpose.
//
//  Teammates go through the declarative `ConfigApplier` path like any
//  template-made agent. What the declarative entry cannot carry (the fixed
//  template id that workflow steps and worker superseding key on, and the
//  avatar) is set on the created agent afterwards.
//

import Foundation
import OsaurusRepository

@MainActor
public enum TeamSeeder {
    public static let seededDefaultsKey = "onboardingTeamSeeded"

    /// Repo Digest reads Builder's project, so it ships only with Builder.
    nonisolated static let repoDigestTemplateID = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000207")!

    static let defaultWorkflowResourceNames = [
        "default-workflow-morning-brief",
        "default-workflow-meeting-prep",
        "default-workflow-mail-triage",
        "default-workflow-new-download",
        "default-workflow-end-of-day",
        "default-workflow-research-brief",
        "default-workflow-repo-digest",
    ]

    public struct Options: Sendable, Equatable {
        /// Builder and Repo Digest come only with a developer Mac.
        public var developerMac: Bool
        /// The writing steps stay on this Mac when the brain does. On a
        /// provider the person chose, a local-only slot would block every
        /// run, so the slot allows the cloud and setup says where it goes.
        public var brainIsLocal: Bool
        /// Teammates an installed bundle left out. The default workflows
        /// that use them are left out too.
        public var excludedTeammates: TeammateExclusion

        public init(developerMac: Bool, brainIsLocal: Bool, excludedTeammates: TeammateExclusion = .none) {
            self.developerMac = developerMac
            self.brainIsLocal = brainIsLocal
            self.excludedTeammates = excludedTeammates
        }

        /// The teammates the seed creates on this Mac.
        var teammates: [Teammate] {
            TeamSeeder.teammates(developerMac: developerMac).filter { !excludedTeammates.excludes($0.rawValue) }
        }
    }

    /// Test seam: replaces a teammate's working folder (Keeper's Downloads),
    /// so a test never asks for access to the real one.
    @TaskLocal static var workingFolderOverrideForTests: String?

    public static func hasSeeded(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seededDefaultsKey)
    }

    /// The fresh-install seed: the team, the default workflows, and the
    /// Privacy Filter file. Returns the teammates it created; empty when
    /// this install was seeded before.
    @discardableResult
    public static func seedFreshInstall(_ options: Options, defaults: UserDefaults = .standard) async -> [Agent] {
        guard !hasSeeded(defaults) else { return [] }
        let created = await create(options.teammates, bookmarkingGuardedFolders: false)
        installDefaultWorkflows(options)
        writePrivacyFilterIfMissing()
        defaults.set(true, forKey: seededDefaultsKey)
        return created
    }

    /// The teammates for this Mac, in roster order.
    nonisolated static func teammates(developerMac: Bool) -> [Teammate] {
        Teammate.allCases.filter { $0 != .builder || developerMac }
    }

    /// Creates each teammate that has no agent yet, on the Orchestrator's
    /// model (`ConfigApplier`'s create default). A name someone already uses
    /// gets a number, so an existing agent is never patched into a teammate.
    @discardableResult
    public static func createTeam(developerMac: Bool) async -> [Agent] {
        await create(teammates(developerMac: developerMac))
    }

    /// Creates `teammates` with each working folder at `workingFolder`, so
    /// an eval run never reads the person's Downloads.
    @discardableResult
    public static func create(_ teammates: [Teammate], workingFolder: String) async -> [Agent] {
        await $workingFolderOverrideForTests.withValue(workingFolder) { await create(teammates) }
    }

    /// Creates each of `teammates` that has no agent yet. A discovery adds
    /// one teammate this way without bringing back one that was deleted.
    ///
    /// Bookmarking a folder macOS guards raises its dialog. The fresh-install
    /// seed passes `bookmarkingGuardedFolders: false`: such a teammate gets
    /// the path alone, and `bookmarkWaitingFolders` adds the bookmark when
    /// the first run asks for that folder.
    @discardableResult
    static func create(_ teammates: [Teammate], bookmarkingGuardedFolders: Bool = true) async -> [Agent] {
        let manager = AgentManager.shared
        let present = Set(manager.agents.compactMap(\.teammate))
        var takenSlugs = Set(manager.agents.map { Template.slug(for: $0.name) })
        var planned: [(teammate: Teammate, name: String)] = []
        var document = OsaurusConfigDocument()
        document.version = 1
        var entries: [AgentEntry] = []
        var slugs: [String] = []
        var waitingFolders: [String: String] = [:]
        for teammate in teammates where !present.contains(teammate) {
            guard let template = template(for: teammate), var entry = template.document().agents?.first else {
                continue
            }
            slugs.append(template.slug)
            let name = Template.availableName(for: entry.name, takenSlugs: takenSlugs)
            takenSlugs.insert(Template.slug(for: name))
            entry.name = name
            entry.sourceTemplate = template.name
            if let folder = workingFolderOverrideForTests, entry.workingFolder.isSpecified {
                entry.workingFolder = .value(folder)
            }
            if !bookmarkingGuardedFolders, case .value(let folder) = entry.workingFolder,
                let guarded = guardedFolder(folder)
            {
                waitingFolders[name] = guarded
                entry.workingFolder = .absent
            }
            entries.append(entry)
            planned.append((teammate, name))
        }
        guard !entries.isEmpty else { return [] }
        document.agents = entries
        _ = await ConfigApplier.apply(
            document: document, prune: false, caller: .templateInstall(templateId: slugs.joined(separator: ", ")))

        var created: [Agent] = []
        for (teammate, name) in planned {
            guard
                var agent = manager.agents.first(where: {
                    !$0.isBuiltIn && $0.name.caseInsensitiveCompare(name) == .orderedSame
                })
            else { continue }
            agent.sourceTemplateID = teammate.templateID
            agent.avatar = teammate.avatar.rawValue
            // Quick actions ride on the template envelope, not the config
            // schema.
            agent.chatQuickActions = template(for: teammate)?.quickActions
            if let path = waitingFolders[name] {
                agent.workingFolderPath = path
                agent.workingFolderBookmark = nil
            }
            manager.update(agent)
            created.append(manager.agent(for: agent.id) ?? agent)
        }
        return created
    }

    /// The folder's expanded path when macOS asks before an app reads it:
    /// Downloads, Documents, or Desktop.
    nonisolated static func guardedFolder(_ raw: String) -> String? {
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        let fm = FileManager.default
        let guarded: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .documentDirectory, .desktopDirectory]
        return guarded.contains { fm.urls(for: $0, in: .userDomainMask).first?.standardizedFileURL.path == path }
            ? path : nil
    }

    /// Bookmarks `folder` on each teammate that has its path and no
    /// bookmark, once the person has let Osaurus read it.
    static func bookmarkWaitingFolders(at folder: URL) {
        let path = folder.standardizedFileURL.path
        let manager = AgentManager.shared
        let waiting = manager.agents.filter { agent in
            agent.teammate != nil && agent.workingFolderBookmark == nil
                && agent.workingFolderPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path
        }
        guard !waiting.isEmpty,
            let bookmark = FolderContextService.makeSecurityScopedBookmark(for: URL(fileURLWithPath: path, isDirectory: true))
        else { return }
        for agent in waiting {
            manager.updateWorkingFolder(for: agent.id, bookmark: bookmark, path: path)
        }
    }

    /// Installs the default workflows, off until asked: visible to the
    /// Orchestrator, with no automation.
    static func installDefaultWorkflows(_ options: Options) {
        let store = InstalledWorkflowStore.shared
        for template in defaultWorkflowTemplates(options) {
            do {
                let installed = try store.install(template, bindings: InstallBindings())
                if !installed.orchestratorVisible {
                    try store.setOrchestratorVisible(true, id: installed.id)
                }
            } catch {
                print("[Osaurus] Default workflow \(template.name) did not install: \(error)")
            }
        }
    }

    /// The default workflows for this Mac, with the writer slot's locality
    /// set from where the brain runs. A workflow whose steps run as a
    /// teammate the seed leaves out is left out with it: those steps fail
    /// without their agent.
    static func defaultWorkflowTemplates(_ options: Options) -> [Template] {
        let missing = Set(Teammate.allCases).subtracting(options.teammates)
        return bundledDefaultWorkflows()
            .filter { $0.id != repoDigestTemplateID || options.developerMac }
            .filter { template in missing.allSatisfy { !uses($0, template) } }
            .map { options.brainIsLocal ? $0 : allowingCloudWriter($0) }
    }

    /// Whether a workflow names the teammate as a step's agent. Steps refer
    /// to teammates by template id.
    static func uses(_ teammate: Teammate, _ template: Template) -> Bool {
        guard let text = try? template.jsonString() else { return false }
        return text.uppercased().contains(teammate.templateID.uuidString)
    }

    static func allowingCloudWriter(_ template: Template) -> Template {
        guard case .workflow(var def) = template.payload else { return template }
        for index in def.modelSlots.indices where def.modelSlots[index].locality == .localOnly {
            def.modelSlots[index].locality = .cloudAllowed
        }
        var copy = template
        copy.payload = .workflow(def)
        return copy.sealed()
    }

    /// The first-run Privacy Filter: on, regex layer only, review sheet on.
    /// Written only when no file exists, so a choice already made stands.
    static func writePrivacyFilterIfMissing() {
        guard PrivacyFilterStore.load() == nil else { return }
        var config = PrivacyFilterConfiguration.freshInstall()
        config.enabled = true
        config.aiDetectionEnabled = false
        config.alwaysApproveByDefault = false
        PrivacyFilterStore.save(config)
    }

    // MARK: - Bundled resources

    static func template(for teammate: Teammate) -> Template? {
        loadBundled(teammate.resourceName)
    }

    static func bundledDefaultWorkflows() -> [Template] {
        defaultWorkflowResourceNames.compactMap(loadBundled)
    }

    /// Bundled team resources live outside `Templates/` and without
    /// `-template-` in their names, so the template gallery does not list
    /// them for installs that never get the team.
    static func loadBundled(_ name: String) -> Template? {
        let url =
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Team")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8),
            let template = try? Template.parse(text)
        else {
            assertionFailure("Bundled team resource failed to load: \(name)")
            return nil
        }
        return template
    }
}
