//
//  Events.swift
//  osaurus
//
//  Typed events emitted by the unified generation pipeline.
//

import Foundation

enum ModelRuntimeEvent: Sendable {
    case tokens(String)
    case toolInvocation(name: String, argsJSON: String)
}
