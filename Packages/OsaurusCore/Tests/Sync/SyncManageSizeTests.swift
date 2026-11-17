//
//  SyncManageSizeTests.swift
//  OsaurusCoreTests
//
//  The sync core takes at most 64 KiB in one app-data value: past it a write
//  fails. The workflow library is its own message, a blob when large, and the
//  manage state is fitted under its limit before it's written.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SyncManageSizeTests {

    /// The largest library the Mac lists: `workflowLimit` workflows, each with long fields, a long
    /// last input, every step and access row.
    private static func largestLibrary() -> [SyncDeviceFeedContract.ManagedWorkflow] {
        let long = String(repeating: "w", count: 2_000)
        return (0 ..< 100).map { index in
            SyncDeviceFeedContract.ManagedWorkflow(
                id: UUID().uuidString.lowercased(),
                name: "Workflow \(index) " + String(long.prefix(80)),
                summary: String(long.prefix(500)),
                fields: (0 ..< 10).map { field in
                    SyncDeviceFeedContract.WorkflowInputField(
                        key: "field\(field)", label: long, type: "text", required: true, options: nil,
                        help: String(long.prefix(500)), default: .string(long))
                },
                prefill: ["field0": .string(String(repeating: "p", count: 20_000))],
                phoneStartable: true,
                facts: [SyncDeviceFeedContract.WorkflowChip(icon: "bolt", text: long, tone: "neutral")],
                steps: (0 ..< 30).map { step in
                    SyncDeviceFeedContract.WorkflowStep(
                        name: "Step \(step)", kind: "Uses a model and tools", icon: "cpu",
                        badges: [SyncDeviceFeedContract.WorkflowChip(icon: "clock", text: "2 min", tone: "neutral")])
                },
                outputs: [long]
            )
        }
    }

    @Test("the largest library is one message whose app data stays under the core's limit")
    func largestLibraryFits() throws {
        let library = Self.largestLibrary()
        let payload = try #require(SyncManageDetail.workflowsPayload(library))
        #expect(payload.kind == .workflows)
        #expect(payload.namespace == SyncDeviceFeedContract.manageWorkflowsNamespace)
        #expect(payload.object.count < 64 * 1024)
        // The list went to a blob, which reads back as the library.
        let object = try #require(SyncConversationMapper.parseObject(payload.object))
        let reference = try #require(object["workflows"] as? [String: Any])
        #expect(reference["$blob"] as? Int == 0)
        let decoded = try JSONDecoder().decode(
            [SyncDeviceFeedContract.ManagedWorkflow].self, from: try #require(payload.blobs.first?.bytes))
        #expect(decoded == library)
    }

    @Test("a small library sits inline, and the same library gives the same digest")
    func smallLibraryInline() throws {
        let library = Array(Self.largestLibrary().prefix(1)).map { workflow -> SyncDeviceFeedContract.ManagedWorkflow in
            var small = workflow
            small.fields = []
            small.prefill = nil
            small.steps = []
            small.facts = nil
            small.outputs = nil
            return small
        }
        let payload = try #require(SyncManageDetail.workflowsPayload(library))
        #expect(payload.blobs.isEmpty)
        #expect(SyncManageDetail.workflowsPayload(library)?.digest == payload.digest)
    }

    private static func state(models: Int, workflows: [SyncDeviceFeedContract.ManagedWorkflow]?)
        -> SyncDeviceFeedContract.ManageState
    {
        SyncDeviceFeedContract.ManageState(
            device: "mac",
            agents: [SyncDeviceFeedContract.ManagedAgent(id: "a", name: "Agent")],
            models: (0 ..< models).map {
                SyncDeviceFeedContract.ManagedModel(
                    id: "provider/model-\($0)-" + String(repeating: "m", count: 100), name: "Model \($0)",
                    provider: "Provider")
            },
            workspaceAgents: [],
            projects: [],
            plugins: [],
            workspaces: [],
            workflows: workflows,
            pushRegistered: ["phone"],
            call: nil,
            updatedMs: 1
        )
    }

    @Test("a state under the limit is written whole")
    func smallStateWhole() throws {
        let state = Self.state(models: 10, workflows: nil)
        let (written, bytes) = try SyncManageFeed.fitted(state)
        #expect(written == state)
        #expect(bytes == (try SyncHostedRunContract.encode(state)))
    }

    @Test("a state past the limit drops what the phone has elsewhere, never the agents or registrations")
    func largeStateFitted() throws {
        let state = Self.state(models: 2_000, workflows: Self.largestLibrary())
        #expect((try SyncHostedRunContract.encode(state)).count > SyncManageFeed.stateLimit)
        let (written, bytes) = try SyncManageFeed.fitted(state)
        #expect(bytes.count <= SyncManageFeed.stateLimit)
        #expect(written.workflows == nil)
        #expect(written.models.isEmpty)
        #expect(written.agents == state.agents)
        #expect(written.pushRegistered == ["phone"])
    }
}
