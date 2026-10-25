import Foundation

/// ModelRuntime owns this ledger on its actor. Returning true from end permits
/// the process-wide freed-buffer return and persistent allocator-cap restore.
struct GenerationAllocatorWindows {
    struct Window: Hashable, Sendable {
        private let id = UUID()
        var traceID: String { id.uuidString }
    }

    private var active: Set<Window> = []
    var activeWindowCount: Int { active.count }

    mutating func begin() -> Window {
        let window = Window()
        active.insert(window)
        return window
    }

    mutating func end(_ window: Window?) -> Bool {
        guard let window, active.remove(window) != nil else { return false }
        return active.isEmpty
    }
}
