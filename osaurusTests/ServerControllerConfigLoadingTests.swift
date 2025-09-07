//
//  ServerControllerConfigLoadingTests.swift
//  osaurusTests
//

import XCTest

@testable import osaurus

@MainActor
final class ServerControllerConfigLoadingTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base.appendingPathComponent(
      "osaurus-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDir = dir
    ServerConfigurationStore.overrideDirectory = dir
  }

  override func tearDown() async throws {
    ServerConfigurationStore.overrideDirectory = nil
    if let tempDir {
      try? FileManager.default.removeItem(at: tempDir)
    }
    tempDir = nil
  }

  func testControllerLoadsSavedConfigurationOnInit() async throws {
    var config = ServerConfiguration.default
    config.port = 4242
    config.exposeToNetwork = true
    ServerConfigurationStore.save(config)

    let controller = ServerController()
    XCTAssertEqual(controller.configuration.port, 4242)
    XCTAssertEqual(controller.configuration.exposeToNetwork, true)
  }
}
