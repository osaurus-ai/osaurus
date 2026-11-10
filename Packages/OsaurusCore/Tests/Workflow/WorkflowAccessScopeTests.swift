//
//  WorkflowAccessScopeTests.swift
//  OsaurusCoreTests
//
//  What a workflow touches on this Mac, read from its definition, and the
//  words every surface says about it.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowAccessScopeTests {

    static let folderInput: JSONValue = .object(["type": .string("string"), "format": .string("folder"), "title": .string("Folder")])

    static func toolNode(_ id: String, _ tool: String, _ input: [String: String]) -> WorkflowNode {
        WorkflowNode(id: id, name: id, kind: .tool(ToolNodeSpec(tool: ToolRef(name: tool))), input: .object(input))
    }

    /// Copies each SVG into the workspace, converts it in the sandbox, and
    /// copies the PNG to a `png` folder next to the originals.
    static func svgToPNG() -> WorkflowDefinition {
        let body: JSONValue = .object([
            "name": .string("Deliver"),
            "kind": .string("tool"),
            "tool": .string("file_copy"),
            "input": .object([
                "source": .string("out/{{item.name}}.png"),
                "destination": .string("{{input.folder}}/png/{{item.name}}.png"),
            ]),
        ])
        return WorkflowDefinition(
            inputSchema: WF.object(["folder": folderInput], required: ["folder"]),
            nodes: [
                toolNode("list", "file_search", ["path": "{{input.folder}}", "pattern": "*.svg"]),
                toolNode("stage", "file_copy", ["source": "{{input.folder}}/a.svg", "destination": "a.svg"]),
                toolNode("convert", "shell_run", ["command": "rsvg-convert a.svg -o a.png"]),
                WorkflowNode(
                    id: "deliver", name: "Deliver",
                    kind: .map(MapSpec(items: "{{nodes.list.output.files}}", step: body))),
            ],
            dependencies: [WorkflowDependency(manager: .apk, packages: ["librsvg"])])
    }

    @Test
    func svgToPNG_readsThePickedFolderAndWritesOnlyItsPngSubfolder() {
        let scope = WorkflowAccessScope.derive(Self.svgToPNG())
        #expect(scope.sources.count == 1)
        let source = scope.sources[0]
        #expect(source.ref == .input("folder"))
        #expect(source.reads)
        #expect(source.writeSubpaths == ["png"])
        #expect(!source.replaces)
        #expect(scope.runsInSandbox)
        #expect(scope.hostReach.isEmpty)
        #expect(!scope.mayAskForMoreFolders)
        #expect(scope.isContained)

        let rows = Dictionary(uniqueKeysWithValues: scope.rows.map { ($0.verb, $0.value) })
        #expect(rows[.reads] == "folder you pick")
        #expect(rows[.writes] == "png subfolder")
        #expect(rows[.deletes] == "nothing")
        #expect(rows[.replaces] == nil)
        #expect(scope.oneLine == "Reads a folder you choose · saves results to a png folder inside it · works in the sandbox")
        #expect(
            scope.architectSentence
                == "This workflow will read the folder you choose, do its work in the sandbox, and save results to a png subfolder of the folder you choose. It won't touch anything else."
        )
        #expect(scope.caption(forInput: "folder") == "Results will be saved to a png folder inside it.")
    }

    @Test
    func resolved_namesTheRealFoldersAndWritableTargets() {
        let scope = WorkflowAccessScope.derive(Self.svgToPNG())
        let resolved = scope.resolved(
            input: .object(["folder": .string("/Users/me/Downloads/dinos")]), dialogOutputs: [:], boundFolders: [:])
        #expect(resolved.count == 1)
        #expect(resolved[0].name == "dinos")
        #expect(resolved[0].writableURLs.map(\.path) == ["/Users/me/Downloads/dinos/png"])
        #expect(resolved[0].writableNames == ["dinos/png"])
    }

    @Test
    func agenticFileWrites_cannotBeNarrowed_soTheWholeFolderIsWritable() {
        let def = WorkflowDefinition(
            inputSchema: WF.object(["folder": Self.folderInput]),
            nodes: [
                WorkflowNode(
                    id: "tidy", name: "Tidy",
                    kind: .inference(
                        InferenceSpec(
                            modelSlot: "main", instructions: "Tidy {{input.folder}}",
                            mode: .agentic(tools: [ToolRef(name: "file_read"), ToolRef(name: "file_write")], maxSteps: 4))))
            ])
        let scope = WorkflowAccessScope.derive(def)
        #expect(scope.sources[0].writeSubpaths == [""])
        #expect(scope.sources[0].reads)
        #expect(scope.oneLine.contains("may save anywhere inside it"))
        #expect(scope.caption(forInput: "folder") == "Results may be saved anywhere inside it.")
    }

    @Test
    func unconfinedTools_areNamed_andTheCopyNeverSaysNothingElse() {
        let def = WorkflowDefinition(
            inputSchema: WF.object(["folder": Self.folderInput]),
            nodes: [
                Self.toolNode("read", "file_read", ["path": "{{input.folder}}/notes.txt"]),
                Self.toolNode("script", "applescript", ["script": "tell app \"Finder\" to activate"]),
            ])
        let scope = WorkflowAccessScope.derive(def)
        #expect(scope.hostReach == ["applescript"])
        #expect(!scope.isContained)
        #expect(!scope.architectSentence.contains("won't touch anything else"))
        #expect(scope.architectSentence.contains("applescript"))
        let rows = Dictionary(uniqueKeysWithValues: scope.rows.map { ($0.verb, $0.value) })
        #expect(rows[.deletes] == "nothing through its file steps")
        #expect(rows[.alsoUses]?.contains("applescript") == true)
    }

    @Test
    func declaredReadFolder_isReadOnly_andOverwritingCopyReplaces() {
        let def = WorkflowDefinition(
            nodes: [
                Self.toolNode("load", "file_read", ["path": "{{folders.invoices}}/list.csv"]),
                WorkflowNode(
                    id: "save", name: "Save",
                    kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_copy"))),
                    input: .values([
                        "source": .string("out.pdf"), "destination": .string("{{folders.reports}}/summary.pdf"),
                        "overwrite": .bool(true),
                    ])),
            ],
            folders: [
                FolderRequirement(key: "invoices", label: "Invoices", access: .read),
                FolderRequirement(key: "reports", label: "Reports", access: .write),
            ])
        let scope = WorkflowAccessScope.derive(def)
        let invoices = scope.sources.first { $0.ref == .folder("invoices") }
        let reports = scope.sources.first { $0.ref == .folder("reports") }
        #expect(invoices?.reads == true)
        #expect(invoices?.writes == false)
        #expect(reports?.writeSubpaths == ["summary.pdf"])
        #expect(reports?.replaces == true)
        #expect(scope.replaces)
        #expect(scope.architectSentence.contains("asks before replacing"))
        let rows = Dictionary(uniqueKeysWithValues: scope.rows.map { ($0.verb, $0.value) })
        #expect(rows[.replaces] == "files in “Reports”, after asking you")
    }

    @Test
    func pathsComputedAtRunTime_mayAskForMoreFolders() {
        let def = WorkflowDefinition(
            nodes: [Self.toolNode("save", "file_write", ["path": "{{nodes.plan.output.path}}", "content": "x"])])
        let scope = WorkflowAccessScope.derive(def)
        #expect(scope.mayAskForMoreFolders)
        #expect(scope.asksToWrite && !scope.asksToRead)
        #expect(scope.architectSentence == "This workflow will save results to a folder it asks you for.")
        #expect(scope.oneLine == "Saves to a folder it asks for")
        #expect(scope.rows.first { $0.verb == .writes }?.value == "a folder it asks for")
        #expect(scope.rows.first { $0.verb == .reads }?.value == "nothing")
        #expect(scope.places == [.mac])
    }

    @Test
    func pathReadAtRunTime_namesTheAskBesideTheChosenFolder() {
        let def = WorkflowDefinition(
            inputSchema: WF.object(["folder": Self.folderInput], required: ["folder"]),
            nodes: [
                Self.toolNode("list", "file_read", ["path": "{{input.folder}}"]),
                Self.toolNode("open", "file_read", ["path": "{{nodes.list.output.path}}"]),
            ])
        let scope = WorkflowAccessScope.derive(def)
        #expect(scope.asksToRead && !scope.asksToWrite)
        #expect(scope.rows.first { $0.verb == .reads }?.value == "folder you pick, a folder it asks for")
        #expect(
            scope.architectSentence
                == "This workflow will read the folder you choose and a folder it asks you for.")
        #expect(!scope.architectSentence.contains("won't touch anything else"))
    }

    @Test
    func noFiles_saysSo() {
        let scope = WorkflowAccessScope.derive(WF.intake())
        #expect(scope.sources.isEmpty)
        #expect(scope.oneLine == "Doesn't use your files")
        #expect(scope.architectSentence == "This workflow doesn't read or save files on your Mac. It won't touch anything else.")
    }

    @Test
    func target_parsesTheLiteralPathBelowTheSource() {
        let dialogs = ["ask": Set(["where"])]
        #expect(WorkflowAccessScope.target(of: "{{input.folder}}/png/{{item}}.png", dialogFields: [:]) == .source(.input("folder"), subpath: "png"))
        #expect(WorkflowAccessScope.target(of: "{{ input.folder }}", dialogFields: [:]) == .source(.input("folder"), subpath: ""))
        #expect(WorkflowAccessScope.target(of: "{{input.folder}}/{{item}}.png", dialogFields: [:]) == .source(.input("folder"), subpath: ""))
        #expect(WorkflowAccessScope.target(of: "{{input.folder}}/../x", dialogFields: [:]) == .source(.input("folder"), subpath: ""))
        #expect(WorkflowAccessScope.target(of: "{{nodes.ask.output.where}}/out.txt", dialogFields: dialogs) == .source(.dialog(node: "ask", field: "where"), subpath: "out.txt"))
        #expect(WorkflowAccessScope.target(of: "{{run.workspace}}/a.png", dialogFields: [:]) == .internal)
        #expect(WorkflowAccessScope.target(of: "out/a.png", dialogFields: [:]) == .internal)
        #expect(WorkflowAccessScope.target(of: "/Users/me/x", dialogFields: [:]) == .dynamic)
        #expect(WorkflowAccessScope.target(of: "{{input.folder}}x", dialogFields: [:]) == .dynamic)
    }
}
