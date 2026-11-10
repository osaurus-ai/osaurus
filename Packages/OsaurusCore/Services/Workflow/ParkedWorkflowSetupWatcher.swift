//
//  ParkedWorkflowSetupWatcher.swift
//  osaurus
//
//  Workflow setup parks itself when it sends the user to another tab (to
//  download a model, add a provider, connect a server). Once whatever it
//  was waiting on arrives, a toast offers to go back and finish, so the
//  user does not have to remember where they left off. One toast per park.
//

import Combine
import Foundation

@MainActor
final class ParkedWorkflowSetupWatcher {
    static let shared = ParkedWorkflowSetupWatcher()

    private var watching: UUID?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Starts watching the wizard parked on `pendingSetupSubject`, if it
    /// is a workflow that still has something blocking.
    func watchParked() {
        stop()
        guard case .workflow(let subject)? = ManagementStateManager.shared.pendingSetupSubject,
            !Self.blockers(subject).isEmpty
        else { return }
        watching = subject.id
        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: .localModelsChanged).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: .toolsListChanged).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: .remoteProviderModelsChanged).map { _ in () }.eraseToAnyPublisher(),
            ModelPickerItemCache.shared.$items.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] in self?.check() }
        .store(in: &cancellables)
    }

    func stop() {
        watching = nil
        cancellables.removeAll()
    }

    static func blockers(_ subject: WorkflowSetupSubject) -> [SetupItem] {
        let bindings = MCPServerResolution.liveAutoBindings(for: subject.template, bindings: subject.bindings)
        return SetupChecker.check(
            subject.template, bindings: bindings, subjectId: subject.subjectID, secrets: .install, attended: true
        ).blocking
    }

    private func check() {
        guard case .workflow(let subject)? = ManagementStateManager.shared.pendingSetupSubject,
            subject.id == watching
        else {
            stop()
            return
        }
        guard Self.blockers(subject).isEmpty else { return }
        stop()
        let actionId = "workflow.setup.resume.\(subject.id.uuidString)"
        ToastManager.shared.registerActionHandler(for: actionId) { _ in
            AppDelegate.shared?.showManagementWindow(initialTab: .workflows)
        }
        ToastManager.shared.action(
            L("\(subject.name) is ready to finish"), message: L("Everything it was waiting on is here now."),
            action: .custom(id: actionId), buttonTitle: L("Finish Setup"))
    }
}
