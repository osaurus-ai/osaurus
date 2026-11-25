//
//  WorkflowInstallCoordinatorTests.swift
//  osaurus
//
//  The background install: downloads, quiet retries, the check that
//  decides between installing and asking, cancel, and resuming after a
//  relaunch. Every service is faked.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
private final class FakeMachine {
    typealias Key = WorkflowInstallCoordinator.DownloadKey

    var transfers: [Key: WorkflowInstallCoordinator.Transfer] = [:]
    var startedChat: [String] = []
    var startedMedia: [String] = []
    var cancelled: [Key] = []
    var log: [String] = []
    var blockers: [SetupItem] = []
    var installedID = UUID()
    var commits = 0
    var flaggedNeedsSetup: [UUID] = []
    var provisionError: Error?
    var now = Date(timeIntervalSince1970: 1_000)

    func environment(storeURL: URL? = nil) -> WorkflowInstallCoordinator.Environment {
        WorkflowInstallCoordinator.Environment(
            startChat: { repo in
                self.startedChat.append(repo)
                self.transfers[.chat(repo)] = .init(state: .downloading(progress: 0))
                return .chat(repo)
            },
            startMedia: { source in
                self.startedMedia.append(source.id)
                self.transfers[.media(source.id)] = .init(state: .downloading(progress: 0))
            },
            transfer: { self.transfers[$0] },
            cancel: { key in
                self.cancelled.append(key)
                self.transfers[key] = .init(state: .notStarted)
            },
            provisionSandbox: {
                self.log.append("sandbox")
                if let error = self.provisionError { throw error }
            },
            installPackages: { deps, _ in self.log.append("packages:" + deps.map(\.id).joined(separator: ",")) },
            check: { subject in SetupReport(subjectId: subject.subjectID, items: self.blockers) },
            commit: { _ in
                self.commits += 1
                return self.installedID
            },
            flagNeedsSetup: { self.flaggedNeedsSetup.append($0) },
            storeURL: storeURL,
            now: { self.now },
            tickInterval: nil,
            retryDelays: [5, 20],
            remainingRefresh: 3)
    }

    func set(_ key: Key, _ state: DownloadState, received: Int64? = nil, total: Int64? = nil, speed: Double? = nil) {
        transfers[key] = .init(state: state, received: received, total: total, bytesPerSecond: speed)
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
@Suite(.serialized)
struct WorkflowInstallCoordinatorTests {

    private let subject = WorkflowSetupSubject(
        mode: .install, template: Template(name: "Character Forge", payload: .workflow(WorkflowDefinition())),
        bindings: InstallBindings(), name: "Character Forge")

    private let qwen = MediaModelSource(
        id: "Qwen-Image", repoId: "OsaurusAI/Qwen-Image", displayName: "Qwen Image", family: "qwen-image-2.1",
        sizeBytes: 3_000)

    private func chatItem(_ repo: String = "org/chat", size: Int64? = 1_000) -> WorkflowInstallPlan.Item {
        .init(
            id: "chat:" + repo, work: .chatModel(repoId: repo), title: "Text model", detail: repo,
            activity: "Downloading the text model", sizeBytes: size, covers: [])
    }

    private var mediaItem: WorkflowInstallPlan.Item {
        .init(
            id: "media:" + qwen.id, work: .mediaModel(qwen), title: "Image model", detail: qwen.repoId,
            activity: "Downloading the image model", sizeBytes: qwen.sizeBytes, covers: [])
    }

    private var sandboxItem: WorkflowInstallPlan.Item {
        .init(id: "sandbox", work: .sandbox, title: "Sandbox", detail: "", activity: "Setting up", sizeBytes: nil, covers: [])
    }

    private var packagesItem: WorkflowInstallPlan.Item {
        .init(
            id: "packages", work: .packages([WorkflowDependency(manager: .pip, packages: ["yt-dlp"])]), title: "Tools",
            detail: "", activity: "Installing", sizeBytes: nil, covers: [])
    }

    /// Lets the coordinator's own tasks run.
    private func settleTasks() async {
        for _ in 0 ..< 10 { await Task.yield() }
    }

    // MARK: - Installing

    @Test
    func installsByItselfOnceEveryDownloadLands() async {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [chatItem(), mediaItem])
        await settleTasks()

        #expect(machine.startedChat == ["org/chat"])
        #expect(machine.startedMedia == [qwen.id])
        #expect(coordinator.job(id: id)?.phase == .running)

        machine.set(.chat("org/chat"), .completed)
        machine.set(.media(qwen.id), .completed)
        coordinator.tick()

        #expect(coordinator.job(id: id)?.phase == .done(installedID: machine.installedID))
        #expect(machine.commits == 1)
        #expect(coordinator.job(id: id)?.progress == 1)
    }

    @Test
    func aWorkflowWithNothingToDownloadInstallsAtOnce() {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [])
        #expect(coordinator.job(id: id)?.phase == .done(installedID: machine.installedID))
    }

    @Test
    func startingTheSameWorkflowAgainKeepsOneJob() {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let first = coordinator.start(subject, items: [mediaItem])
        #expect(coordinator.start(subject, items: [mediaItem]) == first)
        #expect(coordinator.jobs.count == 1)
        #expect(machine.startedMedia.count == 1)
    }

    @Test
    func aStillBlockedWorkflowWaitsForThePerson() {
        let machine = FakeMachine()
        machine.blockers = [SetupItem(kind: .folder, severity: .blocking, title: "Output", detail: "", value: "out")]
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [mediaItem])
        machine.set(.media(qwen.id), .completed)
        coordinator.tick()

        #expect(coordinator.job(id: id)?.phase == .needsYou)
        #expect(machine.commits == 0)

        #expect(coordinator.recheck(id)?.hasBlockers == true)
        machine.blockers = []
        coordinator.recheck(id)
        #expect(coordinator.job(id: id)?.phase == .done(installedID: machine.installedID))
    }

    @Test
    func aSkippedModelSlotInstallsMarkedNeedsSetup() {
        let machine = FakeMachine()
        machine.blockers = [SetupItem(kind: .model, severity: .blocking, title: "Write", detail: "", value: "write")]
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [], deferring: ["write"])

        #expect(coordinator.job(id: id)?.phase == .done(installedID: machine.installedID))
        #expect(machine.flaggedNeedsSetup == [machine.installedID])
    }

    @Test
    func anotherBlockerStillWaitsWithASkippedModelSlot() {
        let machine = FakeMachine()
        machine.blockers = [
            SetupItem(kind: .model, severity: .blocking, title: "Write", detail: "", value: "write"),
            SetupItem(kind: .model, severity: .blocking, title: "Judge", detail: "", value: "judge"),
        ]
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [], deferring: ["write"])

        #expect(coordinator.job(id: id)?.phase == .needsYou)
        #expect(machine.commits == 0)
    }

    @Test
    func aCleanInstallIsNotMarkedNeedsSetup() {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        coordinator.start(subject, items: [], deferring: ["write"])
        #expect(machine.commits == 1)
        #expect(machine.flaggedNeedsSetup.isEmpty, "a skipped slot that turned out fine needs nothing")
    }

    // MARK: - Downloads

    @Test
    func aDownloadAlreadyRunningIsTakenOverNotRestarted() async {
        let machine = FakeMachine()
        machine.set(.media(qwen.id), .downloading(progress: 0.4))
        machine.set(.chat("org/chat"), .downloading(progress: 0.1))
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [chatItem(), mediaItem])
        await settleTasks()

        #expect(machine.startedChat.isEmpty)
        #expect(machine.startedMedia.isEmpty)
        #expect(coordinator.job(id: id)?.started.isEmpty == true)

        coordinator.cancel(id)
        #expect(machine.cancelled.isEmpty, "a download the job did not start keeps going")
        #expect(coordinator.jobs.isEmpty)
    }

    @Test
    func cancelStopsTheDownloadsTheJobStarted() async {
        let machine = FakeMachine()
        machine.set(.chat("org/chat"), .downloading(progress: 0.1))
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [chatItem(), mediaItem])
        await settleTasks()

        coordinator.cancel(id)
        #expect(machine.cancelled == [.media(qwen.id)])
    }

    @Test
    func aFailedDownloadRetriesQuietlyThenFails() {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [mediaItem])

        machine.set(.media(qwen.id), .failed(error: "connection lost"))
        coordinator.tick()
        #expect(coordinator.job(id: id)?.phase == .running)
        #expect(coordinator.job(id: id)?.activity == "Trying again in a moment…")

        machine.now += 4
        coordinator.tick()
        #expect(machine.startedMedia.count == 1, "waits out the first delay")

        machine.now += 2
        coordinator.tick()
        #expect(machine.startedMedia.count == 2)

        machine.set(.media(qwen.id), .failed(error: "connection lost"))
        coordinator.tick()
        machine.now += 21
        coordinator.tick()
        #expect(machine.startedMedia.count == 3)

        machine.set(.media(qwen.id), .failed(error: "connection lost"))
        coordinator.tick()
        #expect(coordinator.job(id: id)?.phase == .failed("connection lost"))

        coordinator.retry(id)
        #expect(machine.startedMedia.count == 4)
        #expect(coordinator.job(id: id)?.phase == .running)
    }

    @Test
    func aDownloadStoppedElsewhereIsNotStartedAgain() {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [mediaItem])
        machine.set(.media(qwen.id), .notStarted)
        coordinator.tick()

        #expect(coordinator.job(id: id)?.phase == .failed("The download was stopped."))
        #expect(machine.startedMedia.count == 1)
    }

    // MARK: - Sandbox and packages

    @Test
    func packagesWaitForTheSandbox() async {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [sandboxItem, packagesItem])
        await settleTasks()

        #expect(machine.log == ["sandbox", "packages:pip"])
        #expect(coordinator.job(id: id)?.phase == .done(installedID: machine.installedID))
    }

    @Test
    func aSandboxThatWillNotStartFailsTheJobAfterRetries() async {
        let machine = FakeMachine()
        machine.provisionError = Boom()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [sandboxItem, packagesItem])
        await settleTasks()
        for delay in [5.0, 20.0] {
            machine.now += delay
            coordinator.tick()
            await settleTasks()
        }

        #expect(machine.log == ["sandbox", "sandbox", "sandbox"])
        #expect(coordinator.job(id: id)?.phase == .failed("boom"))
    }

    // MARK: - Progress

    @Test
    func progressIsWeightedByBytes() async {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [chatItem(size: 1_000), mediaItem])
        await settleTasks()

        machine.set(.media(qwen.id), .downloading(progress: 0.5), received: 1_500, total: 3_000, speed: 100)
        coordinator.tick()
        let job = coordinator.job(id: id)
        #expect(abs((job?.progress ?? 0) - 0.375) < 0.0001)
        #expect(job?.activity == "Downloading the text model")
        // 1500 + 1000 bytes left at 100 B/s.
        #expect(job?.remaining == 25)
    }

    @Test
    func timeLeftIsSmoothedAndOnlyRefreshedEveryFewSeconds() async {
        let machine = FakeMachine()
        let coordinator = WorkflowInstallCoordinator(environment: machine.environment())
        let id = coordinator.start(subject, items: [mediaItem])

        machine.set(.media(qwen.id), .downloading(progress: 0), received: 0, total: 3_000, speed: 100)
        coordinator.tick()
        #expect(coordinator.job(id: id)?.remaining == 30)

        machine.now += 1
        machine.set(.media(qwen.id), .downloading(progress: 0), received: 0, total: 3_000, speed: 300)
        coordinator.tick()
        #expect(coordinator.job(id: id)?.remaining == 30, "held until the refresh interval")

        machine.now += 3
        coordinator.tick()
        let expected = WorkflowInstallCoordinator.smoothed(
            previous: WorkflowInstallCoordinator.smoothed(previous: 30, sample: 10), sample: 10)
        #expect(coordinator.job(id: id)?.remaining == expected)
    }

    @Test
    func timeLeftReadsInRoundNumbers() {
        #expect(WorkflowInstallCoordinator.remainingText(20) == "Less than a minute left")
        #expect(WorkflowInstallCoordinator.remainingText(70) == "About a minute left")
        #expect(WorkflowInstallCoordinator.remainingText(8 * 60 + 10) == "About 8 minutes left")
        #expect(WorkflowInstallCoordinator.remainingText(23 * 60) == "About 25 minutes left")
        #expect(WorkflowInstallCoordinator.remainingText(62 * 60) == "About an hour left")
        #expect(WorkflowInstallCoordinator.remainingText(100 * 60) == "About 1.5 hours left")
        #expect(WorkflowInstallCoordinator.remainingText(3 * 3600) == "About 3 hours left")
        #expect(WorkflowInstallCoordinator.smoothed(previous: nil, sample: 40) == 40)
    }

    // MARK: - Relaunch

    @Test
    func aJobResumesAfterARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = FakeMachine()
        let first = WorkflowInstallCoordinator(environment: machine.environment(storeURL: url))
        let id = first.start(subject, items: [mediaItem, chatItem()])
        await settleTasks()
        machine.set(.chat("org/chat"), .completed)
        first.tick()
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A new session: the download services remember nothing.
        let relaunched = FakeMachine()
        let second = WorkflowInstallCoordinator(environment: relaunched.environment(storeURL: url))
        second.resumeAfterLaunch()
        await settleTasks()

        let job = try #require(second.job(id: id))
        #expect(job.name == "Character Forge")
        #expect(job.state(of: chatItem()) == .done)
        #expect(relaunched.startedMedia == [qwen.id], "the unfinished download starts again")
        #expect(relaunched.startedChat.isEmpty)
        #expect(job.started.contains(mediaItem.id), "and Cancel may still stop it")

        relaunched.set(.media(qwen.id), .completed)
        second.tick()
        #expect(second.job(id: id)?.phase == .done(installedID: relaunched.installedID))

        let third = WorkflowInstallCoordinator(environment: FakeMachine().environment(storeURL: url))
        third.resumeAfterLaunch()
        #expect(third.jobs.isEmpty, "a finished job is not saved")
    }

    @Test
    func aSkippedModelSlotSurvivesARelaunch() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("installs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let machine = FakeMachine()
        let first = WorkflowInstallCoordinator(environment: machine.environment(storeURL: url))
        let id = first.start(subject, items: [mediaItem], deferring: ["write"])
        await settleTasks()

        let relaunched = FakeMachine()
        relaunched.blockers = [SetupItem(kind: .model, severity: .blocking, title: "Write", detail: "", value: "write")]
        let second = WorkflowInstallCoordinator(environment: relaunched.environment(storeURL: url))
        second.resumeAfterLaunch()
        await settleTasks()
        #expect(second.job(id: id)?.deferredSlots == ["write"])

        relaunched.set(.media(qwen.id), .completed)
        second.tick()
        #expect(second.job(id: id)?.phase == .done(installedID: relaunched.installedID))
    }
}
