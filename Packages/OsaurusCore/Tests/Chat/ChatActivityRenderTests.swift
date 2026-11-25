//
//  ChatActivityRenderTests.swift
//  osaurusTests
//
//  Renders the native transcript activity views (tool-call rows, the pending
//  tool row, the reasoning row and the typing indicator) offscreen in light
//  and dark and checks each draws content. Set
//  `CHAT_ACTIVITY_RENDER_DIR=/some/dir` to also write each render as a PNG.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct ChatActivityRenderTests {
    private static let width: CGFloat = 620

    private static func render(
        _ name: String, dark: Bool, height: CGFloat, _ mount: (NSView, any ThemeProtocol) -> Void
    ) async throws -> NSBitmapImageRep {
        let theme: any ThemeProtocol = dark ? CustomizableTheme.dark() : CustomizableTheme.light()
        let frame = NSRect(x: 0, y: 0, width: width + 32, height: height)
        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(theme.surface.canvas).cgColor
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        mount(root, theme)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try snapshot(root, name: "\(name)-\(dark ? "dark" : "light")")
        // Two in-flight frames show the direction of running animations.
        for frameIndex in 1...2 {
            try await Task.sleep(nanoseconds: 250_000_000)
            _ = try snapshot(root, name: "\(name)-\(dark ? "dark" : "light")-frame\(frameIndex)", presentation: true)
        }
        return rep
    }

    private static func snapshot(_ root: NSView, name: String, presentation: Bool = false) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(root.frame.width * scale),
                pixelsHigh: Int(root.frame.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        ctx.cgContext.scaleBy(x: scale, y: scale)
        let layer = try #require(root.layer)
        (presentation ? layer.presentation() ?? layer : layer).render(in: ctx.cgContext)
        if let dir = ProcessInfo.processInfo.environment["CHAT_ACTIVITY_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
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

    private static func item(
        _ id: String, _ name: String, args: String = "{}", result: String? = nil, duration: TimeInterval? = nil
    ) -> ToolCallItem {
        ToolCallItem(
            call: ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: args)),
            result: result, duration: duration)
    }

    private static func pin(_ view: NSView, in root: NSView, top: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            view.widthAnchor.constraint(equalToConstant: width),
            view.topAnchor.constraint(equalTo: root.topAnchor, constant: top),
        ])
    }

    @Test(arguments: [true, false])
    func toolRows_draw(dark: Bool) async throws {
        let calls = [
            Self.item("a", "osaurus_config", result: "{\"ok\":true}", duration: 16.6),
            Self.item("b", "web_search", args: "{\"query\":\"maps\"}", result: "{\"ok\":false,\"message\":\"nope\"}", duration: 1.2),
            Self.item("c", "file_read", args: "{\"path\":\"README.md\"}"),
        ]
        let rep = try await Self.render("tool-rows", dark: dark, height: 260) { root, theme in
            let lone = NativeToolCallGroupView()
            Self.pin(lone, in: root, top: 16)
            lone.configure(
                calls: [Self.item("solo", "osaurus_config", result: "{\"ok\":true}", duration: 16.6)],
                expandedIds: [], width: Self.width, theme: theme, isStreaming: false,
                onToggle: { _ in }, onHeightChanged: {})
            let group = NativeToolCallGroupView()
            Self.pin(group, in: root, top: 84)
            group.configure(
                calls: calls, expandedIds: [], width: Self.width, theme: theme, isStreaming: true,
                onToggle: { _ in }, onHeightChanged: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }

    /// Chats saved while the AppleScript subagent shipped still hold
    /// `applescript` / `mac_query` calls; they draw as ordinary tool rows.
    @Test(arguments: [true, false])
    func removedAppleScriptToolRows_draw(dark: Bool) async throws {
        let calls = [
            Self.item(
                "as", "applescript", args: "{\"task\":\"Create a note\"}",
                result: "{\"ok\":true,\"result\":{\"summary\":\"Ran 1 script(s) successfully.\"}}", duration: 3.1),
            Self.item(
                "mq", "mac_query", args: "{\"question\":\"Front app?\"}",
                result: "{\"ok\":true,\"result\":{\"summary\":\"Safari\"}}", duration: 1.4),
        ]
        let rep = try await Self.render("removed-applescript-rows", dark: dark, height: 300) { root, theme in
            let group = NativeToolCallGroupView()
            Self.pin(group, in: root, top: 16)
            group.configure(
                calls: calls, expandedIds: ["as"], width: Self.width, theme: theme, isStreaming: false,
                onToggle: { _ in }, onHeightChanged: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }

    @Test(arguments: [true, false])
    func expandedToolRow_draws(dark: Bool) async throws {
        let rep = try await Self.render("tool-expanded", dark: dark, height: 300) { root, theme in
            let group = NativeToolCallGroupView()
            Self.pin(group, in: root, top: 16)
            group.configure(
                calls: [Self.item("x", "file_read", args: "{\"path\":\"README.md\"}", result: "{\"ok\":true,\"text\":\"Hello\"}", duration: 0.4)],
                expandedIds: ["x"], width: Self.width, theme: theme, isStreaming: false,
                onToggle: { _ in }, onHeightChanged: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }

    @Test(arguments: [true, false])
    func activityGroups_draw(dark: Bool) async throws {
        let turn = UUID()
        let children = [
            ContentBlock.thinking(turnId: turn, index: 0, text: "Plan", isStreaming: false, duration: 3, position: .first),
            ContentBlock.toolCallGroup(
                turnId: turn,
                calls: [
                    Self.item("g1", "web_search", result: "{\"ok\":true}", duration: 1.1),
                    Self.item("g2", "file_read", result: "{\"ok\":true}", duration: 0.3),
                    Self.item("g3", "shell_run", result: "{\"ok\":false,\"message\":\"exit 1\"}", duration: 2),
                ],
                position: .last),
        ]
        let rep = try await Self.render("activity-groups", dark: dark, height: 150) { root, theme in
            let done = NativeActivityGroupView()
            Self.pin(done, in: root, top: 16)
            done.configure(
                children: children, expandedIds: [], width: Self.width, theme: theme, isStreaming: false,
                blockId: "done", sessionRedactions: [:], onToggleChild: { _ in }, onToggle: {}, onHeightChanged: {})
            let live = NativeActivityGroupView()
            Self.pin(live, in: root, top: 80)
            live.configure(
                children: children + [
                    ContentBlock.toolCallGroup(turnId: UUID(), calls: [Self.item("g4", "web_fetch")], position: .only)
                ],
                expandedIds: [], width: Self.width, theme: theme, isStreaming: true,
                blockId: "live", sessionRedactions: [:], onToggleChild: { _ in }, onToggle: {}, onHeightChanged: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }

    @Test(arguments: [true, false])
    func loaders_draw(dark: Bool) async throws {
        let rep = try await Self.render("loaders", dark: dark, height: 220) { root, theme in
            let typing = NativeTypingIndicatorView()
            Self.pin(typing, in: root, top: 16)
            typing.heightAnchor.constraint(equalToConstant: 40).isActive = true
            typing.configure(theme: theme)
            let pending = NativePendingToolCallView()
            Self.pin(pending, in: root, top: 72)
            pending.heightAnchor.constraint(equalToConstant: 48).isActive = true
            pending.configure(toolName: "web_search", argPreview: nil, argSize: 0, theme: theme)
            let thinking = NativeThinkingView()
            Self.pin(thinking, in: root, top: 136)
            thinking.configure(
                thinking: "Considering the options", thinkingLength: nil, width: Self.width, isStreaming: true,
                isExpanded: false, duration: nil, theme: theme, blockId: "t", onToggle: {}, onHeightChanged: {})
        }
        #expect(Self.distinctColors(rep) > 8)
    }
}
