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
  case running
  case stopping
  case error(String)

  /// User-friendly description of the current server state
  var displayTitle: String {
    switch self {
    case .stopped: return "Server Stopped"
    case .starting: return "Starting Server..."
    case .running: return "Server Running"
    case .stopping: return "Stopping Server..."
    case .error: return "Server Error"
    }
  }

  /// Short status description
  var statusDescription: String {
    switch self {
    case .stopped: return "Stopped"
    case .starting: return "Starting..."
    case .running: return "Running"
    case .stopping: return "Stopping..."
    case .error: return "Error"
    }
  }
}
