//
//  SharedConfigurationService.swift
//  osaurus
//
//  Created by Terence on 9/8/25.
//

import Foundation

/// Publishes runtime server configuration for discovery by other processes
@MainActor
final class SharedConfigurationService {
  static let shared = SharedConfigurationService()

  /// Unique identifier for this app run
  private let instanceId: String

  private init() {
    self.instanceId = UUID().uuidString
  }

  /// Base directory for shared configurations
  private func baseDirectoryURL() -> URL? {
    guard
      let appSupportURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else {
      return nil
    }
    let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
    // Parent directory remains stable so external tools can enumerate instances
    return
      appSupportURL
      .appendingPathComponent(bundleId, isDirectory: true)
      .appendingPathComponent("SharedConfiguration", isDirectory: true)
  }

  /// Directory for this running instance
  private func instanceDirectoryURL() -> URL? {
    guard let base = baseDirectoryURL() else { return nil }
    return base.appendingPathComponent(instanceId, isDirectory: true)
  }

  /// Ensure directories exist
  private func ensureDirectories() -> URL? {
    guard let base = baseDirectoryURL(), let instance = instanceDirectoryURL() else { return nil }
    do {
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
      return instance
    } catch {
      print("[Osaurus] SharedConfigurationService: failed to create directories: \(error)")
      return nil
    }
  }

  /// Update or remove the shared configuration based on server health
  func update(health: ServerHealth, configuration: ServerConfiguration, localAddress: String) {
    guard let instanceDir = ensureDirectories() else { return }

    let fileURL = instanceDir.appendingPathComponent("configuration.json")

    switch health {
    case .running:
      let values: [String: Any] = [
        "instanceId": instanceId,
        "updatedAt": ISO8601DateFormatter().string(from: Date()),
        "port": configuration.port,
        "address": localAddress,
        "url": "http://\(localAddress):\(configuration.port)",
        "exposeToNetwork": configuration.exposeToNetwork,
        "health": "running",
      ]
      do {
        let jsonData = try JSONSerialization.data(
          withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: fileURL, options: [.atomic])
        // Touch base directory mtime for discoverability of latest instance
        _ = try? FileManager.default.setAttributes(
          [.modificationDate: Date()], ofItemAtPath: instanceDir.path)
      } catch {
        print("[Osaurus] SharedConfigurationService: failed to write configuration: \(error)")
      }
    case .starting:
      // Publish minimal metadata while starting
      let values: [String: Any] = [
        "instanceId": instanceId,
        "updatedAt": ISO8601DateFormatter().string(from: Date()),
        "health": "starting",
      ]
      do {
        let jsonData = try JSONSerialization.data(
          withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: fileURL, options: [.atomic])
      } catch {
        print(
          "[Osaurus] SharedConfigurationService: failed to write starting configuration: \(error)")
      }
    case .stopped, .stopping, .error:
      // Remove the file to indicate this instance is not serving
      remove()
    }
  }

  /// Remove this instance's shared files
  func remove() {
    guard let instance = instanceDirectoryURL() else { return }
    do {
      if FileManager.default.fileExists(atPath: instance.path) {
        try FileManager.default.removeItem(at: instance)
        print(
          "[Osaurus] SharedConfigurationService: removed instance directory at \(instance.path)")
      }
    } catch {
      print("[Osaurus] SharedConfigurationService: failed to remove instance directory: \(error)")
    }
  }
}
