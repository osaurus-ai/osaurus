//
//  BusinessDocumentStudioLauncher.swift
//  osaurus
//
//  App-facing entry point for opening Business Document Studio windows.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public enum BusinessDocumentStudioLauncher {
    private static var windows: [URL: NSWindow] = [:]
    private static var delegates: [ObjectIdentifier: BusinessDocumentStudioWindowDelegate] = [:]

    public static func openDocumentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = L("Open Business Document")
        panel.message = L("Choose a supported document to inspect preview, security, and export availability.")
        panel.allowedContentTypes = supportedContentTypes

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                open(url: url)
            }
        }
    }

    public static func open(url: URL) {
        let sourceURL = url.standardizedFileURL
        if let existing = windows[sourceURL] {
            show(existing)
            return
        }

        let root = BusinessDocumentStudioView(sourceURL: sourceURL)
        let hostingController = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = sourceURL.lastPathComponent.isEmpty
            ? L("Business Document Studio")
            : sourceURL.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = hostingController
        window.center()

        let identifier = ObjectIdentifier(window)
        let delegate = BusinessDocumentStudioWindowDelegate {
            windows[sourceURL] = nil
            delegates[identifier] = nil
        }
        delegates[identifier] = delegate
        window.delegate = delegate
        windows[sourceURL] = window

        show(window)
    }

    private static var supportedContentTypes: [UTType] {
        let extensions = ["csv", "tsv", "xlsx", "pdf", "pptx", "potx", "docx", "doc", "rtf", "rtfd", "txt"]
        let structuredTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        let parserTypes = DocumentParser.supportedDocumentTypes
        var seen = Set<String>()
        return (parserTypes + structuredTypes).filter { seen.insert($0.identifier).inserted }
    }

    private static func show(_ window: NSWindow) {
        NSApp.unhide(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

@MainActor
private final class BusinessDocumentStudioWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
