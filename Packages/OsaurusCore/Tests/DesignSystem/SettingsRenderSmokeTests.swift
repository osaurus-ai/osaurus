//
//  SettingsRenderSmokeTests.swift
//  osaurusTests
//
//  Renders the kit gallery (light and dark) and representative Management
//  pages (in the app theme, which pages read directly) at a narrow and a
//  wide width, and fails if any render comes out blank. Set `SETTINGS_RENDER_DIR=/some/dir` to also write each render as a
//  PNG for side-by-side review; reference images are not kept in the repo.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct SettingsRenderSmokeTests {
    private static let updater = UpdaterViewModel()
    private static let server = ServerController()

    static let widths: [CGFloat] = [680, 1100]

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// Renders `view` and returns how many distinct colours a coarse grid
    /// of the bitmap holds; a blank or failed render has one or two.
    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, dark: Bool, _ view: V)
        async throws -> Int
    {
        let theme: ThemeProtocol = dark ? CustomizableTheme.dark() : CustomizableTheme.light()
        let root = view
            .frame(width: width, height: height)
            .background(theme.surface.canvas)
            .environment(\.theme, theme)
            .tint(theme.action.primary.default.background)
            .environmentObject(Self.updater)
            .environmentObject(Self.server)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // A loaded CI runner can take several passes before the hosting view
        // has drawn, so a blank capture is retried before it counts.
        var colours = 0
        for attempt in 1...5 {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            colours = distinctColours(rep)
            if colours > 8 || attempt == 5 {
                if let dir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] {
                    let file = "\(name)-\(Int(width))-\(dark ? "dark" : "light").png"
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
                }
                break
            }
        }
        // Headless runners sometimes never composite the offscreen window;
        // SwiftUI's own rasterizer needs no window server.
        if colours <= 8 {
            let renderer = ImageRenderer(content: root.environment(\.colorScheme, dark ? .dark : .light))
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            if let cgImage = renderer.cgImage {
                colours = distinctColours(NSBitmapImageRep(cgImage: cgImage))
            }
        }
        return colours
    }

    private func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var colours = Set<UInt32>()
        let step = 12
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(c.redComponent * 255), g = UInt32(c.greenComponent * 255)
                let b = UInt32(c.blueComponent * 255)
                colours.insert(r << 16 | g << 8 | b)
            }
        }
        return colours.count
    }

    private func check<V: View>(
        _ name: String,
        height: CGFloat = 1000,
        themes: [Bool] = [false],
        _ make: () -> V
    ) async throws {
        for width in Self.widths {
            for dark in themes {
                let colours = try await render(name, width: width, height: height, dark: dark, make())
                #expect(colours > 8, "\(name) @\(Int(width)) \(dark ? "dark" : "light") rendered blank (\(colours) colours)")
            }
        }
    }

    @Test func kitGallery() async throws {
        // A 6400pt window renders blank on headless CI runners; the full
        // height is only needed when writing PNGs for review.
        let fullHeight = ProcessInfo.processInfo.environment["SETTINGS_RENDER_DIR"] != nil
        try await StoragePathsTestLock.shared.run {
            try await check("gallery", height: fullHeight ? 6400 : 1600, themes: [false, true]) {
                SettingsKitGallery()
            }
        }
    }

    /// Pages open their stores on appear. Storage-migration tests close and
    /// reopen every open store inside their own data root, so the stores are
    /// closed again before the lock is released.
    @Test func representativePages() async throws {
        try await StoragePathsTestLock.shared.run {
            defer { for handle in OsaurusDatabaseHandle.allOpenHandles { handle.closer() } }
            try await check("model-defaults") { ModelDefaultsView() }
            try await check("chat") { ChatSettingsView() }
            try await check("general") { ConfigurationView() }
            try await check("memory") { MemoryView() }
            try await check("web-search") { SearchView() }
            try await check("insights") { InsightsView() }
        }
    }
}
