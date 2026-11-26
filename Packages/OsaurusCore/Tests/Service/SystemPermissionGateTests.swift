//
//  SystemPermissionGateTests.swift
//  OsaurusCoreTests — Service
//
//  The tool gate for macOS permissions: macOS's own dialog first, the
//  Osaurus panel when macOS cannot ask, and an Automation probe that could
//  not decide is not a denial.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("System permission gate", .serialized)
@MainActor
struct SystemPermissionGateTests {

    // MARK: - Fixtures

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [SystemPermissionPanelService.Request] = []
        private var _granted = false

        var requests: [SystemPermissionPanelService.Request] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }
        var granted: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _granted
            }
            set {
                lock.lock()
                _granted = newValue
                lock.unlock()
            }
        }
        func record(_ request: SystemPermissionPanelService.Request) {
            lock.lock()
            _requests.append(request)
            lock.unlock()
        }
    }

    private func environment(
        macOSCanAsk: Bool,
        request: PermissionProbeResult.Status,
        addOnly: Bool = false,
        recorder: Recorder
    ) -> SystemPermissionGate.Environment {
        SystemPermissionGate.Environment(
            macOSCanAsk: { _ in macOSCanAsk },
            request: { _ in recorder.granted ? .granted : request },
            isGranted: { _ in recorder.granted },
            calendarIsAddOnly: { addOnly }
        )
    }

    /// Runs `body` with the gate's system calls and the panel replaced.
    private func withGate<T>(
        _ env: SystemPermissionGate.Environment,
        recorder: Recorder,
        timeout: TimeInterval? = nil,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await SystemPermissionGate.$environmentOverrideForTests.withValue(env) {
            try await SystemPermissionPanelService.$presentationOverrideForTests.withValue({ recorder.record($0) }) {
                try await SystemPermissionPanelService.$timeoutOverrideForTests.withValue(timeout) {
                    try await body()
                }
            }
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - macOS asks first

    @Test("a permission nobody answered yet gets the macOS dialog and no Osaurus panel")
    func notDecided_asksMacOSFirst() async {
        let recorder = Recorder()
        let allowed = await withGate(environment(macOSCanAsk: true, request: .granted, recorder: recorder), recorder: recorder) {
            await SystemPermissionGate.ensure(.calendar, toolName: "calendar_events")
        }
        #expect(allowed == .granted)

        let declined = await withGate(environment(macOSCanAsk: true, request: .denied, recorder: recorder), recorder: recorder) {
            await SystemPermissionGate.ensure(.calendar, toolName: "calendar_events")
        }
        // The person just answered macOS's dialog; asking again is nagging.
        #expect(declined == .declined)
        #expect(!declined.allowsCall)
        #expect(recorder.requests.isEmpty)
    }

    // MARK: - The panel

    @Test("an earlier Don't Allow shows the panel, and Try Again lets the call through once access is on")
    func denied_panelThenTryAgain() async {
        let recorder = Recorder()
        await withGate(environment(macOSCanAsk: false, request: .denied, recorder: recorder), recorder: recorder) {
            let call = Task { await SystemPermissionGate.ensure(.calendar, toolName: "calendar_events") }
            await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.calendar) }
            #expect(
                recorder.requests == [
                    .init(permission: .calendar, toolName: "calendar_events", requesterName: "Osaurus", reason: .turnedOff)
                ])

            await SystemPermissionPanelService.tryAgainForTesting(.calendar)
            #expect(SystemPermissionPanelService.stillOffForTesting(.calendar))
            #expect(SystemPermissionPanelService.openPanelsForTesting.contains(.calendar))

            recorder.granted = true
            await SystemPermissionPanelService.tryAgainForTesting(.calendar)
            #expect(await call.value == .granted)
            #expect(SystemPermissionPanelService.openPanelsForTesting.isEmpty)
        }
    }

    @Test("Not Now on the panel refuses the call")
    func denied_notNow() async {
        let recorder = Recorder()
        await withGate(environment(macOSCanAsk: false, request: .denied, recorder: recorder), recorder: recorder) {
            let call = Task { await SystemPermissionGate.ensure(.reminders, toolName: "reminders_list") }
            await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.reminders) }
            SystemPermissionPanelService.answerForTesting(.reminders, .notNow)
            #expect(await call.value == .notNow)
        }
    }

    @Test("permissions macOS never asks for go straight to the panel, which says where to turn them on")
    func neverPromptable_showsSettingsOnlyPanel() async {
        let recorder = Recorder()
        await withGate(environment(macOSCanAsk: true, request: .denied, recorder: recorder), recorder: recorder) {
            let call = Task { await SystemPermissionGate.ensure(.disk, toolName: "messages_search") }
            await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.disk) }
            #expect(recorder.requests.first?.reason == .settingsOnly)
            SystemPermissionPanelService.answerForTesting(.disk, .notNow)
            #expect(await call.value == .notNow)
        }
        let copy = recorder.requests.first.map(SystemPermissionPanelView.explanation(for:))
        #expect(copy?.contains("Full Disk Access") == true)
    }

    @Test("Calendar set to Add Events Only says to choose Full Access")
    func calendarAddOnly_namesTheChoice() async {
        let recorder = Recorder()
        await withGate(
            environment(macOSCanAsk: false, request: .denied, addOnly: true, recorder: recorder), recorder: recorder
        ) {
            let call = Task { await SystemPermissionGate.ensure(.calendar, toolName: "calendar_events") }
            await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.calendar) }
            SystemPermissionPanelService.answerForTesting(.calendar, .notNow)
            _ = await call.value
        }
        #expect(recorder.requests.first?.reason == .addOnly)
        #expect(recorder.requests.first.map(SystemPermissionPanelView.explanation(for:))?.contains("Full Access") == true)
    }

    @Test("calls that need the same permission share one panel")
    func onePanelPerPermission() async {
        let recorder = Recorder()
        await withGate(environment(macOSCanAsk: false, request: .denied, recorder: recorder), recorder: recorder) {
            let first = Task { await SystemPermissionGate.ensure(.contacts, toolName: "contacts_search") }
            let second = Task { await SystemPermissionGate.ensure(.contacts, toolName: "contacts_get") }
            await waitUntil { SystemPermissionPanelService.waiterCountForTesting(.contacts) == 2 }
            #expect(recorder.requests.count == 1)
            recorder.granted = true
            await SystemPermissionPanelService.tryAgainForTesting(.contacts)
            #expect(await first.value == .granted)
            #expect(await second.value == .granted)
        }
    }

    @Test("an unanswered panel times out instead of holding the call forever")
    func unansweredPanel_timesOut() async {
        let recorder = Recorder()
        let outcome = await withGate(
            environment(macOSCanAsk: false, request: .denied, recorder: recorder), recorder: recorder, timeout: 0.05
        ) {
            await SystemPermissionGate.ensure(.microphone, toolName: "transcribe")
        }
        #expect(outcome == .notAnswered)
        #expect(SystemPermissionPanelService.openPanelsForTesting.isEmpty)
    }

    @Test("a cancelled call closes its panel when nobody else is waiting on it")
    func cancelledCaller_closesThePanel() async {
        let recorder = Recorder()
        await withGate(environment(macOSCanAsk: false, request: .denied, recorder: recorder), recorder: recorder) {
            let call = Task { await SystemPermissionGate.ensure(.location, toolName: "maps_here") }
            await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.location) }
            call.cancel()
            #expect(await call.value == .notNow)
            await waitUntil { SystemPermissionPanelService.openPanelsForTesting.isEmpty }
            #expect(SystemPermissionPanelService.openPanelsForTesting.isEmpty)
        }
    }

    @Test("with no panel stand-in a test process answers Not Now at once")
    func headless_answersNotNow() async {
        let recorder = Recorder()
        let outcome = await SystemPermissionGate.$environmentOverrideForTests.withValue(
            environment(macOSCanAsk: false, request: .denied, recorder: recorder)
        ) {
            await SystemPermissionGate.ensure(.calendar, toolName: "calendar_events")
        }
        #expect(outcome == .notNow)
    }

    // MARK: - Probe failures are not denials

    @Test("an Automation probe that could not decide lets the tool run and report its own error")
    func undecidedProbe_letsTheToolRun() async {
        let recorder = Recorder()
        let outcome = await withGate(environment(macOSCanAsk: false, request: .unknown, recorder: recorder), recorder: recorder) {
            await SystemPermissionGate.ensure(.automationMail, toolName: "mail_mailboxes")
        }
        #expect(outcome == .undetermined)
        #expect(outcome.allowsCall)
        #expect(recorder.requests.isEmpty)
    }

    @Test("only a real -1743 is a denial; timeouts and an app that did not answer are unknown and not cached")
    func probeMapping_separatesDenialFromNoAnswer() {
        func status(_ s: AppleScriptExecutionResult.Status, _ number: Int? = nil) -> PermissionProbeResult.Status {
            SystemPermissionService.probeResult(
                for: AppleScriptExecutionResult(status: s, output: "Mail", errorNumber: number, errorMessage: "x"),
                success: { $0 }
            ).status
        }
        #expect(status(.success) == .granted)
        #expect(status(.permissionRequired, -1743) == .denied)
        #expect(status(.timedOut) == .unknown)
        #expect(status(.runtimeError, AppleScriptBridge.ErrorNumber.appNotRunning) == .unknown)
        #expect(status(.runtimeError, AppleScriptBridge.ErrorNumber.connectionInvalid) == .unknown)
        #expect(SystemPermissionService.cachedGrant(for: .unknown) == nil)
        #expect(SystemPermissionService.cachedGrant(for: .denied) == false)
        #expect(SystemPermissionService.cachedGrant(for: .granted) == true)
    }

    // MARK: - Through the tool registry

    @Test("the registry runs a permissioned tool after Try Again, and Not Now keeps today's permission_denied error")
    func registryGate_usesThePanel() async {
        await DynamicCatalogTestLock.shared.run {
            let name = "calendar_gate_probe_" + UUID().uuidString
            let registry = ToolRegistry.shared
            registry.registerPluginTool(CalendarPermissionFixture(name: name))
            registry.setEnabled(true, for: name)
            defer { registry.unregister(names: [name]) }
            let scope = ToolExecutionScope(exposed: registry.specs(forTools: [name]))

            let refused = Recorder()
            await withGate(environment(macOSCanAsk: false, request: .denied, recorder: refused), recorder: refused) {
                await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                    let call = Task { try await registry.execute(name: name, argumentsJSON: "{}") }
                    await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.calendar) }
                    SystemPermissionPanelService.answerForTesting(.calendar, .notNow)
                    do {
                        _ = try await call.value
                        Issue.record("Not Now must refuse the call")
                    } catch let error as NSError {
                        #expect(error.code == 7)
                        #expect(error.userInfo[ToolRegistry.missingPermissionUserInfoKey] as? String == "calendar")
                    }
                }
            }

            let allowed = Recorder()
            let result = await withGate(environment(macOSCanAsk: false, request: .denied, recorder: allowed), recorder: allowed) {
                await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                    let call = Task { try await registry.execute(name: name, argumentsJSON: "{}") }
                    await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.calendar) }
                    allowed.granted = true
                    await SystemPermissionPanelService.tryAgainForTesting(.calendar)
                    return await call.result
                }
            }
            #expect((try? result.get())?.contains(CalendarPermissionFixture.executed) == true, "\(result)")

            let addOnly = Recorder()
            await withGate(
                environment(macOSCanAsk: false, request: .denied, addOnly: true, recorder: addOnly), recorder: addOnly
            ) {
                await ChatExecutionContext.$toolExecutionScope.withValue(scope) {
                    let call = Task { try await registry.execute(name: name, argumentsJSON: "{}") }
                    await waitUntil { SystemPermissionPanelService.openPanelsForTesting.contains(.calendar) }
                    SystemPermissionPanelService.answerForTesting(.calendar, .notNow)
                    do {
                        _ = try await call.value
                        Issue.record("Not Now must refuse the call")
                    } catch let error as NSError {
                        #expect(error.code == 7)
                        #expect(error.localizedDescription.contains("choose Full Access"), "\(error)")
                    }
                }
            }
        }
    }
}

private struct CalendarPermissionFixture: OsaurusTool, PermissionedTool {
    static let executed = "calendar-fixture-ran"
    let name: String
    let description = "Harmless calendar permission gate probe"
    let requirements: [String] = [SystemPermission.calendar.rawValue]
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto
    let parameters: JSONValue? = .object(["type": .string("object"), "properties": .object([:])])
    func execute(argumentsJSON: String) async throws -> String { Self.executed }
}
