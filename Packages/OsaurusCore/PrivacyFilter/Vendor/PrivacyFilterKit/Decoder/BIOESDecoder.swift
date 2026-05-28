//
//  BIOESDecoder.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5. See
//  PrivacyFilter/Vendor/PrivacyFilterKit/README-vendoring.md.
//

import Foundation

/// Constrained Viterbi decoder over BIOES label sequences.
/// Transitions matrix is `[fromLabel][toLabel] = score`. When transitions are unavailable,
/// a derived validity mask (-inf for invalid transitions, 0 for valid) is used.
public struct BIOESDecoder: Sendable {
    public let labels: BIOESLabelTable
    public let transitions: [[Float]]

    public init(labels: BIOESLabelTable, transitions: [[Float]]) {
        precondition(transitions.count == labels.count)
        precondition(transitions.allSatisfy { $0.count == labels.count })
        self.labels = labels
        self.transitions = transitions
    }

    /// Decode emission logits of shape `[seqLen][numLabels]` into a sequence of label ids.
    public func decode(logits: [[Float]]) -> [Int] {
        let seqLen = logits.count
        guard seqLen > 0 else { return [] }
        let numLabels = labels.count
        precondition(logits.allSatisfy { $0.count == numLabels })

        let neginf: Float = -1e30
        var dp = Array(repeating: Array(repeating: neginf, count: numLabels), count: seqLen)
        var bp = Array(repeating: Array(repeating: -1, count: numLabels), count: seqLen)

        for j in 0 ..< numLabels {
            let label = labels[j]
            let allowed = label.boundary == .begin || label.boundary == .single || label.boundary == .outside
            dp[0][j] = allowed ? logits[0][j] : neginf
        }

        for t in 1 ..< seqLen {
            for j in 0 ..< numLabels {
                var bestScore: Float = neginf
                var bestPrev: Int = -1
                for i in 0 ..< numLabels {
                    let prev = dp[t - 1][i]
                    if prev <= neginf { continue }
                    let trans = transitions[i][j]
                    if trans <= neginf { continue }
                    let score = prev + trans
                    if score > bestScore {
                        bestScore = score
                        bestPrev = i
                    }
                }
                dp[t][j] = bestScore + logits[t][j]
                bp[t][j] = bestPrev
            }
        }

        var bestEnd: Int = -1
        var bestScore: Float = neginf
        for j in 0 ..< numLabels {
            let label = labels[j]
            let allowed = label.boundary == .end || label.boundary == .single || label.boundary == .outside
            if !allowed { continue }
            if dp[seqLen - 1][j] > bestScore {
                bestScore = dp[seqLen - 1][j]
                bestEnd = j
            }
        }
        if bestEnd < 0 {
            bestEnd = (0 ..< numLabels).max(by: { dp[seqLen - 1][$0] < dp[seqLen - 1][$1] }) ?? labels.outsideId
        }

        var path = [Int](repeating: -1, count: seqLen)
        path[seqLen - 1] = bestEnd
        var cursor = bestEnd
        for t in stride(from: seqLen - 1, to: 0, by: -1) {
            cursor = bp[t][cursor]
            if cursor < 0 { cursor = labels.outsideId }
            path[t - 1] = cursor
        }
        return path
    }
}

public extension BIOESDecoder {
    /// Build a transition mask that only allows BIOES-valid transitions, scoring all valid ones equally.
    /// Used when no learned transition matrix is shipped with the model.
    static func validityMask(labels: BIOESLabelTable) -> [[Float]] {
        let neginf: Float = -1e30
        let n = labels.count
        var mask = Array(repeating: Array(repeating: neginf, count: n), count: n)
        for i in 0 ..< n {
            for j in 0 ..< n {
                if isValidTransition(from: labels[i], to: labels[j]) {
                    mask[i][j] = 0
                }
            }
        }
        return mask
    }

    private static func isValidTransition(from: BIOESLabel, to: BIOESLabel) -> Bool {
        switch from.boundary {
        case .outside, .end, .single:
            return to.boundary == .begin || to.boundary == .single || to.boundary == .outside
        case .begin, .inside:
            return (to.boundary == .inside || to.boundary == .end) && from.entity == to.entity
        }
    }
}
