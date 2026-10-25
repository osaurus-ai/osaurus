import Foundation

/// ModelRuntime owns this ledger on its actor. Returning true from end permits
/// the process-wide freed-buffer return and persistent allocator-cap restore.
struct GenerationAllocatorWindows {
    struct Window: Hashable, Sendable {
        private let id = UUID()
    }

    private var activeCount = 0

    mutating func begin() -> Window {
        activeCount += 1
        return Window()
    }

    mutating func end(_ window: Window?) -> Bool {
        guard window != nil else { return false }
        activeCount = max(0, activeCount - 1)
        return activeCount == 0
    }
}
