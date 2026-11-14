import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Plugin tool execution ownership", .serialized, .timeLimit(.minutes(1)))
struct ResponsesPluginToolWaitTests {
    private struct CancellableTool: OsaurusTool {
        let name: String
        let started: OSAllocatedUnfairLock<Bool>
        let finished: OSAllocatedUnfairLock<Bool>
        let description = "No-IO cancellable wait fixture"
        let parameters: JSONValue? = .object(["type": .string("object")])
        var bypassRegistryTimeout: Bool { true }
        func execute(argumentsJSON: String) async throws -> String {
            started.withLock { $0 = true }
            defer { finished.withLock { $0 = true } }
            do {
                try await Task.sleep(for: .seconds(100))
                return ToolEnvelope.success(tool: name, text: "completed")
            } catch {
                // Real terminal/process cleanup may outlast cancellation.
                // Keep this deterministic and short without ignoring cleanup.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        continuation.resume()
                    }
                }
                throw error
            }
        }
    }

    @Test @MainActor
    func cancellationDuringBypassToolWaitIsNotReportedAsTimeout() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let name = "responses_wait_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        ToolRegistry.shared.register(CancellableTool(name: name, started: started, finished: finished))
        ToolRegistry.shared.setEnabled(true, for: name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: name)
            ToolRegistry.shared.unregister(names: [name])
        }
        let task = Task.detached {
            await PluginHostContext.executeToolCall(name: name, argumentsJSON: "{}")
        }
        let until = ContinuousClock.now + .seconds(2)
        while !started.withLock({ $0 }), ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let text = await task.value
        let body = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(started.withLock { $0 })
        #expect(finished.withLock { $0 })
        #expect(body["kind"] as? String == "execution_error")
        #expect(body["retryable"] as? Bool == false)
        #expect((body["message"] as? String)?.contains("cancelled") == true)
    }
}
