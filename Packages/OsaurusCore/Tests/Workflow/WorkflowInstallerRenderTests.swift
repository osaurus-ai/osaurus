//
//  WorkflowInstallerRenderTests.swift
//  osaurus
//
//  Renders every installer screen (Ready, a question, Installing, Done,
//  a problem) in light and dark, and the bundle setup's progress card,
//  and fails if a render comes out blank or the installer lands on the
//  wrong screen. Set `SETTINGS_RENDER_DIR=/some/dir` to also write each
//  render as a PNG for review; reference images are not kept in the repo.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkflowInstallerRenderTests {

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "The sandbox could not start." }
    }

    /// Downloads that stay at 40%, a sandbox that fails when asked to.
    private func coordinator(sandboxFails: Bool = false) -> WorkflowInstallCoordinator {
        WorkflowInstallCoordinator(
            environment: .init(
                startChat: { .chat($0) },
                startMedia: { _ in },
                transfer: { _ in
                    .init(state: .downloading(progress: 0.4), received: 400, total: 1_000, bytesPerSecond: 50)
                },
                cancel: { _ in },
                provisionSandbox: { if sandboxFails { throw Boom() } },
                installPackages: { _, _ in },
                check: { SetupReport(subjectId: $0.subjectID, items: []) },
                commit: { _ in UUID() },
                storeURL: nil,
                now: { Date() },
                tickInterval: nil,
                retryDelays: [],
                remainingRefresh: 3))
    }

    private func subject(_ definition: WorkflowDefinition = WorkflowDefinition()) -> WorkflowSetupSubject {
        WorkflowSetupSubject(
            mode: .install, template: Template(name: "Character Forge", payload: .workflow(definition)),
            bindings: InstallBindings(), name: "Character Forge")
    }

    private let chatItem = WorkflowInstallPlan.Item(
        id: "chat:org/chat", work: .chatModel(repoId: "org/chat"), title: "Text model", detail: "org/chat",
        activity: "Downloading the text model", sizeBytes: 1_000, covers: [])

    private let sandboxItem = WorkflowInstallPlan.Item(
        id: "sandbox", work: .sandbox, title: "Sandbox", detail: "Linux sandbox",
        activity: "Setting up the sandbox", sizeBytes: nil, covers: [])

    /// Renders `view`, waits for it to draw, and returns how many distinct
    /// colours a coarse grid of the bitmap holds; a blank render has one
    /// or two.
    private func render<V: View>(_ name: String, dark: Bool, settle: Double = 1.2, _ view: V) async throws -> Int {
        let theme: ThemeProtocol = dark ? CustomizableTheme.dark() : CustomizableTheme.light()
        let size = NSSize(width: 560, height: 600)
        let root = view
            .frame(width: size.width, height: size.height)
            .background(theme.surface.canvas)
            .environment(\.theme, theme)
            .tint(theme.action.primary.default.background)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        var colours = 0
        for attempt in 1 ... 5 {
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            colours = Self.distinctColours(rep)
            if colours > 8 || attempt == 5 {
                if let dir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] {
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("installer-\(name)-\(dark ? "dark" : "light").png"))
                }
                break
            }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
        }
        if colours <= 8 {
            let renderer = ImageRenderer(content: root.environment(\.colorScheme, dark ? .dark : .light))
            renderer.proposedSize = ProposedViewSize(size)
            if let cgImage = renderer.cgImage { colours = Self.distinctColours(NSBitmapImageRep(cgImage: cgImage)) }
        }
        return colours
    }

    private static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 48)
        let stepY = max(1, rep.pixelsHigh / 48)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let key =
                    UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31)
                seen.insert(key)
            }
        }
        return seen.count
    }

    private func installer(_ subject: WorkflowSetupSubject, _ coordinator: WorkflowInstallCoordinator) -> some View {
        WorkflowInstallerView(subject: subject, coordinator: coordinator, onClose: {})
    }

    // MARK: - Screens

    @Test(arguments: [false, true])
    func readyScreenRenders(dark: Bool) async throws {
        let colours = try await render("ready", dark: dark, installer(subject(), coordinator()))
        #expect(colours > 8)
    }

    @Test(arguments: [false, true])
    func questionScreenRenders(dark: Bool) async throws {
        var definition = WorkflowDefinition()
        definition.folders = [FolderRequirement(key: "out", label: "Where to save the characters")]
        let colours = try await render("question", dark: dark, installer(subject(definition), coordinator()))
        #expect(colours > 8)
    }

    @Test(arguments: [false, true])
    func installingScreenRenders(dark: Bool) async throws {
        let coordinator = coordinator()
        let subject = subject()
        let id = coordinator.start(subject, items: [chatItem, sandboxItem])
        for _ in 0 ..< 10 { await Task.yield() }
        coordinator.tick()
        #expect(coordinator.job(id: id)?.phase == .running)
        let colours = try await render("installing", dark: dark, installer(subject, coordinator))
        #expect(colours > 8)
    }

    @Test(arguments: [false, true])
    func doneScreenRenders(dark: Bool) async throws {
        let coordinator = coordinator()
        let subject = subject()
        let id = coordinator.start(subject, items: [])
        guard case .done = coordinator.job(id: id)?.phase else {
            Issue.record("a workflow with nothing to fetch installs at once")
            return
        }
        let colours = try await render("done", dark: dark, installer(subject, coordinator))
        #expect(colours > 8)
    }

    @Test(arguments: [false, true])
    func problemScreenRenders(dark: Bool) async throws {
        let coordinator = coordinator(sandboxFails: true)
        let subject = subject()
        let id = coordinator.start(subject, items: [sandboxItem])
        for _ in 0 ..< 10 { await Task.yield() }
        coordinator.tick()
        guard case .failed = coordinator.job(id: id)?.phase else {
            Issue.record("a sandbox that cannot start fails the install")
            return
        }
        let colours = try await render("problem", dark: dark, installer(subject, coordinator))
        #expect(colours > 8)
    }

    @Test
    func progressCardRendersOnItsOwn() async throws {
        let coordinator = coordinator()
        let id = coordinator.start(subject(), items: [chatItem])
        for _ in 0 ..< 10 { await Task.yield() }
        coordinator.tick()
        let job = try #require(coordinator.job(id: id))
        let card = WorkflowInstallProgressView(job: job, coordinator: coordinator, showsDetails: .constant(true))
            .padding()
        let colours = try await render("progress-card", dark: false, settle: 0.6, card)
        #expect(colours > 8)
        #expect(WorkflowInstallProgressView.checklist(job).map(\.state) == [.working])
    }

    @Test
    func everyQuestionHasAPlainTitle() {
        let asked: [WorkflowSetupWizardView.Step] = [
            .models, .secrets, .folders, .apps, .agents, .tools, .dependencies, .permissions,
        ]
        let titles = asked.map(WorkflowInstallerView.questionTitle)
        #expect(Set(titles).count == asked.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }
}
