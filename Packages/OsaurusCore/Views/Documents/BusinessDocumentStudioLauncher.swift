//
//  BusinessDocumentStudioLauncher.swift
//  osaurus
//
//  App-facing entry point for opening Business Document Workbench windows.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public enum BusinessDocumentStudioLauncher {
    private static let windowCache = BusinessDocumentStudioWindowCache<NSWindow>()
    private static var delegates: [ObjectIdentifier: BusinessDocumentStudioWindowDelegate] = [:]

    public static func openDocumentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = L("Open Business Document")
        panel.message = L("Choose a supported document to inspect preview, security, and export availability.")
        panel.allowedContentTypes = BusinessDocumentStudioDocumentTypes.supportedContentTypes

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                open(url: url)
            }
        }
    }

    public static func open(url: URL) {
        let sourceURL = BusinessDocumentStudioSourceIdentity.standardized(url)
        if let existing = windowCache.window(for: sourceURL) {
            show(existing)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let root = BusinessDocumentStudioView(
            sourceURL: sourceURL,
            claimSourceURL: { [weak window] selectedURL in
                guard let window else { return false }
                return claim(selectedURL, for: window)
            }
        )
        let hostingController = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }

        window.title = BusinessDocumentStudioSourceIdentity.windowTitle(
            for: sourceURL,
            fallback: L("Business Document Workbench")
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = hostingController
        window.center()

        let identifier = ObjectIdentifier(window)
        let delegate = BusinessDocumentStudioWindowDelegate { closingWindow in
            windowCache.remove(closingWindow)
            delegates[ObjectIdentifier(closingWindow)] = nil
        }
        delegates[identifier] = delegate
        window.delegate = delegate
        _ = windowCache.claim(sourceURL, for: window)

        show(window)
    }

    private static func claim(_ sourceURL: URL, for window: NSWindow) -> Bool {
        switch windowCache.claim(sourceURL, for: window) {
        case .claimed:
            window.title = BusinessDocumentStudioSourceIdentity.windowTitle(
                for: sourceURL,
                fallback: L("Business Document Workbench")
            )
            return true

        case .occupied(let existing):
            show(existing)
            window.close()
            return false
        }
    }

    private static func show(_ window: NSWindow) {
        NSApp.unhide(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

enum BusinessDocumentStudioSourceIdentity {
    static func standardized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func acceptedSourceURL(
        _ url: URL,
        claim: ((URL) -> Bool)?
    ) -> URL? {
        let sourceURL = standardized(url)
        guard claim?(sourceURL) ?? true else { return nil }
        return sourceURL
    }

    static func windowTitle(for url: URL, fallback: String) -> String {
        let filename = standardized(url).lastPathComponent
        return filename.isEmpty ? fallback : filename
    }
}

@MainActor
final class BusinessDocumentStudioWindowCache<Window: AnyObject> {
    enum ClaimResult {
        case claimed
        case occupied(Window)
    }

    private var windowsBySourceURL: [URL: Window] = [:]
    private var sourceURLsByWindow: [ObjectIdentifier: URL] = [:]

    func window(for sourceURL: URL) -> Window? {
        windowsBySourceURL[BusinessDocumentStudioSourceIdentity.standardized(sourceURL)]
    }

    func sourceURL(for window: Window) -> URL? {
        sourceURLsByWindow[ObjectIdentifier(window)]
    }

    /// A failed claim leaves both windows under their existing identities.
    /// This lets the caller focus the owner instead of corrupting either key.
    func claim(_ sourceURL: URL, for window: Window) -> ClaimResult {
        let sourceURL = BusinessDocumentStudioSourceIdentity.standardized(sourceURL)
        if let existing = windowsBySourceURL[sourceURL], existing !== window {
            return .occupied(existing)
        }

        let identifier = ObjectIdentifier(window)
        if let previousSourceURL = sourceURLsByWindow[identifier],
            windowsBySourceURL[previousSourceURL] === window {
            windowsBySourceURL[previousSourceURL] = nil
        }
        windowsBySourceURL[sourceURL] = window
        sourceURLsByWindow[identifier] = sourceURL
        return .claimed
    }

    func remove(_ window: Window) {
        let identifier = ObjectIdentifier(window)
        guard let sourceURL = sourceURLsByWindow.removeValue(forKey: identifier) else { return }
        if windowsBySourceURL[sourceURL] === window {
            windowsBySourceURL[sourceURL] = nil
        }
    }
}

enum BusinessDocumentStudioDocumentTypes {
    static var supportedContentTypes: [UTType] {
        let extensions = ["csv", "tsv", "xlsx", "pdf", "pptx", "potx", "docx", "doc", "rtf", "rtfd", "txt"]
        let structuredTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        let parserTypes = DocumentParser.supportedDocumentTypes
        var seen = Set<String>()
        return (parserTypes + structuredTypes).filter { seen.insert($0.identifier).inserted }
    }
}

@MainActor
private final class BusinessDocumentStudioWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: (NSWindow) -> Void

    init(onClose: @escaping (NSWindow) -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onClose(window)
    }
}
