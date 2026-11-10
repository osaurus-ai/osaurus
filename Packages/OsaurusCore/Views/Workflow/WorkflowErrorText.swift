//
//  WorkflowErrorText.swift
//  osaurus
//
//  An error in words for the Workflows screens: a typed error's own
//  description, a system error's message, and otherwise "Something went
//  wrong" with the error's name, never "The operation couldn't be
//  completed. (OsaurusCore.SomeError error 2.)".
//

import Foundation

enum WorkflowErrorText {
    static func text(_ error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        let ns = error as NSError
        // Swift errors bridge with their qualified type name as the domain
        // and a description that names only the type and case number.
        if ns.domain.contains(".") && !ns.domain.hasPrefix("NS") && !ns.domain.hasPrefix("com.apple") {
            let name = ns.domain.split(separator: ".").last.map(String.init) ?? ns.domain
            return L("Something went wrong (\(name) \(ns.code)).")
        }
        return ns.localizedDescription
    }

    /// Runs a save the person asked for; a failure shows as a toast titled
    /// `title` (already localized) instead of looking like it worked.
    @MainActor
    static func saving(_ title: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            _ = ToastManager.shared.error(title, message: text(error))
        }
    }
}
