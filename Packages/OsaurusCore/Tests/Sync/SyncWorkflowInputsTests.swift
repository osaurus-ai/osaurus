//
//  SyncWorkflowInputsTests.swift
//  OsaurusCoreTests
//
//  A workflow started from the iPhone gets file and folder paths only from this Mac
//  (`workflow_file_inputs`): a file the phone attached on the manage conversation, saved here, or what an
//  earlier run used. Never a path the phone sends.
//

import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@MainActor
struct SyncWorkflowInputsTests {

    private static let phone = "aa11"
    private static let manage = "manage-scope"

    private static func message(
        scope: String = manage,
        device: String = phone,
        isAgent: Bool = false,
        blobs: [Blob] = [blob()]
    ) -> SyncMessage {
        SyncMessage(
            id: "m", scope: scope, hlc: 0, timestampMs: 0, authorDevice: device, author: "u:me",
            isAgent: isAgent, role: .user, content: "", blobs: blobs, replyTo: nil, toolCallId: nil, toolName: nil,
            edited: false, delivery: .delivered, reactions: [], appData: [])
    }

    private static func blob(hash: String = "h1", size: UInt64 = 1024) -> Blob {
        Blob(hash: hash, size: size, mediaType: "image/jpeg", name: "me.jpg", available: true)
    }

    private static let ref = SyncWorkflowInputs.FileRef(message: "m", blob: "h1")

    // MARK: Which file is taken

    @Test("the attachment on the requesting device's manage message is taken")
    func takesTheRequestersAttachment() {
        let result = SyncWorkflowInputs.check(Self.message(), ref: Self.ref, scope: Self.manage, device: "AA11")
        guard case .success(let (scope, blob)) = result else {
            Issue.record("expected the file")
            return
        }
        #expect(scope == Self.manage)
        #expect(blob.hash == "h1")
    }

    @Test("a message on another conversation, by another device or by an agent is refused")
    func refusesOtherMessages() {
        for message in [
            Self.message(scope: "a-chat"), Self.message(device: "bb22"), Self.message(isAgent: true),
        ] {
            let result = SyncWorkflowInputs.check(message, ref: Self.ref, scope: Self.manage, device: Self.phone)
            if case .success = result { Issue.record("took a file it shouldn't have") }
        }
    }

    @Test("an attachment the message doesn't have, or one over 10 MB, is refused")
    func refusesMissingOrLargeFiles() {
        let missing = SyncWorkflowInputs.check(
            Self.message(blobs: [Self.blob(hash: "other")]), ref: Self.ref, scope: Self.manage, device: Self.phone)
        let large = SyncWorkflowInputs.check(
            Self.message(blobs: [Self.blob(size: SyncWorkflowInputs.maxBytes + 1)]),
            ref: Self.ref, scope: Self.manage, device: Self.phone)
        if case .success = missing { Issue.record("took a file the message doesn't have") }
        if case .success = large { Issue.record("took a file over the limit") }
    }

    // MARK: Saved names

    @Test("the phone's file name is saved as one plain name in its folder")
    func safeNames() {
        #expect(SyncWorkflowInputs.safeName("me.jpg") == "me.jpg")
        #expect(SyncWorkflowInputs.safeName("../../etc/passwd") == "passwd")
        #expect(SyncWorkflowInputs.safeName("/Users/me/.ssh/id_rsa") == "id_rsa")
        #expect(SyncWorkflowInputs.safeName(".hidden") == "hidden")
        #expect(SyncWorkflowInputs.safeName("a:b\u{0}c.png") == "a_b_c.png")
        #expect(SyncWorkflowInputs.safeName(nil) == "input")
        #expect(SyncWorkflowInputs.safeName("...") == "input")
        let long = SyncWorkflowInputs.safeName(String(repeating: "x", count: 300) + ".jpeg")
        #expect(long.count <= 120)
        #expect(long.hasSuffix(".jpeg"))
    }

    // MARK: Last used

    private static func run(
        _ input: [String: JSONValue], workflowId: UUID = UUID(), fromPhone: Bool = false,
        kind: WorkflowCaller.Kind = .user
    ) -> WorkflowRun {
        var caller = WorkflowCaller(kind: kind, background: fromPhone)
        caller.fromPhone = fromPhone
        return WorkflowRun(
            workflowID: workflowId,
            workflowName: "Headshots",
            templateID: UUID(),
            templateVersion: 1,
            caller: caller,
            input: .object(input),
            nodeIDs: [],
            startedAt: Date()
        )
    }

    @Test("the last run's file or folder is offered by name only, for required file and folder fields only")
    func lastUsedName() {
        let last = Self.run([
            "photo": .string("/Users/me/Pictures/me.jpg"),
            "folder": .string("/Users/me/Projects"),
            "topic": .string("/not/a/path/field"),
            "relative": .string("me.jpg"),
            "optional": .string("/Users/me/Pictures/ref.jpg"),
        ])
        let photo = DialogField(key: "photo", label: "Photo", type: .file)
        let folder = DialogField(key: "folder", label: "Folder", type: .folder)
        let topic = DialogField(key: "topic", label: "Topic")
        let relative = DialogField(key: "relative", label: "Relative", type: .file)
        let optional = DialogField(key: "optional", label: "Reference", type: .file, required: false)
        #expect(SyncWorkflowInputs.lastUsedName(photo, lastRun: last) == "me.jpg")
        #expect(SyncWorkflowInputs.lastUsedName(folder, lastRun: last) == "Projects")
        #expect(SyncWorkflowInputs.lastUsedName(topic, lastRun: last) == nil)
        #expect(SyncWorkflowInputs.lastUsedName(relative, lastRun: last) == nil)
        #expect(SyncWorkflowInputs.lastUsedName(optional, lastRun: last) == nil)
        #expect(SyncWorkflowInputs.lastUsedName(photo, lastRun: nil) == nil)
    }

    @Test("from a run the phone started, only a file this Mac saved for it is reused, never the phone's own value")
    func phoneRunsReuseOnlyWhatTheMacMade() {
        let id = UUID()
        let saved = SyncWorkflowInputs.phoneInputs(id).appendingPathComponent("abc/me.jpg").path
        let folder = DialogField(key: "folder", label: "Folder", type: .folder)
        let photo = DialogField(key: "photo", label: "Photo", type: .file)
        let phoneRun = Self.run(
            ["folder": .string("/Users/me/.ssh"), "photo": .string(saved)],
            workflowId: id,
            fromPhone: true
        )
        #expect(SyncWorkflowInputs.lastPath(folder, lastRun: phoneRun) == nil)
        #expect(SyncWorkflowInputs.lastPath(photo, lastRun: phoneRun) == saved)
        let escaping = Self.run(
            ["photo": .string(SyncWorkflowInputs.phoneInputs(id).path + "/../../secret")],
            workflowId: id,
            fromPhone: true
        )
        #expect(SyncWorkflowInputs.lastPath(photo, lastRun: escaping) == nil)
    }

    @Test("a path an agent, the Orchestrator, an event or another workflow gave is never reused")
    func onlyAPersonsChoiceOnThisMacIsReused() {
        let photo = DialogField(key: "photo", label: "Photo", type: .file)
        let input: [String: JSONValue] = ["photo": .string("/Users/me/.ssh/id_ed25519")]
        for kind: WorkflowCaller.Kind in [.agent, .orchestrator, .event, .workflow, .test] {
            #expect(SyncWorkflowInputs.lastPath(photo, lastRun: Self.run(input, kind: kind)) == nil, "\(kind)")
        }
        #expect(SyncWorkflowInputs.lastPath(photo, lastRun: Self.run(input)) == "/Users/me/.ssh/id_ed25519")
    }
}
