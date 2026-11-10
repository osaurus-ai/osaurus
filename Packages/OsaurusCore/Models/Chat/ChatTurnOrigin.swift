//
//  ChatTurnOrigin.swift
//  osaurus
//
//  Marks on a turn that say how it came to be and where it ran, for the
//  first-run chat: the opening Osaurus writes from a template, and the label
//  under each reply.
//

import Foundation

/// An assistant turn no model generated.
public enum ChatTurnOrigin: String, Codable, Sendable, Equatable {
    /// Written by Osaurus from a template: the first-run opening and the
    /// lines of each setup step.
    case authored
}

/// Where a reply was generated. Set by the runtime from the model's source.
public enum ChatRunLocation: Codable, Sendable, Hashable {
    case thisMac
    case thisMacOffline
    case provider(String)
}
