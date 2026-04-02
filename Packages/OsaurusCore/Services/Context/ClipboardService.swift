//
//  ClipboardService.swift
//  osaurus
//
//  Service for monitoring the macOS pasteboard and capturing selections.
//

import AppKit
import Combine
import Foundation

/// Service for monitoring the macOS pasteboard and capturing selections from other apps
@MainActor
public final class ClipboardService: ObservableObject {
    public static let shared = ClipboardService()

    /// Supported content types on the clipboard
    public enum ClipboardContent: Equatable {
        case text(String)
        case image(Data)
        case file(URL)
        
        public var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    /// The current content on the pasteboard
    @Published public private(set) var currentContent: ClipboardContent?
    
    /// The application that was frontmost when the clipboard last changed
    @Published public private(set) var lastSourceApp: String?

    /// Whether the clipboard content has been "seen" or used
    @Published public var hasNewContent: Bool = false

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: AnyCancellable?
    private let keyboardService = KeyboardSimulationService.shared

    private init() {
        // monitoring is started/stopped by AppDelegate based on window visibility
    }

    /// Start polling the pasteboard for changes
    public func startMonitoring() {
        guard timer == nil else { return }
        print("[ClipboardService] Starting monitoring...")
        
        // Poll every 0.5 seconds for pasteboard changes
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPasteboard()
            }
    }

    /// Stop polling the pasteboard
    public func stopMonitoring() {
        print("[ClipboardService] Stopping monitoring")
        timer?.cancel()
        timer = nil
    }

    /// Explicitly check the pasteboard for changes
    public func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        
        print("[ClipboardService] Pasteboard change detected. Count: \(pb.changeCount) (was \(lastChangeCount))")
        lastChangeCount = pb.changeCount
        
        let newContent = detectContent(in: pb)
        
        if let content = newContent {
            // Only update if content actually changed
            if content != currentContent {
                print("[ClipboardService] New content detected: \(content)")
                currentContent = content
                hasNewContent = true
                
                // Identify the source application
                if let frontmost = NSWorkspace.shared.frontmostApplication {
                    lastSourceApp = frontmost.localizedName ?? frontmost.bundleIdentifier
                    print("[ClipboardService] Source app identified: \(lastSourceApp ?? "unknown")")
                }
            } else {
                print("[ClipboardService] Change detected but content is identical to current.")
            }
        } else {
            print("[ClipboardService] Change detected but no meaningful content found on pasteboard.")
        }
    }

    private func detectContent(in pb: NSPasteboard) -> ClipboardContent? {
        // 1. try file URLs (copied files in Finder)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            // check if it's a supported document or image
            if DocumentParser.canParse(url: url) || DocumentParser.isImageFile(url: url) {
                return .file(url)
            }
        }
        
        // 2. try images (direct data)
        if let imageData = pb.data(forType: .png) {
            return .image(imageData)
        }
        if let tiffData = pb.data(forType: .tiff), let nsImage = NSImage(data: tiffData), let pngData = nsImage.pngData() {
            return .image(pngData)
        }
        
        // 3. try plain text
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        
        return nil
    }

    /// Attempt to grab the current selection from the active application
    /// by simulating Cmd+C and waiting for the pasteboard to update.
    public func grabSelection() async -> String? {
        let pb = NSPasteboard.general
        let startChangeCount = pb.changeCount
        print("[ClipboardService] Starting grabSelection. Current changeCount: \(startChangeCount)")
        
        // 1. simulate Cmd+C
        let posted = keyboardService.copySelection()
        print("[ClipboardService] copySelection() call returned: \(posted)")
        
        if !posted {
            print("[ClipboardService] FAILED to post Cmd+C event. Likely missing accessibility permissions.")
            return nil
        }
        
        // 2. wait for update (up to 500ms)
        print("[ClipboardService] Waiting for pasteboard update...")
        for i in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            if pb.changeCount != startChangeCount {
                print("[ClipboardService] Pasteboard update detected at iteration \(i+1). New count: \(pb.changeCount)")
                checkPasteboard()
                
                if case .text(let text) = currentContent {
                    return text
                }
                return nil
            }
        }
        
        print("[ClipboardService] TIMEOUT: Pasteboard did not update after 500ms.")
        return nil
    }

    /// Mark the current clipboard content as "read"
    public func markAsRead() {
        hasNewContent = false
    }
}
