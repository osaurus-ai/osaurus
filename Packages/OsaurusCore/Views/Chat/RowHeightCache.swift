//
//  RowHeightCache.swift
//  osaurus
//
//  Row heights the chat thread has measured, kept per column width.
//

import CoreGraphics

/// Row heights per block id at the current column width, plus the heights
/// measured at the last few widths. Toggling the sidebar or resizing back
/// to a width the thread already rendered at brings those heights back
/// instead of re-estimating every row; a row never measured at the new
/// width starts from its height at the previous one, which is far closer
/// than an estimate (most rows don't re-wrap at all).
struct RowHeightCache {
    private(set) var width: CGFloat = 0
    private var current: [String: CGFloat] = [:]
    /// Ids whose current height is a stand-in (an estimate, or carried from
    /// another width) rather than a measurement at this width.
    private var provisional: Set<String> = []
    private var retained: [Int: [String: CGFloat]] = [:]
    /// Most recent last.
    private var retainedOrder: [Int] = []
    private static let retainedWidthCount = 4

    /// A measured height. A row whose measurement changes at an unchanged
    /// width changed for every width (content, state, an image loading), so
    /// what other widths remember for it is dropped.
    subscript(id: String) -> CGFloat? {
        get { current[id] }
        set {
            let old = current[id]
            current[id] = newValue
            if provisional.remove(id) != nil { return }
            if let old, let newValue, abs(old - newValue) <= 0.5 { return }
            if old != nil { dropRetained(id) }
        }
    }

    /// A stand-in height until the row is measured at this width.
    mutating func setEstimate(_ height: CGFloat, for id: String) {
        current[id] = height
        provisional.insert(id)
    }

    var isEmpty: Bool { current.isEmpty }

    /// Whether the block has been measured at this width, not just estimated.
    func isMeasured(_ id: String) -> Bool { current[id] != nil && !provisional.contains(id) }

    /// The block's height changed at every width (its content or state did).
    mutating func removeValue(forKey id: String) {
        current.removeValue(forKey: id)
        provisional.remove(id)
        dropRetained(id)
    }

    mutating func removeAll() {
        current.removeAll()
        provisional.removeAll()
        retained.removeAll()
        retainedOrder.removeAll()
    }

    /// Drop blocks that left the thread, at every width.
    mutating func prune(keeping ids: Set<String>) {
        current = current.filter { ids.contains($0.key) }
        provisional.formIntersection(ids)
        for key in retainedOrder {
            retained[key] = retained[key]?.filter { ids.contains($0.key) }
        }
    }

    mutating func switchWidth(to newWidth: CGFloat) {
        let newKey = Self.key(newWidth)
        guard width > 0, Self.key(width) != newKey else {
            width = newWidth
            return
        }
        let oldKey = Self.key(width)
        retained[oldKey] = current.filter { !provisional.contains($0.key) }
        retainedOrder.removeAll { $0 == oldKey }
        retainedOrder.append(oldKey)

        let restored = retained.removeValue(forKey: newKey) ?? [:]
        retainedOrder.removeAll { $0 == newKey }
        var next = restored
        var nextProvisional = Set<String>()
        for (id, height) in current where next[id] == nil {
            next[id] = height
            nextProvisional.insert(id)
        }
        current = next
        provisional = nextProvisional
        width = newWidth
        while retainedOrder.count > Self.retainedWidthCount {
            retained.removeValue(forKey: retainedOrder.removeFirst())
        }
    }

    private mutating func dropRetained(_ id: String) {
        for key in retainedOrder {
            retained[key]?.removeValue(forKey: id)
        }
    }

    private static func key(_ width: CGFloat) -> Int { Int((width * 2).rounded()) }
}
