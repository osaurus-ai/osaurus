//
//  PublishReviewState.swift
//  osaurus
//
//  Where a published listing stands with store review, derived from its
//  record. One value drives the Share sheet, the dashboard, library chips,
//  and decision notifications.
//
//  A Public submission starts unlisted: its link works right away, and the
//  store lists it once the Osaurus team approves a version. An update to a
//  listed workflow waits the same way while the approved version stays up.
//

import Foundation

public struct PublishReviewState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Unlisted or Password: nothing to review.
        case linkOnly
        /// Submitted and waiting for the Osaurus team.
        case inReview
        /// The Osaurus team asked for changes.
        case changesRequested
        /// Listed in the store.
        case listed
        case takenDown
        case removed
    }

    public let phase: Phase
    public let visibility: WorkflowVisibility
    /// The latest review, when there is one.
    public let review: WorkflowsRegistryReview?
    /// The approved version the store lists, while one is listed.
    public let listedVersion: Int?
    /// An approval or change request not opened yet.
    public let unseen: Bool

    public init(record: WorkflowRegistryRecord) {
        visibility = record.visibility
        review = record.review
        unseen = record.hasUnseenDecision
        listedVersion =
            record.isListed ? (record.liveVersion ?? record.registryLatestVersion ?? record.version) : nil
        if record.removedByAdmin {
            phase = .removed
        } else if record.takenDown {
            phase = .takenDown
        } else if record.visibility != .public {
            phase = .linkOnly
        } else {
            switch record.review?.status {
            case .pending: phase = .inReview
            case .rejected: phase = .changesRequested
            default: phase = .listed
            }
        }
    }

    /// Waiting on review or on a fix: the review step is where it stands.
    public var isUnderReview: Bool { phase == .inReview || phase == .changesRequested }

    /// In review with no approved version up: link only until approved.
    public var isUnlistedUntilApproved: Bool { isUnderReview && listedVersion == nil }

    /// The version waiting on, or decided by, review.
    public var reviewedVersion: Int? { review?.version }

    // MARK: - Copy

    /// The short label for chips: "In review", "Changes requested", …
    public var chipText: String? {
        switch phase {
        case .inReview: return L("In review")
        case .changesRequested: return L("Changes requested")
        case .linkOnly, .listed, .takenDown, .removed: return nil
        }
    }

    public var headline: String {
        switch phase {
        case .linkOnly: return L("Link only")
        case .inReview: return isUnlistedUntilApproved ? L("In review · Unlisted until approved") : L("Update in review")
        case .changesRequested:
            return isUnlistedUntilApproved ? L("Changes requested · Still unlisted") : L("Changes requested on the update")
        case .listed: return L("In the store")
        case .takenDown: return L("Taken down")
        case .removed: return L("Removed by the Osaurus team")
        }
    }

    /// One or two sentences under the headline.
    public func detail(now: Date = Date()) -> String {
        switch phase {
        case .linkOnly:
            if visibility == .workspace {
                return L("Members of the workspaces it's shared with can install it now. Workspace listings aren't listed in the store or reviewed.")
            }
            return L("The link works now. \(visibility.title) listings aren't listed in the store or reviewed.")
        case .inReview:
            let version = reviewedVersion ?? 1
            let when = Self.expectation(review)
            if let listed = listedVersion {
                return L("Version \(listed) stays in the store until version \(version) is approved. \(when)")
            }
            return L("Anyone with the link can open it now. It's listed in the store once approved. \(when)")
        case .changesRequested:
            let version = reviewedVersion ?? 1
            if let listed = listedVersion {
                return L("Version \(version) wasn't approved, so version \(listed) stays in the store. Fix it and resubmit.")
            }
            return L("Version \(version) wasn't approved, so it stays unlisted; the link still works. Fix it and resubmit to get it listed.")
        case .listed:
            return L("Version \(listedVersion ?? reviewedVersion ?? 1) is listed for everyone.")
        case .takenDown:
            return L("Its page no longer works. Publish again to bring it back.")
        case .removed:
            return L("The Osaurus team took this down. It can't be published again.")
        }
    }

    /// "Usually reviewed within 24 hours."
    static func expectation(_ review: WorkflowsRegistryReview?) -> String {
        guard let hours = review?.expectedWithinHours, hours > 0 else { return L("Reviews usually take a day.") }
        return hours == 1 ? L("Usually reviewed within an hour.") : L("Usually reviewed within \(hours) hours.")
    }

    /// The Public option's promise in the publish step.
    public static var publicReviewNote: String {
        L("Reviewed by the Osaurus team before it's listed, usually within 24 hours. Until then it's unlisted: your link works right away.")
    }
}
