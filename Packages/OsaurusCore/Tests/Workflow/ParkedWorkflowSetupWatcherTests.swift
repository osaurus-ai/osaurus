//
//  ParkedWorkflowSetupWatcherTests.swift
//  OsaurusCoreTests
//
//  The parked-setup watcher listens to catalog notifications that post
//  from background threads; receiving one must not trap the main-actor
//  isolation check (APPLE-MACOS-3S2).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ParkedWorkflowSetupWatcherTests {

    private static func blockedSubject() -> WorkflowSetupSubject {
        var template = WF.template(
            WorkflowDefinition(
                inputSchema: WF.object([:]),
                nodes: [
                    WorkflowNode(
                        id: "fetch", name: "Fetch",
                        kind: .code(CodeSpec(source: "async function run() { return {} }")))
                ],
                output: .object([:])))
        template.requirements.plugins = ["com.example.not-installed-\(UUID().uuidString)"]
        return WorkflowSetupSubject(mode: .install, template: template, bindings: InstallBindings(), name: "W")
    }

    @Test
    func catalogNotificationsFromABackgroundThread_doNotTrap() async {
        let subject = Self.blockedSubject()
        #expect(!ParkedWorkflowSetupWatcher.blockers(subject).isEmpty)

        let manager = ManagementStateManager.shared
        let previous = manager.pendingSetupSubject
        manager.pendingSetupSubject = .workflow(subject)
        defer {
            ParkedWorkflowSetupWatcher.shared.stop()
            manager.pendingSetupSubject = previous
        }
        ParkedWorkflowSetupWatcher.shared.watchParked()

        await Task.detached {
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
            NotificationCenter.default.post(name: .remoteProviderModelsChanged, object: nil)
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }.value
    }
}
