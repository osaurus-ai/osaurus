//
//  WorkflowInstallPlanTests.swift
//  osaurus
//
//  What the guided installer does by itself and what it asks.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowInstallPlanTests {

    private func template(_ edit: (inout TemplateRequirements) -> Void = { _ in }) -> Template {
        var t = Template(name: "Character Forge", payload: .workflow(WorkflowDefinition()))
        edit(&t.requirements)
        return t
    }

    private func item(
        _ kind: TemplateRequirement.Kind, _ value: String, severity: SetupItem.Severity = .blocking,
        hasNoModel: Bool = false, needsMediaModel: Bool = false, isMissingKey: Bool = false
    ) -> SetupItem {
        SetupItem(
            kind: kind, severity: severity, title: value, detail: "", value: value, isMissingKey: isMissingKey,
            hasNoModel: hasNoModel, needsMediaModel: needsMediaModel)
    }

    private func plan(
        _ t: Template, _ items: [SetupItem], bindings: InstallBindings = InstallBindings(),
        inputs: WorkflowInstallPlan.Inputs = .init()
    ) -> WorkflowInstallPlan {
        WorkflowInstallPlan.make(
            template: t, bindings: bindings, report: SetupReport(subjectId: t.id, items: items), inputs: inputs)
    }

    private func chat(_ repo: String, size: Int64? = nil) -> WorkflowInstallPlan.Inputs {
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.chatSource = { _ in .init(repoId: repo, sizeBytes: size) }
        return inputs
    }

    private let qwen = MediaModelSource(
        id: "Qwen-Image-2.1-mflux-4bit", repoId: "OsaurusAI/Qwen-Image-2.1-mflux-4bit", displayName: "Qwen Image",
        family: "qwen-image-2.1", sizeBytes: 12_000_000_000)

    // MARK: - Chat models

    @Test
    func requiredChatModelIsInstalledAndCoversItsSlot() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "mlx-community/Qwen3-8B-4bit", strictness: .always)] }
        let missing = item(.model, "write")
        let p = plan(t, [missing], inputs: chat("mlx-community/Qwen3-8B-4bit", size: 4_000))

        #expect(p.items.map(\.work) == [.chatModel(repoId: "mlx-community/Qwen3-8B-4bit")])
        #expect(p.items.first?.covers == [missing.id])
        #expect(p.items.first?.title == "Text model")
        #expect(p.questions.isEmpty)
        #expect(p.totalBytes == 4_000)
    }

    @Test
    func suggestedModelWithADefaultIsOfferedNotInstalled() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "mlx-community/Qwen3-8B-4bit")] }
        let p = plan(t, [], inputs: chat("mlx-community/Qwen3-8B-4bit"))

        #expect(p.items.isEmpty)
        #expect(p.optional.map(\.id) == ["chat:mlx-community/qwen3-8b-4bit"])
        #expect(p.needsNothing)

        let chosen = p.including("chat:mlx-community/qwen3-8b-4bit")
        #expect(chosen.optional.isEmpty)
        #expect(chosen.items.map(\.id) == ["chat:mlx-community/qwen3-8b-4bit"])
    }

    @Test
    func suggestedModelWithNothingStandingInIsInstalled() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "mlx-community/Qwen3-8B-4bit")] }
        let noModel = item(.model, "write", hasNoModel: true)
        let p = plan(t, [noModel], inputs: chat("mlx-community/Qwen3-8B-4bit"))

        #expect(p.items.map(\.id) == ["chat:mlx-community/qwen3-8b-4bit"])
        #expect(p.optional.isEmpty)
        #expect(p.questions.isEmpty)
        #expect(p.sizeIsPartial, "a download with no size yet")
    }

    @Test
    func aSlotThePersonBoundKeepsItsChoice() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "mlx-community/Qwen3-8B-4bit", strictness: .always)] }
        var bindings = InstallBindings()
        bindings.models["write"] = "openai/gpt-5"
        let mismatch = item(.model, "write")
        let p = plan(t, [mismatch], bindings: bindings, inputs: chat("mlx-community/Qwen3-8B-4bit"))

        #expect(p.items.isEmpty)
        #expect(p.questions == [mismatch])
        #expect(p.questionSteps() == [.models])
    }

    @Test
    func twoSlotsOnOneRepoAreOneDownload() {
        let t = template {
            $0.models = [
                ModelRequirement(slot: "a", preferred: "org/m", strictness: .always),
                ModelRequirement(slot: "b", preferred: "org/m", strictness: .always),
            ]
        }
        let p = plan(t, [item(.model, "a"), item(.model, "b")], inputs: chat("org/m"))
        #expect(p.items.count == 1)
        #expect(p.items.first?.covers == ["model:a", "model:b"])
    }

    @Test
    func choosingAnotherModelDropsTheDownloadAndAsks() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "org/m")] }
        let unusable = item(.model, "write")
        let report = SetupReport(subjectId: t.id, items: [unusable])
        let p = plan(t, [unusable], inputs: chat("org/m", size: 4_000))
        #expect(p.chatSlots == ["chat:org/m": ["write"]])

        let choosing = p.withoutDownloads(for: ["write"], deferring: [], report: report)
        #expect(choosing.items.isEmpty)
        #expect(choosing.questions == [unusable])
        #expect(choosing.questionSteps() == [.models])
        #expect(choosing.totalBytes == 0)
    }

    @Test
    func skippingAModelDropsTheDownloadWithoutAsking() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "org/m")] }
        let noModel = item(.model, "write", hasNoModel: true)
        let report = SetupReport(subjectId: t.id, items: [noModel])
        let skipped = plan(t, [noModel], inputs: chat("org/m")).withoutDownloads(for: [], deferring: ["write"], report: report)

        #expect(skipped.items.isEmpty)
        #expect(skipped.questions.isEmpty)
    }

    @Test
    func aSharedDownloadStaysForTheSlotStillUsingIt() {
        let t = template {
            $0.models = [
                ModelRequirement(slot: "a", preferred: "org/m", strictness: .always),
                ModelRequirement(slot: "b", preferred: "org/m", strictness: .always),
            ]
        }
        let issues = [item(.model, "a"), item(.model, "b")]
        let report = SetupReport(subjectId: t.id, items: issues)
        let p = plan(t, issues, inputs: chat("org/m")).withoutDownloads(for: [], deferring: ["a"], report: report)

        #expect(p.items.map(\.id) == ["chat:org/m"])
        #expect(p.items.first?.covers == ["model:b"])
        #expect(p.questions.isEmpty)
    }

    // MARK: - Media models

    @Test
    func aMissingImageModelDownloadsTheResolvedBundle() {
        let media = MediaModelRequirement(action: .generate, model: MediaModelSelector(family: "qwen-image-2.1"))
        let t = template { $0.mediaModels = [media] }
        let missing = SetupItem(
            kind: .mediaModel, severity: .blocking, title: media.label, detail: "", value: media.id, needsMediaModel: true)
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.mediaOutcome = { _ in .download(choice: self.qwen, alternatives: []) }
        let p = plan(t, [missing], inputs: inputs)

        #expect(p.items.map(\.work) == [.mediaModel(qwen)])
        #expect(p.items.first?.title == "Image model")
        #expect(p.items.first?.covers == [missing.id])
        #expect(p.questions.isEmpty)
        #expect(p.totalBytes == 12_000_000_000)
    }

    @Test
    func anImageToolWithNoModelNamedIsAQuestion() {
        let noModel = item(.tool, "image", needsMediaModel: true)
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.mediaOutcome = { _ in .choose(options: [self.qwen]) }
        let p = plan(template(), [noModel], inputs: inputs)

        #expect(p.items.isEmpty)
        #expect(p.questions == [noModel])
        #expect(p.questionSteps() == [.models])
    }

    @Test
    func aRemoteOnlyMediaModelIsAQuestion() {
        let media = MediaModelRequirement(action: .video, model: MediaModelSelector(locality: .remote))
        let t = template { $0.mediaModels = [media] }
        let missing = SetupItem(
            kind: .mediaModel, severity: .blocking, title: media.label, detail: "", value: media.id, needsMediaModel: true)
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.mediaOutcome = { _ in .connectProvider }
        #expect(plan(t, [missing], inputs: inputs).questions == [missing])
    }

    // MARK: - Sandbox and packages

    @Test
    func sandboxThenPackagesWhenNeitherIsHere() {
        let pip = WorkflowDependency(manager: .pip, packages: ["yt-dlp", "numpy"])
        let t = template { $0.dependencies = [pip] }
        let sandbox = item(.dependency, "sandbox")
        let package = item(.dependency, pip.id)
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.sandboxStatus = .notProvisioned
        inputs.dependencyStatus = { _ in .notInstalled }
        let p = plan(t, [sandbox, package], inputs: inputs)

        #expect(p.items.map(\.work) == [.sandbox, .packages([pip])])
        #expect(p.items.map(\.covers) == [[sandbox.id], [package.id]])
        #expect(p.items.last?.detail == "pip: yt-dlp, numpy")
        #expect(p.questions.isEmpty)
        #expect(!p.sizeIsPartial, "only downloads have a size")
    }

    @Test
    func aSandboxWithNoNetworkIsAskedAbout() {
        let pip = WorkflowDependency(manager: .pip, packages: ["yt-dlp"])
        let t = template { $0.dependencies = [pip] }
        let network = item(.dependency, "sandbox-network")
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.dependencyStatus = { _ in .notInstalled }
        let p = plan(t, [item(.dependency, pip.id), network], inputs: inputs)

        #expect(p.items.map(\.id) == ["packages"])
        #expect(p.questions == [network])
        #expect(p.questionSteps() == [.dependencies])
    }

    @Test
    func aBrokenSandboxIsNotSetUpAgainByItself() {
        let sandbox = item(.dependency, "sandbox")
        var inputs = WorkflowInstallPlan.Inputs()
        inputs.sandboxStatus = .error("disk image missing")
        let p = plan(template(), [sandbox], inputs: inputs)
        #expect(p.items.isEmpty)
        #expect(p.questions == [sandbox])
    }

    // MARK: - Questions and totals

    @Test
    func whatOnlyThePersonCanAnswerIsAskedInRailOrder() {
        let key = item(.secret, "API_KEY", severity: .advisory, isMissingKey: true)
        let folder = item(.folder, "out")
        let agent = item(.agent, "writer")
        let permission = item(.systemPermission, "accessibility")
        let note = item(.mediaModel, "checking", severity: .advisory)
        let p = plan(template(), [permission, agent, note, folder, key])

        #expect(p.questions == [permission, agent, folder, key], "advisory notes are not questions")
        #expect(p.questionSteps() == [.secrets, .folders, .agents, .permissions])
    }

    @Test
    func storageRefusalNeedsKnownFreeSpace() {
        let t = template { $0.models = [ModelRequirement(slot: "write", preferred: "org/m", strictness: .always)] }
        let p = plan(t, [item(.model, "write")], inputs: chat("org/m", size: 8_000_000_000))

        #expect(p.storageRefusal(freeBytes: nil) == nil)
        #expect(p.storageRefusal(freeBytes: 100_000_000_000) == nil)
        #expect(p.storageRefusal(freeBytes: 1_000_000_000) != nil)
    }

    @Test
    func itemsSurviveAnEncodeRoundTrip() throws {
        let pip = WorkflowDependency(manager: .pip, packages: ["yt-dlp"])
        let items = [
            WorkflowInstallPlan.Item(
                id: "media:q", work: .mediaModel(qwen), title: "Image model", detail: qwen.repoId, activity: "",
                sizeBytes: qwen.sizeBytes, covers: ["mediaModel:x"]),
            WorkflowInstallPlan.Item(
                id: "packages", work: .packages([pip]), title: "Tools", detail: "pip: yt-dlp", activity: "", sizeBytes: nil,
                covers: []),
            WorkflowInstallPlan.Item(id: "sandbox", work: .sandbox, title: "Sandbox", detail: "", activity: "", sizeBytes: nil,
                covers: []),
        ]
        let data = try JSONEncoder().encode(items)
        #expect(try JSONDecoder().decode([WorkflowInstallPlan.Item].self, from: data) == items)
    }
}
