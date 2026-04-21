//
//  ServerHealth.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

/// Represents the health state of the server
public enum ServerHealth: Equatable {
    case stopped
    case starting
    case restarting
    case running
    case stopping
    case error(String)

    /// User-friendly description of the current server state
    var displayTitle: String {
        switch self {
        case .stopped: return L("Server Stopped")
        case .starting: return L("Starting Server...")
        case .restarting: return L("Restarting Server...")
        case .running: return L("Server Running")
        case .stopping: return L("Stopping Server...")
        case .error: return L("Server Error")
        }
    }

    /// Short status description
    var statusDescription: String {
        switch self {
        case .stopped: return L("Stopped")
        case .starting: return L("Starting...")
        case .restarting: return L("Restarting...")
        case .running: return L("Running")
        case .stopping: return L("Stopping...")
        case .error: return L("Error")
        }
    }
}
