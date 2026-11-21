//
//  WorkflowInstallToastsTests.swift
//  osaurus
//
//  The background install's toasts and its row on Workflows Home: one
//  progress toast while the installer is not on screen, gone while it is
//  or once closed, and one toast when the install is ready (which then
//  leaves Home) or stops.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkflowInstallToastsTests {

    private final class Machine {
        var progress = 0.25
        var sandboxFails = false
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "The sandbox could not start." }
    }

    private func coordinator(_ machine: Machine) -> WorkflowInstallCoordinator {
        WorkflowInstallCoordinator(
            environment: .init(
                startChat: { .chat($0) },
                startMedia: { _ in },
                transfer: { _ in
                    .init(
                        state: machine.progress >= 1 ? .completed : .downloading(progress: machine.progress),
                        received: Int64(machine.progress * 1_000), total: 1_000)
                },
                cancel: { _ in },
                provisionSandbox: { if machine.sandboxFails { throw Boom() } },
                installPackages: { _, _ in },
                check: { SetupReport(subjectId: $0.subjectID, items: []) },
                commit: { _ in UUID() },
                storeURL: nil,
                now: { Date() },
                tickInterval: nil,
                retryDelays: [],
                remainingRefresh: 3))
    }

    private let name = "Toast Forge \(UUID().uuidString.prefix(6))"

    private var subject: WorkflowSetupSubject {
        WorkflowSetupSubject(
            mode: .install, template: Template(name: name, payload: .workflow(WorkflowDefinition())),
            bindings: InstallBindings(), name: name)
    }

    private let chatItem = WorkflowInstallPlan.Item(
        id: "chat:org/chat", work: .chatModel(repoId: "org/chat"), title: "Text model", detail: "org/chat",
        activity: "Downloading the text model", sizeBytes: 1_000, covers: [])

    private let sandboxItem = WorkflowInstallPlan.Item(
        id: "sandbox", work: .sandbox, title: "Sandbox", detail: "", activity: "Setting up the sandbox",
        sizeBytes: nil, covers: [])

    private var mine: [Toast] { ToastManager.shared.toasts.filter { $0.title.contains(name) } }

    /// Lets the coordinator's tasks and the toaster's main-queue hop run.
    private func settle() async throws {
        for _ in 0 ..< 10 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private func withToasts(_ body: () async throws -> Void) async throws {
        let original = ToastManager.shared.configuration
        var enabled = original
        enabled.enabled = true
        ToastManager.shared.updateConfiguration(enabled)
        defer {
            for toast in mine { ToastManager.shared.dismiss(id: toast.id) }
            ToastManager.shared.updateConfiguration(original)
        }
        try await body()
    }

    @Test
    func aBackgroundInstallShowsOneProgressToastThatFollowsIt() async throws {
        try await withToasts {
            let machine = Machine()
            let coordinator = coordinator(machine)
            let toaster = WorkflowInstallToasts(coordinator: coordinator)
            toaster.start()
            defer { withExtendedLifetime(toaster) {} }
            let id = coordinator.start(subject, items: [chatItem])
            coordinator.tick()
            try await settle()

            #expect(mine.count == 1)
            #expect(mine.first?.type == .loading)
            #expect(mine.first?.actionTitle == "Show")
            let first = try #require(mine.first?.progress)

            machine.progress = 0.6
            coordinator.tick()
            try await settle()
            #expect(mine.count == 1)
            #expect((mine.first?.progress ?? 0) > first)
            #expect(coordinator.job(id: id)?.phase == .running)
        }
    }

    @Test
    func theInstallerOnScreenHidesTheToast() async throws {
        try await withToasts {
            let coordinator = coordinator(Machine())
            let toaster = WorkflowInstallToasts(coordinator: coordinator)
            toaster.start()
            defer { withExtendedLifetime(toaster) {} }
            let subject = subject
            coordinator.setPresented(subject.template.id, true)
            _ = coordinator.start(subject, items: [chatItem])
            coordinator.tick()
            try await settle()
            #expect(mine.isEmpty)

            coordinator.setPresented(subject.template.id, false)
            try await settle()
            #expect(mine.count == 1)

            coordinator.setPresented(subject.template.id, true)
            try await settle()
            #expect(mine.isEmpty)
        }
    }

    @Test
    func aClosedProgressToastStaysClosed() async throws {
        try await withToasts {
            let machine = Machine()
            let coordinator = coordinator(machine)
            let toaster = WorkflowInstallToasts(coordinator: coordinator)
            toaster.start()
            defer { withExtendedLifetime(toaster) {} }
            _ = coordinator.start(subject, items: [chatItem])
            coordinator.tick()
            try await settle()
            let toast = try #require(mine.first)
            ToastManager.shared.dismiss(id: toast.id, reason: .user)

            machine.progress = 0.7
            coordinator.tick()
            try await settle()
            #expect(mine.isEmpty)
        }
    }

    @Test
    func aFinishedInstallSaysTryItAndLeavesHome() async throws {
        try await withToasts {
            let machine = Machine()
            let coordinator = coordinator(machine)
            let toaster = WorkflowInstallToasts(coordinator: coordinator)
            toaster.start()
            defer { withExtendedLifetime(toaster) {} }
            let id = coordinator.start(subject, items: [chatItem])
            coordinator.tick()
            try await settle()

            machine.progress = 1
            coordinator.tick()
            try await settle()

            #expect(mine.count == 1)
            #expect(mine.first?.type == .success)
            #expect(mine.first?.actionTitle == "Try It")
            #expect(coordinator.job(id: id) == nil)
        }
    }

    @Test
    func aStoppedInstallSaysSoOnce() async throws {
        try await withToasts {
            let machine = Machine()
            machine.sandboxFails = true
            let coordinator = coordinator(machine)
            let toaster = WorkflowInstallToasts(coordinator: coordinator)
            toaster.start()
            defer { withExtendedLifetime(toaster) {} }
            let id = coordinator.start(subject, items: [sandboxItem])
            try await settle()
            coordinator.tick()
            try await settle()
            guard case .failed = coordinator.job(id: id)?.phase else {
                Issue.record("expected the install to stop")
                return
            }
            coordinator.tick()
            try await settle()

            #expect(mine.count == 1)
            #expect(mine.first?.type == .warning)
            #expect(mine.first?.message == "The sandbox could not start.")
        }
    }

    // MARK: - Home

    @Test
    func theHomeRowSaysHowFarAlongItIs() async throws {
        let coordinator = coordinator(Machine())
        let id = coordinator.start(subject, items: [chatItem])
        coordinator.tick()
        try await settle()
        let job = try #require(coordinator.job(id: id))

        #expect(WorkflowsInstalling.status(job.phase) == .running)
        #expect(WorkflowsInstalling.line(job).hasPrefix("25% · Downloading the text model"))
        #expect(WorkflowsInstalling.status(.needsYou) == .awaitingUser)
    }

    @Test
    func anInstallInProgressIsNotAFirstRun() {
        #expect(!WorkflowsView.isFirstRun(installed: .shared, drafts: .shared, installing: true))
    }
}
