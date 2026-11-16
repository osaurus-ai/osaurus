import AppKit
import SwiftUI

/// Keeps the original footer commit callback and guards when the attached
/// sheet's title frame no longer supplies SwiftUI's key-equivalent routing.
struct InspectorAssignedSheetCommit: NSViewRepresentable {
    let action: (() -> Void)?
    let isEnabled: Bool

    func makeNSView(context: Context) -> CommitMarker { CommitMarker() }
    func updateNSView(_ view: CommitMarker, context: Context) {
        view.action = action
        view.isEnabled = isEnabled
    }
    static func dismantleNSView(_ view: CommitMarker, coordinator: ()) { view.stopMonitoring() }

    final class CommitMarker: NSView {
        var action: (() -> Void)?
        var isEnabled = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return false }
                    guard (window.isSheet || window.sheetParent != nil),
                        event.window === window || event.window?.attachedSheet === window,
                        self.action != nil,
                        [36, 76].contains(event.keyCode),
                        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
                    else { return false }
                    if self.isEnabled && !event.isARepeat { self.action?() }
                    return true
                }
                return consumed ? nil : event
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
