//
//  WorkBatchTool.swift
//  osaurus
//
//  A generic batch tool that executes multiple registered tool operations in sequence.
//  Solves the bounded execution limit for bulk operations like file organization.
//

import Foundation

// MARK: - Batch Tool

/// Tool for executing multiple operations in a single call
struct WorkBatchTool: OsaurusTool {
    let name = "batch"
    let description = "Execute multiple tool operations in sequence (max 30). Continues on error and reports results."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "operations": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "tool": .object([
                            "type": .string("string"),
                            "description": .string("Name of the tool to execute"),
                        ]),
                        "args": .object([
                            "type": .string("object"),
                            "description": .string("Arguments to pass to the tool"),
                        ]),
                    ]),
                    "required": .array([.string("tool"), .string("args")]),
                ]),
                "description": .string("Array of tool operations to execute (max 30)"),
            ])
        ]),
        "required": .array([.string("operations")]),
    ])

    // MARK: - Configuration

    /// Tools that cannot be batched
    private static let denyList: Set<String> = [
        "shell_run",  // Dangerous, unknown side effects
        "git_commit",  // Sequential by nature, requires careful ordering
        "batch",  // No nesting allowed
    ]

    /// Maximum operations per batch
    private static let maxOperations = 30

    /// Error indicators in tool output (some tools return errors as strings instead of throwing)
    private static let errorPrefixes = ["error", "failed", "unable to", "cannot "]
    private static let errorSubstrings = ["not found", "does not exist"]

    // MARK: - Initialization

    private let rootPath: URL

    init(rootPath: URL) {
        self.rootPath = rootPath
    }

    // MARK: - Execution

    func execute(argumentsJSON: String) async throws -> String {
        let operations = try parseOperations(argumentsJSON)
        let batchId = UUID()

        // Request batch approval for tools that need it
        let approvedTools = await requestApprovalIfNeeded(for: operations)

        // Execute all operations
        var results: [Result] = []
        for op in operations {
            let result = await executeOperation(op, batchId: batchId, approvedTools: approvedTools)
            results.append(result)
        }

        return formatOutput(batchId: batchId, results: results)
    }

    // MARK: - Parsing

    private struct Operation {
        let index: Int
        let tool: String
        let argsJSON: String
        let isDenied: Bool
    }

    private func parseOperations(_ argumentsJSON: String) throws -> [Operation] {
        let args = try WorkFolderToolHelpers.parseArguments(argumentsJSON)

        guard let operationsArray = args["operations"] as? [[String: Any]] else {
            throw WorkFolderToolError.invalidArguments("Missing required parameter: operations")
        }

        guard !operationsArray.isEmpty else {
            throw WorkFolderToolError.invalidArguments("Operations array cannot be empty")
        }

        guard operationsArray.count <= Self.maxOperations else {
            throw WorkFolderToolError.invalidArguments(
                "Too many operations: \(operationsArray.count). Maximum is \(Self.maxOperations)."
            )
        }

        return try operationsArray.enumerated().map { index, op in
            guard let tool = op["tool"] as? String else {
                throw WorkFolderToolError.invalidArguments("Operation \(index + 1): missing 'tool' field")
            }
            guard let toolArgs = op["args"] else {
                throw WorkFolderToolError.invalidArguments("Operation \(index + 1): missing 'args' field")
            }

            let argsData = try JSONSerialization.data(withJSONObject: toolArgs)
            let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"

            return Operation(
                index: index + 1,
                tool: tool,
                argsJSON: argsJSON,
                isDenied: Self.denyList.contains(tool)
            )
        }
    }

    // MARK: - Approval

    private func requestApprovalIfNeeded(for operations: [Operation]) async -> Set<String> {
        // Count tools requiring approval (excluding denied tools)
        var toolCounts: [String: Int] = [:]
        for op in operations where !op.isDenied {
            if let info = await ToolRegistry.shared.policyInfo(for: op.tool),
                info.effectivePolicy == .ask
            {
                toolCounts[op.tool, default: 0] += 1
            }
        }

        guard !toolCounts.isEmpty else { return [] }

        // If batch tool is set to auto, skip approval dialog
        if let batchInfo = await ToolRegistry.shared.policyInfo(for: "batch"),
            batchInfo.effectivePolicy == .auto
        {
            return Set(toolCounts.keys)
        }

        // Build approval description
        var lines = ["Batch contains operations requiring approval:"]
        for (tool, count) in toolCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("  - \(tool): \(count) operation\(count == 1 ? "" : "s")")
        }

        let approved = await ToolPermissionPromptService.requestApproval(
            toolName: "batch",
            description: lines.joined(separator: "\n"),
            argumentsJSON: "{}"
        )

        return approved ? Set(toolCounts.keys) : []
    }

    // MARK: - Operation Execution

    private struct Result {
        let index: Int
        let tool: String
        let success: Bool
        let message: String
    }

    private func executeOperation(
        _ op: Operation,
        batchId: UUID,
        approvedTools: Set<String>
    ) async -> Result {
        // Handle denied tools
        if op.isDenied {
            return Result(
                index: op.index,
                tool: op.tool,
                success: false,
                message: "Tool '\(op.tool)' is not allowed in batch operations"
            )
        }

        // Check tool policy and registration
        guard let info = await ToolRegistry.shared.policyInfo(for: op.tool) else {
            return Result(
                index: op.index,
                tool: op.tool,
                success: false,
                message: "Tool '\(op.tool)' is not registered"
            )
        }

        // Check if approval was denied for .ask policy tools
        if info.effectivePolicy == .ask, !approvedTools.contains(op.tool) {
            return Result(
                index: op.index,
                tool: op.tool,
                success: false,
                message: "Approval denied"
            )
        }

        // Check if tool is explicitly denied
        if info.effectivePolicy == .deny {
            return Result(
                index: op.index,
                tool: op.tool,
                success: false,
                message: "Tool '\(op.tool)' is denied by policy"
            )
        }

        // Execute the tool - always pass override to bypass config check for batch operations
        // This ensures folder tools work even if not explicitly enabled in persisted config
        do {
            let output = try await WorkExecutionContext.$currentBatchId.withValue(batchId) {
                try await ToolRegistry.shared.execute(
                    name: op.tool,
                    argumentsJSON: op.argsJSON,
                    overrides: [op.tool: true]  // Always enable for batch execution
                )
            }

            let isError = Self.isErrorResult(output)
            return Result(
                index: op.index,
                tool: op.tool,
                success: !isError,
                message: truncate(output)
            )
        } catch {
            return Result(
                index: op.index,
                tool: op.tool,
                success: false,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Output Formatting

    private func formatOutput(batchId: UUID, results: [Result]) -> String {
        let succeeded = results.filter(\.success).count
        let failed = results.count - succeeded

        // Make failures more prominent so the AI recognizes the batch didn't work
        var lines: [String]
        if failed > 0 && succeeded == 0 {
            lines = ["ERROR: Batch failed - all \(failed) operation(s) failed", ""]
        } else if failed > 0 {
            lines = ["WARNING: Batch partial - \(succeeded) succeeded, \(failed) failed", ""]
        } else {
            lines = ["Batch complete: \(succeeded) succeeded", ""]
        }

        for result in results {
            let icon = result.success ? "✓" : "✗"
            lines.append("[\(result.index)] \(icon) \(result.tool): \(result.message)")
        }

        lines.append("")
        lines.append("Batch ID: \(batchId.uuidString)")

        return lines.joined(separator: "\n")
    }

    private func truncate(_ text: String, maxLength: Int = 100) -> String {
        let firstLine =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? text

        if firstLine.count > maxLength {
            return String(firstLine.prefix(maxLength - 3)) + "..."
        }
        return firstLine
    }

    private static func isErrorResult(_ result: String) -> Bool {
        let lower = result.lowercased()
        return errorPrefixes.contains { lower.hasPrefix($0) }
            || errorSubstrings.contains { lower.contains($0) }
    }
}
