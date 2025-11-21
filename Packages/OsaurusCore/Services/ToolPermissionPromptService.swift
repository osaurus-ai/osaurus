//
//  ToolPermissionPromptService.swift
//  osaurus
//
//  Presents a confirmation dialog when a tool requires user approval.
//

import AppKit
import Foundation

@MainActor
enum ToolPermissionPromptService {
    static func requestApproval(
        toolName: String,
        description: String,
        argumentsJSON: String
    ) async -> Bool {
        let prettyArguments = prettyPrintedJSON(argumentsJSON) ?? argumentsJSON

        // Build a monospaced, non-editable text view for JSON arguments
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.string = prettyArguments
        textView.textContainerInset = NSSize(width: 8, height: 8)
        if let container = textView.textContainer {
            container.lineFragmentPadding = 4
            container.widthTracksTextView = true
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Run tool: \(toolName)?"
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alert.informativeText = "This action requires your approval."
        } else {
            alert.informativeText = description
        }
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.accessoryView = scrollView

        // Try to attach as a sheet to a visible window; otherwise, show app-modal
        if let parent =
            NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        {
            NSApp.activate(ignoringOtherApps: true)
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }
    }

    private static func prettyPrintedJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            let pretty = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            return String(decoding: pretty, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
