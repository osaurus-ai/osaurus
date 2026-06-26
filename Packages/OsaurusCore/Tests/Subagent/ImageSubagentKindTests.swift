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
}
