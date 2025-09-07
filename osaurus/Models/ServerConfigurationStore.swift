//
//  ServerConfigurationStore.swift
//  osaurus
//
//  Created by Terence on 8/31/25.
//

import Foundation

/// Handles persistence of `ServerConfiguration` to Application Support
enum ServerConfigurationStore {
  /// Optional directory override for tests. When set, the store reads/writes here.
  static var overrideDirectory: URL?
  /// Shared access pattern; use static functions for simplicity
  static func load() -> ServerConfiguration? {
    let url = configurationFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      return try decoder.decode(ServerConfiguration.self, from: data)
    } catch {
      print("[Osaurus] Failed to load ServerConfiguration: \(error)")
      return nil
    }
  }

  static func save(_ configuration: ServerConfiguration) {
    let url = configurationFileURL()
    do {
      try ensureDirectoryExists(url.deletingLastPathComponent())
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(configuration)
      try data.write(to: url, options: [.atomic])
    } catch {
      print("[Osaurus] Failed to save ServerConfiguration: \(error)")
    }
  }

  // MARK: - Private

  private static func configurationFileURL() -> URL {
    if let overrideDirectory {
      return overrideDirectory.appendingPathComponent("ServerConfiguration.json")
    }
    let fm = FileManager.default
    let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
    return supportDir.appendingPathComponent(bundleId, isDirectory: true)
      .appendingPathComponent("ServerConfiguration.json")
  }

  private static func ensureDirectoryExists(_ url: URL) throws {
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }
}
