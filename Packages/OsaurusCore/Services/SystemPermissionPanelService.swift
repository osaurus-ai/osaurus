//
//  SystemPermissionPanelService.swift
//  osaurus
//
//  The panel the tool permission gate shows when macOS will not show its
//  own dialog: the person chose "Don't Allow" before, or the permission is
//  one macOS never asks for (Full Disk Access, Accessibility, Screen
//  Recording). It says who needs what, opens System Settings, and lets the
//  call go ahead once access is on, instead of failing with nothing shown.
//

import AppKit
import SwiftUI

@MainActor
enum SystemPermissionPanelService {
    enum Answer: Equatable, Sendable {
        case granted
        case notNow
        /// Nobody answered before `timeout`.
        case timedOut
    }

    /// Why macOS did not ask, which decides what the panel says to change.
    enum Reason: Equatable, Sendable {
        /// The person turned it off, or chose "Don't Allow".
        case turnedOff
        /// macOS has no dialog for it; only System Settings can grant it.
        case settingsOnly
        /// Calendar is set to "Add Events Only".
        case addOnly
    }

    struct Request: Equatable, Sendable {
        let permission: SystemPermission
        let toolName: String
        /// The agent (or "Osaurus") the call runs for, as the panel names it.
        let requesterName: String
        let reason: Reason
    }

    /// How long a panel waits for an answer. A scheduled workflow run with
    /// nobody at the Mac must not hold its step forever.
    static let timeout: TimeInterval = 600

    typealias Recheck = @MainActor @Sendable (SystemPermission) async -> Bool

    /// Replaces the AppKit panel. Receives each request as it would be
    /// shown; the test answers with `tryAgainForTesting` /
    /// `answerForTesting`. Task-local so suites that do not bind it keep the
    /// headless "Not Now".
    typealias TestPresenter = @Sendable (Request) -> Void

    @TaskLocal static var presentationOverrideForTests: TestPresenter?
    @TaskLocal static var timeoutOverrideForTests: TimeInterval?

    @MainActor
    private final class Pending {
        let request: Request
        let recheck: Recheck
        let model = SystemPermissionPanelModel()
        var waiters: [UUID: CheckedContinuation<Answer, Never>] = [:]
        var cardID: UUID?
        var timeoutTask: Task<Void, Never>?
        var activationObserver: NSObjectProtocol?

        init(request: Request, recheck: @escaping Recheck) {
            self.request = request
            self.recheck = recheck
        }
    }

    /// One entry per permission: a call that needs a permission whose panel
    /// is already up waits on that panel instead of opening another, so a
    /// parallel batch or a teammate plus its workflow never stack panels.
    private static var pending: [SystemPermission: Pending] = [:]

    /// Shows the panel for `request` (or joins the one already open for the
    /// same permission) and waits for the answer. `recheck` reads the live
    /// grant for **Try Again** and when the person comes back to Osaurus.
    static func ask(_ request: Request, recheck: @escaping Recheck) async -> Answer {
        let presenter = presentationOverrideForTests
        // The eval harness binds auto-approve because it has no UI run loop:
        // a panel there would wait for nobody.
        if presenter == nil, RuntimeEnvironment.isUnderTests || ChatExecutionContext.autoApproveToolPrompts {
            return .notNow
        }
        // A paired phone or a synced device has nobody at this Mac's screen.
        guard ToolPermissionPromptService.Requester.current == .thisMac else { return .notNow }
        let timeout = timeoutOverrideForTests ?? Self.timeout
        let permission = request.permission
        let waiter = UUID()
        let observer = ChatExecutionContext.approvalWaitObserver
        await observer?(true)
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let entry = pending[permission] {
                    entry.waiters[waiter] = continuation
                } else {
                    let entry = Pending(request: request, recheck: recheck)
                    entry.waiters[waiter] = continuation
                    pending[permission] = entry
                    present(entry, presenter: presenter, timeout: timeout)
                }
                if Task.isCancelled { drop(waiter, from: permission) }
            }
        } onCancel: {
            Task { @MainActor in drop(waiter, from: permission) }
        }
        await observer?(false)
        return answer
    }

    // MARK: - Presentation

    private static func present(_ entry: Pending, presenter: TestPresenter?, timeout: TimeInterval) {
        let permission = entry.request.permission
        entry.timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finish(permission, .timedOut)
        }
        if let presenter {
            presenter(entry.request)
            return
        }
        let id = UUID()
        entry.cardID = id
        let view = SystemPermissionPanelView(
            request: entry.request,
            model: entry.model,
            onOpenSettings: { SystemPermissionService.shared.openSystemSettings(for: permission) },
            onTryAgain: { Task { @MainActor in await tryAgain(permission) } },
            onNotNow: { finish(permission, .notNow) }
        )
        .environment(\.theme, ThemeManager.shared.currentTheme)
        ToolPermissionPromptService.presentAheadOfQueue(
            .init(
                id: id,
                view: AnyView(view),
                onReturn: { SystemPermissionService.shared.openSystemSettings(for: permission) },
                onEscape: { finish(permission, .notNow) }
            )
        )
        // Coming back from System Settings is the usual answer; check then
        // so the person does not also have to press Try Again.
        entry.activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await recheckQuietly(permission) }
        }
    }

    private static func tryAgain(_ permission: SystemPermission) async {
        guard let entry = pending[permission], !entry.model.isChecking else { return }
        entry.model.isChecking = true
        let granted = await entry.recheck(permission)
        entry.model.isChecking = false
        if granted {
            finish(permission, .granted)
        } else {
            entry.model.stillOff = true
        }
    }

    private static func recheckQuietly(_ permission: SystemPermission) async {
        guard let entry = pending[permission], !entry.model.isChecking else { return }
        if await entry.recheck(permission) { finish(permission, .granted) }
    }

    private static func finish(_ permission: SystemPermission, _ answer: Answer) {
        guard let entry = pending.removeValue(forKey: permission) else { return }
        entry.timeoutTask?.cancel()
        if let observer = entry.activationObserver { NotificationCenter.default.removeObserver(observer) }
        if let id = entry.cardID { ToolPermissionPromptService.dismissAheadCard(id: id) }
        for continuation in entry.waiters.values { continuation.resume(returning: answer) }
    }

    /// A cancelled caller stops waiting; the panel closes once nobody is
    /// left waiting on it.
    private static func drop(_ waiter: UUID, from permission: SystemPermission) {
        guard let entry = pending[permission],
            let continuation = entry.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(returning: .notNow)
        if entry.waiters.isEmpty { finish(permission, .notNow) }
    }

    // MARK: - Test seams

    static func tryAgainForTesting(_ permission: SystemPermission) async { await tryAgain(permission) }
    static func answerForTesting(_ permission: SystemPermission, _ answer: Answer) { finish(permission, answer) }
    static var openPanelsForTesting: Set<SystemPermission> { Set(pending.keys) }
    static func waiterCountForTesting(_ permission: SystemPermission) -> Int { pending[permission]?.waiters.count ?? 0 }
    static func stillOffForTesting(_ permission: SystemPermission) -> Bool { pending[permission]?.model.stillOff ?? false }
}

@MainActor
final class SystemPermissionPanelModel: ObservableObject {
    @Published var isChecking = false
    /// Try Again found the permission still off.
    @Published var stillOff = false
}
