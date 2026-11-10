//
//  SettingsSearchablePickerRenderTests.swift
//  osaurusTests
//
//  Renders the searchable picker's list (no matches, a short grouped list,
//  a long one) and checks each render is drawn. Set
//  `WORKFLOW_RENDER_DIR=/some/dir` to also write each render as a PNG.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct SettingsSearchablePickerRenderTests {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static func render<V: View>(_ name: String, dark: Bool, _ view: V) async throws -> NSBitmapImageRep {
        let theme: ThemeProtocol = dark ? CustomizableTheme.dark() : CustomizableTheme.light()
        let root = view
            .fixedSize()
            .background(theme.surface.overlay)
            .environment(\.theme, theme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["WORKFLOW_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("searchable-picker-\(name).png"))
        }
        return rep
    }

    private static let options: [SettingsSearchablePicker.Option] =
        [
            .init(id: "qwen", title: "Qwen3.8 27B MXFP8", group: "On this Mac"),
            .init(id: "gemma", title: "gemma-4-26b-a4b", group: "On this Mac"),
            .init(id: "lfm", title: "LFM2.5 8B A1B MXFP8", group: "On this Mac"),
        ]
        + (1 ... 12).map { .init(id: "router-\($0)", title: "deepseek-v4-1-flash-\($0)", group: "Osaurus") }
        + [
            .init(id: "openai/gpt-4o", title: "gpt-4o", group: "OpenAI"),
            .init(id: "openai/gpt-4o-mini", title: "gpt-4o-mini", group: "OpenAI"),
        ]

    @Test func list_drawsInBothAppearances() async throws {
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            for (name, options) in [("long", Self.options), ("short", Array(Self.options.prefix(3))), ("empty", [])] {
                let rep = try await Self.render(
                    "\(name)-\(suffix)", dark: dark,
                    SettingsSearchablePickerList(
                        options: options, selection: "qwen", noneTitle: "Workflow's choice (Qwen3.8 27B MXFP8)",
                        searchPlaceholder: "Search models", onPick: { _ in }, onCancel: {}))
                #expect(rep.pixelsWide > 300)
                #expect(rep.pixelsHigh > 60)
            }
        }
    }
}
