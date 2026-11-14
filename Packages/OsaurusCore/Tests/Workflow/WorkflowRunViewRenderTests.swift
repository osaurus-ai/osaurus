//
//  WorkflowRunViewRenderTests.swift
//  osaurusTests
//
//  Renders a run's step list with a step open (long JSON output, a log,
//  retries) in a real hosting window at a sidebar width and a tab width,
//  and checks the JSON block stays inside its frame: the rows below it
//  must not be drawn over. Set `WORKFLOW_RENDER_DIR=/some/dir` to also
//  write each render as a PNG for review.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct WorkflowRunViewRenderTests {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, _ view: V) async throws
        -> NSBitmapImageRep
    {
        let theme: ThemeProtocol = CustomizableTheme.dark()
        let root = view
            .frame(width: width, height: height, alignment: .topLeading)
            .background(theme.surface.canvas)
            .environment(\.theme, theme)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["WORKFLOW_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(Int(width)).png"))
        }
        return rep
    }

    static let longOutput: JSONValue = .object([
        "backend": .string("local"), "count": .number(1), "duration_ms": .number(26922),
        "images": .array([
            .object([
                "effective_parameters": .object([
                    "guidance": .number(1), "height": .number(512), "sampler": .string("euler"),
                    "scheduler": .string("qwen-image-2.1"), "seed": .number(475_333_398), "shift": .number(0.54),
                    "steps": .number(20), "width": .number(512),
                ]),
                "format": .string("png"), "height": .number(512),
                "path": .string("/Users/someone/.osaurus/workflows/67d6c752-7479-4642-a5ca-54ab06/run/avatar-1.png"),
                "seed": .number(475_333_398), "width": .number(512),
            ])
        ]),
        "model": .string("Qwen-Image-2.1"), "videos": .array([]),
    ])

    /// The bands above and below a JSON block hold only their own text: a
    /// block that spills draws its lines into them.
    @Test func jsonBlock_staysInsideItsFrame() async throws {
        for width in [CGFloat(340), 680] {
            let rep = try await Self.render(
                "json-block", width: width, height: 520,
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 150)
                    WorkflowJSONText(text: Self.longOutput.prettyJSONString, maxHeight: 220)
                    Color.clear.frame(height: 150)
                }
                .frame(maxWidth: .infinity, alignment: .leading))
            let scale = CGFloat(rep.pixelsHigh) / 520
            #expect(Self.inkRows(rep, from: 0, to: Int(140 * scale)) == 0, "JSON drew above its frame @\(Int(width))")
            #expect(
                Self.inkRows(rep, from: Int(380 * scale), to: rep.pixelsHigh) == 0,
                "JSON drew below its frame @\(Int(width))")
        }
    }

    /// Six steps like the character-card starter: four done, the image step
    /// done after two failed attempts and opened, the last one working.
    static func characterCardRun() throws -> (WorkflowRun, WorkflowDefinition) {
        let ids = ["form", "dice", "persona", "prompts", "avatar", "card"]
        let names = ["Character form", "Roll the dice of fate", "Write the persona", "Paint prompts", "Avatar", "Playing card"]
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: zip(ids, names).map { id, name in
                var node = WF.code(id)
                node.name = name
                return node
            },
            edges: zip(ids, ids.dropFirst()).map { WorkflowEdge(from: $0, to: $1) },
            output: .object([:]))
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Character Card", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .user), input: .object([:]), nodeIDs: ids)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        run.startedAt = start
        for (i, id) in ids.dropLast().enumerated() {
            run.update(id) {
                $0.status = .done
                $0.attempts = 1
                $0.startedAt = start.addingTimeInterval(Double(i) * 30)
                $0.finishedAt = start.addingTimeInterval(Double(i) * 30 + 12)
            }
        }
        run.update("persona") { $0.model = "OsaurusAI/Qwen3.8-27B-JANG_6D" }
        let image = WF.tempDir().appendingPathComponent("avatar-1.png")
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<64 { for y in 0..<64 { bitmap.setColor(NSColor(hue: CGFloat(x) / 64, saturation: 0.6, brightness: CGFloat(y) / 64 + 0.3, alpha: 1), atX: x, y: y) } }
        try bitmap.representation(using: .png, properties: [:])?.write(to: image)
        run.update("avatar") {
            $0.attempts = 3
            $0.model = "Qwen-Image-2.1"
            $0.input = .object([:])
            $0.output = longOutput
            $0.logs = [
                "Attempt 1 failed: Qwen-Image-2.1 waited for local work to finish: Write the persona",
                "Attempt 2 failed: Qwen-Image-2.1 waited for local work to finish: Write the persona",
                "Model: Qwen-Image-2.1 (this Mac)", "seed 475333398 (random) · 512×512 · 20 steps",
                "Made 1 file in 27 s.",
            ]
        }
        run.artifacts = [
            WorkflowArtifact(
                source: .generated, nodeID: "avatar", filename: "avatar-1.png", path: image.path, fileSize: 1)
        ]
        run.update("card") {
            $0.status = .running
            $0.startedAt = start.addingTimeInterval(150)
            $0.progress = WorkflowNodeProgress(fraction: 0.15, detail: "Image step 3 of 20 · ~66s left")
        }
        return (run, def)
    }

    @Test func runView_oneStepListWithAnOpenStep() async throws {
        let (run, def) = try Self.characterCardRun()
        for width in [CGFloat(340), 680] {
            let rep = try await Self.render(
                "run-view", width: width, height: 1100,
                ScrollView {
                    WorkflowRunView(run: run, definition: def, showsOutput: false, initiallyOpen: ["avatar"])
                        .padding(16)
                })
            #expect(rep.pixelsWide > 0)
        }
    }

    /// The Architect's Test section at its narrowest: long step names and
    /// durations share a row without either breaking a word per line.
    @Test func runView_narrowSidebarWithLongNames() async throws {
        var (run, def) = try Self.characterCardRun()
        var named = def
        let long = [
            "Choose the visual direction", "Apply a reliable color palette", "Prepare exact-size artwork",
            "Render both sides", "Check the bleed and trim", "Export the print-ready PDF",
        ]
        for (i, name) in long.enumerated() { named.nodes[i].name = name }
        run.update("prompts") {
            $0.input = .object(["command": .string("export INVOICE_ENCODING=utf-8 && node render.js --size 3.5x2in")])
            $0.output = .object([
                "cwd": .string("/workspace/agents/workflows/invoice/run"), "exit_code": .number(0),
                "stderr": .string(""),
            ])
        }
        for width in [CGFloat(220), 280] {
            for open in [Set<String>(), ["prompts"]] {
                let rep = try await Self.render(
                    open.isEmpty ? "run-view-sidebar" : "run-view-sidebar-open", width: width, height: 640,
                    ScrollView {
                        WorkflowRunView(
                            run: run, definition: named, showsOutput: false, header: .timing, initiallyOpen: open
                        )
                        .padding(12)
                    })
                #expect(rep.pixelsWide > 0)
            }
        }
    }

    /// Agent steps: one asking a teammate's agent, still working; one done
    /// that needs more information, with its conversation to open.
    @Test func runView_agentStepsSayWhoTheyAskAndOpenTheirConversation() async throws {
        let ref = WorkspaceAgentRef(workspaceId: "ws_1", agentAddress: "0xagent")
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(id: "ask", name: "Ask Research", kind: .agent(AgentNodeSpec(agent: "Research", task: "x")), timeout: 600),
                WorkflowNode(
                    id: "remote", name: "Ask Ana's agent",
                    kind: .agent(AgentNodeSpec(agent: "Ana's Research", workspace: ref, task: "y")), timeout: 600),
            ],
            edges: [WorkflowEdge(from: "ask", to: "remote")], output: .object([:]))
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Digest", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .user), input: .object([:]), nodeIDs: ["ask", "remote"])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UUID()
        run.update("ask") {
            $0.status = .done
            $0.startedAt = start
            $0.finishedAt = start.addingTimeInterval(40)
            $0.output = .object([
                "text": .string("Which year?"), "agent": .string("Research"),
                "session_id": .string(session.uuidString), "needs_input": .bool(true),
            ])
        }
        run.update("remote") {
            $0.status = .running
            $0.startedAt = start.addingTimeInterval(40)
            $0.progress = WorkflowNodeProgress(fraction: nil, detail: "Asking Ana's Research on a teammate's Mac")
        }

        let askNode = try #require(run.node("ask"))
        let done = try #require(WorkflowRunView.agentStep(askNode, definition: def))
        #expect(done == .init(agent: "Research", isShared: false, sessionID: session, needsInput: true, timeout: 600))
        #expect(WorkflowRunView.askingText(done, node: askNode, now: start) == nil)
        let remoteNode = try #require(run.node("remote"))
        let remote = try #require(WorkflowRunView.agentStep(remoteNode, definition: def))
        #expect(remote.isShared && remote.sessionID == nil)
        #expect(
            WorkflowRunView.askingText(remote, node: remoteNode, now: start.addingTimeInterval(104))
                == "Asking Ana's Research on a teammate's Mac · 1m 4s of 10m 0s")
        #expect(WorkflowRunView.agentStep(askNode, definition: nil) == nil)

        for width in [CGFloat(280), 680] {
            let rep = try await Self.render(
                "run-view-agent-steps", width: width, height: 320,
                ScrollView {
                    WorkflowRunView(run: run, definition: def, showsOutput: false).padding(12)
                })
            #expect(rep.pixelsWide > 0)
        }
    }

    /// Rows of pixels that differ from the canvas colour in the band.
    private static func inkRows(_ rep: NSBitmapImageRep, from: Int, to: Int) -> Int {
        guard let background = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else { return 0 }
        var rows = 0
        for y in stride(from: max(0, from), to: min(rep.pixelsHigh, to), by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - background.redComponent) + abs(c.greenComponent - background.greenComponent)
                    + abs(c.blueComponent - background.blueComponent) > 0.15
                {
                    rows += 1
                    break
                }
            }
        }
        return rows
    }
}
