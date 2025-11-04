//
//  ToolRegistryStockTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import osaurus

struct ToolRegistryStockTests {

  @Test func listTools_containsStock_and_togglePersists() async throws {
    // Use a temp directory for configuration persistence to avoid polluting user dirs
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    await MainActor.run { ToolConfigurationStore.overrideDirectory = temp }

    // First access of shared will initialize with current configuration (now overridden)
    let entries1 = await MainActor.run { ToolRegistry.shared.listTools() }
    #expect(entries1.contains { $0.name == "stock" })

    // Disable the tool and verify state changes
    await MainActor.run { ToolRegistry.shared.setEnabled(false, for: "stock") }
    let entries2 = await MainActor.run { ToolRegistry.shared.listTools() }
    #expect(entries2.first { $0.name == "stock" }?.enabled == false)

    // Specs should not include stock when disabled
    let specsWhenDisabled = await MainActor.run { ToolRegistry.shared.specs() }
    #expect(specsWhenDisabled.contains { $0.function.name == "stock" } == false)

    // Re-enable to leave environment clean
    await MainActor.run { ToolRegistry.shared.setEnabled(true, for: "stock") }
  }
}
