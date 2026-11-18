//
//  PublishReviewBrief.swift
//  osaurus
//
//  What "Revise with Architect" says when the Osaurus team asked for
//  changes before listing a workflow in the store.
//

import Foundation

enum PublishReviewBrief {
    /// The person's message to the Architect, in their words, quoting the
    /// reviewer.
    static func message(name: String, review: WorkflowsRegistryReview) -> String {
        guard let note = review.note else {
            return L(
                "The Osaurus team asked for changes to version \(review.version) of “\(name)” before listing it in the store, without a note. Look it over for what a reviewer would flag and fix it."
            )
        }
        let quoted = note.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
            .joined(separator: "\n")
        return L(
            "The Osaurus team asked for changes to version \(review.version) of “\(name)” before listing it in the store:\n\n\(quoted)\n\nFix that."
        )
    }

    /// The sidebar note that rides with the message.
    static func note(name: String, review: WorkflowsRegistryReview) -> String {
        "The user is revising \"\(name)\" because store review requested changes on version \(review.version)"
            + (review.note.map { ": \"\($0)\"" } ?? " (no message)")
            + ". Address the request, test the change, and propose saving the next version; once saved they "
            + "resubmit it for review."
    }
}
