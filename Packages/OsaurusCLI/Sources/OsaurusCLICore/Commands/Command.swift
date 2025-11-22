//
//  Command.swift
//  osaurus
//
//  Protocol defining the interface for CLI commands. All commands must implement this protocol.
//

import Foundation

public protocol Command {
    static var name: String { get }
    static func execute(args: [String]) async
}
