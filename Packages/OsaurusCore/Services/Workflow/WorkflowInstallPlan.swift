//
//  WorkflowInstallPlan.swift
//  osaurus
//
//  What installing a workflow takes on this Mac, split into what Osaurus
//  can do by itself (download a model, set up the sandbox, install the
//  packages its steps use) and what only the person can answer (a key, a
//  folder, which agent a step asks). The guided installer, its toast and
//  the Installing row on Home all take their words from here.
//
//  Pure core (`make`) so tests need no live services; `live` resolves the
//  download sources and sizes first.
//

import Foundation

struct WorkflowInstallPlan: Equatable, Sendable {

    enum Work: Codable, Equatable, Sendable {
        /// A chat model from Hugging Face.
        case chatModel(repoId: String)
        /// An image or video bundle from the image catalog.
        case mediaModel(MediaModelSource)
        /// The Osaurus sandbox that shell, Python and package steps run in.
        case sandbox
        /// Packages installed into the workflow's own sandbox environment.
        case packages([WorkflowDependency])

        var isDownload: Bool {
            switch self {
            case .chatModel, .mediaModel: return true
            case .sandbox, .packages: return false
            }
        }
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var work: Work
        /// Plain words: "Image model".
        var title: String
        /// The technical name, shown under Details.
        var detail: String
        /// What the installer says while it works on this.
        var activity: String
        var sizeBytes: Int64?
        /// The `SetupItem.id`s this clears once done.
        var covers: [String]
    }

    /// Where a slot's suggested chat model downloads from.
    struct ChatSource: Equatable, Sendable {
        var repoId: String
        var sizeBytes: Int64?
    }

    /// Everything `make` reads from the machine, injectable for tests.
    struct Inputs {
        /// The download for a slot's suggested model, or nil when it is
        /// here, names none, or does not come from Hugging Face.
        var chatSource: (ModelRequirement) -> ChatSource? = { _ in nil }
        var mediaOutcome: (MediaModelRequirement) -> MediaModelSourceResolver.Outcome = { _ in .unavailable }
        var sandboxStatus: ContainerStatus = .running
        var dependencyStatus: (WorkflowDependency) -> WorkflowDependencyStatus = { _ in .installed }
    }

    /// Done by Osaurus when the person presses Install, in order.
    var items: [Item]
    /// Suggested models a default model stands in for until they are here.
    /// Offered under Details, not installed by default.
    var optional: [Item]
    /// What only the person can answer, in report order.
    var questions: [SetupItem]

    var needsNothing: Bool { items.isEmpty && questions.isEmpty }

    /// The known download size of `items`.
    var totalBytes: Int64 { items.compactMap(\.sizeBytes).reduce(0, +) }

    /// A download whose size is not known yet.
    var sizeIsPartial: Bool { items.contains { $0.work.isDownload && $0.sizeBytes == nil } }

    /// Why the downloads would not fit, or nil. Unknown free space never
    /// blocks.
    func storageRefusal(freeBytes: Int64?) -> String? {
        guard let freeBytes else { return nil }
        return ModelDownloadService.storageRefusalMessage(neededBytes: totalBytes, freeBytes: freeBytes)
    }

    /// The setup steps the questions fall on, in the rail wizard's order.
    func questionSteps() -> [WorkflowSetupWizardView.Step] {
        let report = SetupReport(subjectId: UUID(), items: questions)
        let order: [WorkflowSetupWizardView.Step] = [
            .models, .secrets, .folders, .apps, .agents, .tools, .dependencies, .permissions,
        ]
        return order.filter { !$0.items(in: report).isEmpty }
    }

    /// The plan with `item` moved from `optional` into `items`.
    func including(_ id: String) -> WorkflowInstallPlan {
        guard let item = optional.first(where: { $0.id == id }) else { return self }
        var copy = self
        copy.optional.removeAll { $0.id == id }
        copy.items.insert(item, at: copy.items.lastIndex { $0.work.isDownload }.map { $0 + 1 } ?? 0)
        return copy
    }

    // MARK: - Building

    static func make(
        template: Template, bindings: InstallBindings, report: SetupReport, inputs: Inputs
    ) -> WorkflowInstallPlan {
        var items: [Item] = []
        var optional: [Item] = []
        var covered = Set<String>()
        let blocking = report.blocking
        let def = template.workflow

        func add(_ item: Item, to list: inout [Item]) {
            if let index = list.firstIndex(where: { $0.id == item.id }) {
                list[index].covers += item.covers.filter { !list[index].covers.contains($0) }
            } else {
                list.append(item)
            }
        }

        // A slot the person already bound keeps its choice.
        for slot in template.requirements.models where bindings.models[slot.slot] == nil {
            guard let source = inputs.chatSource(slot) else { continue }
            let issues = blocking.filter { $0.kind == .model && $0.value == slot.slot }
            let steps = WorkflowSummary.slotSteps(slot.slot, in: def)
            let item = Item(
                id: "chat:" + source.repoId.lowercased(), work: .chatModel(repoId: source.repoId),
                title: steps.isEmpty ? L("Text model") : L("Text model for \(WorkflowSummary.list(steps))"),
                detail: source.repoId, activity: L("Downloading the text model"), sizeBytes: source.sizeBytes,
                covers: issues.map(\.id))
            // Required, or nothing stands in for it: it is part of the
            // install. Otherwise the default model runs the slot meanwhile.
            if slot.requiredModel != nil || !issues.isEmpty {
                add(item, to: &items)
                covered.formUnion(item.covers)
            } else {
                add(item, to: &optional)
            }
        }
        optional.removeAll { candidate in items.contains { $0.id == candidate.id } }

        for need in WorkflowModelsStep.mediaNeeds(template, items: blocking, onlyBlocked: true) {
            guard let issue = need.issue,
                case .download(let choice, _) = inputs.mediaOutcome(need.requirement)
            else { continue }
            add(
                Item(
                    id: "media:" + choice.id, work: .mediaModel(choice), title: need.requirement.action.modelTitle,
                    detail: choice.repoId, activity: need.requirement.action.downloadActivity,
                    sizeBytes: choice.sizeBytes, covers: [issue.id]),
                to: &items)
            covered.insert(issue.id)
        }

        let sandboxIssues = blocking.filter { $0.kind == .dependency && $0.value == "sandbox" }
        if !sandboxIssues.isEmpty, inputs.sandboxStatus == .notProvisioned {
            items.append(
                Item(
                    id: "sandbox", work: .sandbox, title: L("A safe place to run its steps"),
                    detail: L("Sets up the Osaurus Sandbox"), activity: L("Setting up a safe place to run its steps"),
                    sizeBytes: nil, covers: sandboxIssues.map(\.id)))
            covered.formUnion(sandboxIssues.map(\.id))
        }

        let packages = template.requirements.dependencies.filter {
            let status = inputs.dependencyStatus($0)
            return status == .notInstalled || status == .stale
        }
        if !packages.isEmpty {
            let ids = Set(packages.map(\.id))
            let issues = blocking.filter { $0.kind == .dependency && ids.contains($0.value) }
            items.append(
                Item(
                    id: "packages", work: .packages(packages), title: L("Tools its steps use"),
                    detail: packages.map { "\($0.manager.rawValue): \($0.packages.joined(separator: ", "))" }
                        .joined(separator: " · "),
                    activity: L("Installing the tools its steps use"), sizeBytes: nil, covers: issues.map(\.id)))
            covered.formUnion(issues.map(\.id))
        }

        // A key the install may skip is still asked: the installer is where
        // the person would expect to give it.
        let questions = report.items.filter { item in
            !covered.contains(item.id) && (item.isBlocking || item.isMissingKey)
        }
        return WorkflowInstallPlan(items: items, optional: optional, questions: questions)
    }

    // MARK: - Live

    /// `make` against this Mac: chat repos and media bundles resolved, with
    /// their download sizes.
    @MainActor
    static func live(template: Template, bindings: InstallBindings, report: SetupReport) async -> WorkflowInstallPlan {
        let manager = ModelManager.shared
        var chat: [String: ChatSource] = [:]
        for slot in template.requirements.models where bindings.models[slot.slot] == nil {
            guard case .download(let repo) = WorkflowModelResolution.livePlan(for: WorkflowModelChoices.suggested(slot))
            else { continue }
            let model = (manager.availableModels + manager.suggestedModels).first {
                $0.id.caseInsensitiveCompare(repo) == .orderedSame
            }
            var size: Int64?
            if let model { size = await manager.estimateDownloadSize(for: model) }
            chat[slot.slot] = ChatSource(repoId: repo, sizeBytes: size)
        }

        var media: [String: MediaModelSourceResolver.Outcome] = [:]
        for need in WorkflowModelsStep.mediaNeeds(template, items: report.blocking, onlyBlocked: true)
        where media[need.requirement.id] == nil {
            media[need.requirement.id] = await MediaModelSourceResolver.resolveLive(need.requirement)
        }

        let environment = WorkflowSandboxEnvironment.shared
        let inputs = Inputs(
            chatSource: { chat[$0.slot] },
            mediaOutcome: { media[$0.id] ?? .unavailable },
            sandboxStatus: SandboxManager.State.shared.status,
            dependencyStatus: { environment.status(of: $0, environmentID: template.id) })
        return make(template: template, bindings: bindings, report: report, inputs: inputs)
    }

    /// Free space where models download.
    static func liveFreeBytes() -> Int64? {
        ModelDownloadService.freeBytesOnVolume(containing: DirectoryPickerService.effectiveModelsDirectory())
    }
}
