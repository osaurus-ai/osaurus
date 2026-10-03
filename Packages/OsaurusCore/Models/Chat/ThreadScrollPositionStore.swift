//
//  ThreadScrollPositionStore.swift
//  osaurus
//
//  Remembers where the reader was in a session's message thread while the
//  thread's table is torn down (tab switch rebuilds `ChatView`), so the next
//  mount can put them back instead of re-snapping to the bottom.
//

import CoreGraphics

/// Reading position in the message thread. Pinned readers go back to the
/// bottom; otherwise the block at the top of the viewport and the pixel
/// offset into it, resolved by block id so rows added or removed above it
/// don't shift the restore.
struct ThreadScrollPosition: Equatable {
    let isPinnedToBottom: Bool
    let blockId: String?
    let offsetFromRowTop: CGFloat

    static let bottom = ThreadScrollPosition(isPinnedToBottom: true, blockId: nil, offsetFromRowTop: 0)
}

/// Per-session holder for the saved position. Deliberately not observable:
/// it is written on teardown and read once on mount, so publishing changes
/// would only cause needless re-renders.
@MainActor
final class ThreadScrollPositionStore {
    var position: ThreadScrollPosition?
}
