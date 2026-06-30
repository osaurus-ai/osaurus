//
//  ImageSubagentKindTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the merged `image` tool: the `source_paths` → edit
//  routing decision, argument clamping, and the `ImageSubagentKind` descriptor
//  shape (capability, handoff, mode-aware feed title). The job itself needs a
//  runtime, but the routing/parsing contract — the part that decides generate
//  vs edit — is pure and is pinned here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Image subagent routing + shape")
struct ImageSubagentKindTests {

    @Test("no source_paths → generate mode")
    func noSourcePathsGenerates() {
        let params = ImageTool.buildParams(args: ["prompt": "a cat"], prompt: "a cat")
        #expect(params.sourcePaths.isEmpty)
        #expect(params.isEdit == false)
    }

    @Test("non-empty source_paths → edit mode, paths trimmed")
    func sourcePathsSwitchToEdit() {
        let params = ImageTool.buildParams(
            args: ["prompt": "make it blue", "source_paths": ["  /tmp/a.png ", "/tmp/b.png"]],
            prompt: "make it blue"
        )
        #expect(params.isEdit)
        #expect(params.sourcePaths == ["/tmp/a.png", "/tmp/b.png"])
    }

    @Test("whitespace-only source_paths are dropped → generate mode")
    func blankSourcePathsFallBackToGenerate() {
        let params = ImageTool.buildParams(
            args: ["prompt": "a dog", "source_paths": ["   ", ""]],
            prompt: "a dog"
        )
        #expect(params.sourcePaths.isEmpty)
        #expect(params.isEdit == false)
    }

    @Test("dimensions clamp to 256...1024 on a 16px grid; steps + guidance clamp")
    func numericClamping() {
        let params = ImageTool.buildParams(
            args: [
                "prompt": "x",
                "width": 99,  // below floor → 256
                "height": 5000,  // above ceiling → 1024
                "steps": 999,  // → 50
                "guidance": 999.0,  // → 20
            ],
            prompt: "x"
        )
        #expect(params.width == 256)
        #expect(params.height == 1024)
        #expect(params.steps == 50)
        #expect(params.guidance == 20)
    }

    @Test("the kind descriptor exposes the single image tool and skips host handoff")
    func kindShape() {
        let gen = ImageSubagentKind(
            params: ImageTool.buildParams(args: ["prompt": "a cat"], prompt: "a cat"),
            argumentsJSON: "{}"
        )
        #expect(gen.capability.id == "image")
        #expect(gen.capability.toolNames == ["image"])
        // Images use a dedicated configured model, but keep residency authority
        // inside the coordinator, so the host middleware must NOT run the
        // handoff for this kind (`makeHandoff()` stays passthrough).
        #expect(gen.capability.modelSource == .dedicatedConfigured)
        #expect(gen.feedTitle.contains("image"))
        #expect(!gen.feedTitle.contains("edit"))
    }

    @Test("edit mode is reflected in the live feed title")
    func editFeedTitle() {
        let edit = ImageSubagentKind(
            params: ImageTool.buildParams(
                args: ["prompt": "recolor", "source_paths": ["/tmp/a.png"]],
                prompt: "recolor"
            ),
            argumentsJSON: "{}"
        )
        #expect(edit.feedTitle.contains("edit"))
    }

    // MARK: - Per-agent permission (model-free)

    /// The `permission` step resolves its policy per-agent via the shared
    /// `effectivePermission` resolver. The Default / main chat reads the GLOBAL
    /// permission map, so a `.deny` there must turn into a policy `.denied`
    /// decision for BOTH generate and edit — without ever invoking the runtime
    /// (the model is chosen in the tab now, so the prompt is a plain
    /// allow/deny/always). This pins the kind→resolver wiring without an image
    /// model present.
    @Test("main chat image .deny → policy-denied for generate + edit (no prompt)")
    func mainChatImagePermissionDeny() async {
        let lease = await acquireSubagentStoreSandbox("image-permission-deny")
        defer { lease.release() }
        var perms = SubagentPermissionDefaults()
        perms.setPolicy(.deny, for: SubagentCapabilityRegistry.image.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(permissionDefaults: perms)
        )

        let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
        let resolved = ResolvedModel(name: "test-model", isLocal: true)

        let gen = ImageSubagentKind(
            params: ImageTool.buildParams(args: ["prompt": "a cat"], prompt: "a cat"),
            argumentsJSON: "{}"
        )
        let genDecision = await gen.permission(scope, resolved)
        #expect(
            genDecision == .denied("Image generation is denied by this agent's permission settings.")
        )

        let edit = ImageSubagentKind(
            params: ImageTool.buildParams(
                args: ["prompt": "recolor", "source_paths": ["/tmp/a.png"]],
                prompt: "recolor"
            ),
            argumentsJSON: "{}"
        )
        let editDecision = await edit.permission(scope, resolved)
        #expect(editDecision == .denied("Image edit is denied by this agent's permission settings."))
    }

    /// The complementary always-allow path: a `.alwaysAllow` policy proceeds
    /// straight to `.allow` with no interactive prompt (the "always allow" the
    /// agent set in its Subagents tab).
    @Test("main chat image .alwaysAllow → allow without a prompt")
    func mainChatImagePermissionAlwaysAllow() async {
        let lease = await acquireSubagentStoreSandbox("image-permission-always")
        defer { lease.release() }
        var perms = SubagentPermissionDefaults()
        perms.setPolicy(.alwaysAllow, for: SubagentCapabilityRegistry.image.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(permissionDefaults: perms)
        )

        let scope = SubagentScope(sessionId: "s", toolCallId: "t", agentId: Agent.defaultId)
        let resolved = ResolvedModel(name: "test-model", isLocal: true)
        let gen = ImageSubagentKind(
            params: ImageTool.buildParams(args: ["prompt": "a cat"], prompt: "a cat"),
            argumentsJSON: "{}"
        )
        let decision = await gen.permission(scope, resolved)
        #expect(decision == .allow)
    }
}
