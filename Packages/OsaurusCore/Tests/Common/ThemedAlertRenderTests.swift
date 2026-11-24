//
//  ThemedAlertRenderTests.swift
//  osaurusTests
//
//  Renders themed alerts (a two-button confirmation, the delete dialog with
//  its "Don't ask me again" accessory, and the import guide) offscreen in
//  light and dark and checks each draws content. Set
//  `CHAT_ACTIVITY_RENDER_DIR=/some/dir` to also write each render as a PNG.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ThemedAlertRenderTests {
    private static func render(
        _ name: String, dark: Bool, size: CGSize, _ request: (ThemedAlertScope) -> ThemedAlertRequest
    ) async throws -> NSBitmapImageRep {
        let theme: any ThemeProtocol = dark ? CustomizableTheme.dark() : CustomizableTheme.light()
        let scope = ThemedAlertScope.sheet(UUID())
        let frame = NSRect(origin: .zero, size: size)
        let host = NSHostingView(
            rootView: ThemedAlertHost(scope: scope)
                .environment(\.theme, theme)
                .frame(width: size.width, height: size.height)
                .background(theme.surface.canvas)
        )
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        let req = request(scope)
        ThemedAlertCenter.shared.present(req, scope: scope)
        defer {
            ThemedAlertCenter.shared.dismiss(scope: scope, id: req.id)
            window.orderOut(nil)
        }
        try await Task.sleep(nanoseconds: 900_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["CHAT_ACTIVITY_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("alert-\(name)-\(dark ? "dark" : "light").png"))
        }
        return rep
    }

    private static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = UInt32(c.redComponent * 255), g = UInt32(c.greenComponent * 255)
                let b = UInt32(c.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }

    @Test(arguments: [true, false])
    func confirmation_draws(dark: Bool) async throws {
        let rep = try await Self.render("confirm", dark: dark, size: CGSize(width: 560, height: 300)) { _ in
            ThemedAlertRequest(
                title: "Remove this provider?",
                message: "Its models disappear from the model picker. You can add it again later.",
                buttons: [.cancel("Cancel"), .destructive("Remove") {}],
                onDismiss: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }

    @Test(arguments: [true, false])
    func deleteDialog_draws(dark: Bool) async throws {
        let rep = try await Self.render("delete", dark: dark, size: CGSize(width: 560, height: 320)) { _ in
            ThemedAlertRequest(
                title: "Delete 1 chat?",
                message: "This chat and its messages are removed from this Mac. This cannot be undone.",
                accessory: AnyView(DontAskAgainToggle()),
                buttons: [.cancel("Cancel"), .primary("Archive instead") {}, .destructive("Delete 1 chat") {}],
                onDismiss: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }

    @Test(arguments: [true, false])
    func importGuide_draws(dark: Bool) async throws {
        let rep = try await Self.render("import", dark: dark, size: CGSize(width: 640, height: 560)) { _ in
            ThemedAlertRequest(
                title: "Import Conversations",
                message: nil,
                buttons: [.cancel("Cancel")],
                showsCloseButton: true,
                customContent: AnyView(ImportGuideSheet {}),
                width: 470,
                onDismiss: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }
}
