//
//  WorkflowInstallToasts.swift
//  osaurus
//
//  The toasts for installs running in the background: one progress toast
//  per install while its installer is not on screen (Show reopens it), then
//  one toast when it is ready (Try It), needs an answer, or stopped. A
//  progress toast the person closes stays closed for that install; the row
//  on Workflows Home still shows it.
//

import Combine
import Foundation

@MainActor
final class WorkflowInstallToasts {
    static let shared = WorkflowInstallToasts(coordinator: .shared)

    private let coordinator: WorkflowInstallCoordinator
    private let toasts: ToastManager
    private var subscription: AnyCancellable?
    /// Install → its progress toast, and what that toast last said.
    private var progressToasts: [UUID: (toast: UUID, said: String)] = [:]
    /// Installs whose progress toast the person closed.
    private var muted: Set<UUID> = []
    /// Install → the phase its last one-off toast was for.
    private var announced: [UUID: String] = [:]

    init(coordinator: WorkflowInstallCoordinator, toasts: ToastManager = .shared) {
        self.coordinator = coordinator
        self.toasts = toasts
    }

    func start() {
        guard subscription == nil else { return }
        subscription = coordinator.$jobs.combineLatest(coordinator.$presented)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs, presented in self?.sync(jobs, presented: presented) }
    }

    private func sync(_ jobs: [WorkflowInstallCoordinator.Job], presented: Set<UUID>) {
        for job in jobs {
            let onScreen = presented.contains(job.templateID)
            switch job.phase {
            case .running:
                announced[job.id] = nil
                if onScreen || muted.contains(job.id) { dropProgress(job.id) } else { showProgress(job) }
            case .needsYou:
                dropProgress(job.id)
                guard !onScreen else { continue }
                once(job, "needsYou") {
                    toastWithAction(
                        type: .action, title: L("\(job.name) needs one answer"),
                        message: L("Answer it and Osaurus finishes adding it."),
                        button: L("Finish Setting Up"), job: job, timeout: nil
                    ) { WorkflowInstallCoordinator.show($0) }
                }
            case .failed(let message):
                dropProgress(job.id)
                guard !onScreen else { continue }
                once(job, "failed:" + message) {
                    toastWithAction(
                        type: .warning, title: L("Couldn't finish adding \(job.name)"), message: message,
                        button: L("Show"), job: job, timeout: nil
                    ) { WorkflowInstallCoordinator.show($0) }
                }
            case .done:
                dropProgress(job.id)
                guard !onScreen else { continue }
                let finished = job
                once(job, "done") {
                    toastWithAction(
                        type: .success, title: L("\(job.name) is ready"),
                        message: L("It's in Your Workflows."), button: L("Try It"), job: job, timeout: 10
                    ) { _ in WorkflowInstallCoordinator.tryIt(finished) }
                }
                coordinator.dismiss(job.id)
            }
        }
        let live = Set(jobs.map(\.id))
        for id in progressToasts.keys where !live.contains(id) { dropProgress(id) }
        muted.formIntersection(live)
        announced = announced.filter { live.contains($0.key) }
    }

    private func showProgress(_ job: WorkflowInstallCoordinator.Job) {
        let percent = Int((job.progress * 100).rounded(.down))
        let message = [job.activity, job.remaining.map(WorkflowInstallCoordinator.remainingText)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let said = "\(percent)|\(message)"
        if let existing = progressToasts[job.id] {
            guard existing.said != said else { return }
            progressToasts[job.id]?.said = said
            toasts.update(id: existing.toast, message: message, progress: job.progress)
            return
        }
        let actionID = "workflowInstallShow:\(job.id.uuidString)"
        let toast = toasts.show(
            Toast(
                type: .loading, title: L("Adding \(job.name)"), message: message, actionTitle: L("Show"),
                actionId: actionID, progress: job.progress))
        progressToasts[job.id] = (toast, said)
        let jobID = job.id
        toasts.registerActionHandler(for: actionID) { [weak self] _ in
            guard let job = self?.coordinator.job(id: jobID) else { return }
            WorkflowInstallCoordinator.show(job)
        }
        toasts.onDismiss(of: toast) { [weak self] reason in
            guard let self else { return }
            self.toasts.unregisterActionHandler(for: actionID)
            if self.progressToasts[jobID]?.toast == toast { self.progressToasts[jobID] = nil }
            if reason == .user { self.muted.insert(jobID) }
        }
    }

    private func dropProgress(_ jobID: UUID) {
        guard let entry = progressToasts.removeValue(forKey: jobID) else { return }
        toasts.dismiss(id: entry.toast)
    }

    private func once(_ job: WorkflowInstallCoordinator.Job, _ phase: String, _ show: () -> Void) {
        guard announced[job.id] != phase else { return }
        announced[job.id] = phase
        show()
    }

    private func toastWithAction(
        type: ToastType, title: String, message: String?, button: String, job: WorkflowInstallCoordinator.Job,
        timeout: TimeInterval?, perform: @escaping @MainActor (WorkflowInstallCoordinator.Job) -> Void
    ) {
        let actionID = "workflowInstall:\(UUID().uuidString)"
        let jobID = job.id
        let fallback = job
        let toast = toasts.show(
            Toast(type: type, title: title, message: message, timeout: timeout, actionTitle: button, actionId: actionID))
        toasts.registerActionHandler(for: actionID) { [weak self] _ in
            perform(self?.coordinator.job(id: jobID) ?? fallback)
        }
        toasts.onDismiss(of: toast) { [weak self] _ in self?.toasts.unregisterActionHandler(for: actionID) }
    }
}
