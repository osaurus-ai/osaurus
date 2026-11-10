//
//  WorkflowFlowLayout.swift
//  osaurus
//
//  Where a workflow's steps sit when drawn as a graph: a step one stage
//  after its deepest parent, each stage ordered so the lines between
//  stages cross as little as they can. The sidebar draws stages as rows;
//  the full view draws them as columns, left to right. Also what the full
//  view asks of the graph: what feeds or follows a step, the step beside
//  or after one, the zoom that fits it, and the branches a run did not take.
//

import CoreGraphics
import Foundation

enum WorkflowFlowLayout {
    enum Direction { case up, down, left, right }

    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 2
    /// Below this zoom a step draws as a compact pill.
    static let compactBelowZoom: CGFloat = 0.6

    // MARK: - Rows

    /// Rows of step ids. Falls back to one step per row, in declared
    /// order, when the graph has a cycle or duplicate ids.
    static func rows(_ def: WorkflowDefinition) -> [[String]] {
        guard let order = WorkflowValidator.topologicalOrder(def) else { return def.nodes.map { [$0.id] } }
        let parents = parentMap(def)
        var depth: [String: Int] = [:]
        for id in order {
            depth[id] = ((parents[id] ?? []).compactMap { depth[$0] }.max() ?? -1) + 1
        }
        let maxDepth = depth.values.max() ?? 0
        let byDepth = (0...maxDepth).map { level in order.filter { depth[$0] == level } }.filter { !$0.isEmpty }
        return ordered(byDepth, def: def)
    }

    /// `rows` for views, which ask on every redraw while the Architect
    /// streams patches. Rows depend only on the step ids and edge ends.
    @MainActor
    static func cachedRows(_ def: WorkflowDefinition) -> [[String]] {
        let key = RowsKey(ids: def.nodes.map(\.id), edges: def.edges.map { [$0.from, $0.to] })
        if let hit = rowsCache.first(where: { $0.key == key }) { return hit.rows }
        let computed = rows(def)
        rowsCache = Array(([(key, computed)] + rowsCache).prefix(8))
        return computed
    }

    private struct RowsKey: Equatable {
        let ids: [String]
        let edges: [[String]]
    }

    @MainActor private static var rowsCache: [(key: RowsKey, rows: [[String]])] = []

    /// `rows` reordered by the barycenter heuristic: each row sorted by
    /// where its parents sit, then by where its children sit, twice over.
    /// The arrangement with the fewest crossings wins, the start included.
    static func ordered(_ start: [[String]], def: WorkflowDefinition) -> [[String]] {
        guard start.count > 1 else { return start }
        let parents = parentMap(def)
        let children = childMap(def)
        var rows = start
        var best = start
        var bestCrossings = crossings(start, def: def)
        for _ in 0..<2 {
            for index in rows.indices.dropFirst() {
                rows[index] = sorted(rows[index], by: parents, positions: positions(rows))
            }
            for index in rows.indices.dropLast().reversed() {
                rows[index] = sorted(rows[index], by: children, positions: positions(rows))
            }
            let count = crossings(rows, def: def)
            if count < bestCrossings {
                best = rows
                bestCrossings = count
            }
        }
        return best
    }

    /// Each step's horizontal place, centered on its row's middle, since
    /// rows are drawn centered.
    static func positions(_ rows: [[String]]) -> [String: Double] {
        var out: [String: Double] = [:]
        for row in rows {
            let middle = Double(row.count - 1) / 2
            for (index, id) in row.enumerated() { out[id] = Double(index) - middle }
        }
        return out
    }

    private static func sorted(_ row: [String], by neighbors: [String: [String]], positions: [String: Double])
        -> [String]
    {
        let keyed = row.enumerated().map { index, id -> (id: String, key: Double, index: Int) in
            let places = (neighbors[id] ?? []).compactMap { positions[$0] }
            let key = places.isEmpty ? (positions[id] ?? Double(index)) : places.reduce(0, +) / Double(places.count)
            return (id, key, index)
        }
        return keyed.sorted { $0.key == $1.key ? $0.index < $1.index : $0.key < $1.key }.map(\.id)
    }

    /// Pairs of lines that cross between the same two rows.
    static func crossings(_ rows: [[String]], def: WorkflowDefinition) -> Int {
        let place = positions(rows)
        var row: [String: Int] = [:]
        for (index, ids) in rows.enumerated() { for id in ids { row[id] = index } }
        let lines = def.edges.compactMap { edge -> (from: Int, to: Int, a: Double, b: Double)? in
            guard let r1 = row[edge.from], let r2 = row[edge.to], let a = place[edge.from], let b = place[edge.to]
            else { return nil }
            return (r1, r2, a, b)
        }
        var total = 0
        for i in lines.indices {
            for j in lines.indices where j > i {
                let p = lines[i]
                let q = lines[j]
                guard p.from == q.from, p.to == q.to else { continue }
                if (p.a - q.a) * (p.b - q.b) < 0 { total += 1 }
            }
        }
        return total
    }

    static func parentMap(_ def: WorkflowDefinition) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for edge in def.edges where !(out[edge.to] ?? []).contains(edge.from) { out[edge.to, default: []].append(edge.from) }
        return out
    }

    static func childMap(_ def: WorkflowDefinition) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for edge in def.edges where !(out[edge.from] ?? []).contains(edge.to) { out[edge.from, default: []].append(edge.to) }
        return out
    }

    // MARK: - Focus

    /// Every step `id` depends on, directly or not.
    static func upstream(of id: String, in def: WorkflowDefinition) -> Set<String> {
        walk(from: id, along: parentMap(def))
    }

    /// Every step that depends on `id`, directly or not.
    static func downstream(of id: String, in def: WorkflowDefinition) -> Set<String> {
        walk(from: id, along: childMap(def))
    }

    /// `id`, what it depends on, and what depends on it.
    static func focus(on id: String, in def: WorkflowDefinition) -> Set<String> {
        upstream(of: id, in: def).union(downstream(of: id, in: def)).union([id])
    }

    private static func walk(from id: String, along links: [String: [String]]) -> Set<String> {
        var seen: Set<String> = []
        var queue = links[id] ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            queue += links[next] ?? []
        }
        seen.remove(id)
        return seen
    }

    // MARK: - Moving

    /// The step to move to from `id` in the full view's columns: left and
    /// right follow its lines (the first parent or child in stage order), up
    /// and down stay in its column.
    static func neighbor(of id: String, _ direction: Direction, rows: [[String]], def: WorkflowDefinition) -> String? {
        guard let rowIndex = rows.firstIndex(where: { $0.contains(id) }),
            let column = rows[rowIndex].firstIndex(of: id)
        else { return nil }
        let row = rows[rowIndex]
        func firstInRowOrder(_ ids: [String]) -> String? {
            let set = Set(ids)
            return rows.lazy.flatMap { $0 }.first { set.contains($0) }
        }
        switch direction {
        case .up: return column > 0 ? row[column - 1] : nil
        case .down: return column + 1 < row.count ? row[column + 1] : nil
        case .left: return firstInRowOrder(parentMap(def)[id] ?? [])
        case .right: return firstInRowOrder(childMap(def)[id] ?? [])
        }
    }

    // MARK: - Zoom

    /// The zoom that shows all of `content` in `viewport`, never past 100%.
    static func fitZoom(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let fit = min(viewport.width / content.width, viewport.height / content.height)
        return min(1, max(minimumZoom, fit))
    }

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, zoom))
    }

    // MARK: - Lines

    /// A line from the right edge of one step to the left edge of another.
    struct Curve: Equatable {
        var start: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y)
        }

        var midpoint: CGPoint { point(at: 0.5) }
    }

    /// Lines leave and enter at a step's ports, `inset` outside its edges.
    static func curve(from: CGRect, to: CGRect, inset: CGFloat = 0) -> Curve {
        let start = CGPoint(x: from.maxX + inset, y: from.midY)
        let end = CGPoint(x: to.minX - inset, y: to.midY)
        let bend = max(24, (end.x - start.x) / 2)
        return Curve(
            start: start, control1: CGPoint(x: start.x + bend, y: start.y),
            control2: CGPoint(x: end.x - bend, y: end.y), end: end)
    }

    /// The index of the line in `edges` passing within `tolerance` of `point`.
    static func hitEdge(
        at point: CGPoint, edges: [WorkflowEdge], frames: [String: CGRect], inset: CGFloat = 0, tolerance: CGFloat = 6
    ) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, edge) in edges.enumerated() {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let line = curve(from: from, to: to, inset: inset)
            for step in 0...32 {
                let p = line.point(at: CGFloat(step) / 32)
                let distance = hypot(p.x - point.x, p.y - point.y)
                if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (index, distance) }
            }
        }
        return best?.index
    }

    // MARK: - Runs

    /// Steps a run passed by: skipped, or still waiting once the run is over.
    static func notTaken(_ def: WorkflowDefinition, run: WorkflowRun?) -> Set<String> {
        guard let run else { return [] }
        var out: Set<String> = []
        for node in def.nodes {
            switch run.node(node.id)?.status {
            case .skipped?: out.insert(node.id)
            case .pending?, nil: if run.status.isTerminal { out.insert(node.id) }
            default: break
            }
        }
        return out
    }

    // MARK: - Words

    /// "If urgent → Draft reply", for a step whose next step depends on its
    /// result or that fans out.
    static func branchLines(_ node: WorkflowNode, in def: WorkflowDefinition) -> [String] {
        let out = def.edges.filter { $0.from == node.id }
        guard out.count > 1 || out.contains(where: { $0.when != nil }) else { return [] }
        return out.map { edge in
            let target = def.node(edge.to)?.name ?? edge.to
            guard let condition = edge.when else { return L("Then \(target)") }
            return L("If \(WorkflowSummary.condition(condition)) → \(target)")
        }
    }

    /// Steps whose name, intent, or kind contains `query`, in row order.
    static func matches(_ query: String, in def: WorkflowDefinition, rows: [[String]]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return rows.flatMap { $0 }.filter { id in
            guard let node = def.node(id) else { return false }
            return [node.name, node.intent ?? "", WorkflowSummary.kind(node)].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
