//
//  ABI.swift
//  OsaurusPluginTestKit
//
//  Swift mirror of the v4 `osr_host_api` C struct and the function-
//  pointer typealiases the plugin compiles against. Kept in sync with
//  `Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h`.
//
//  The struct layout is FROZEN per the ABI contract — fields are only
//  ever appended. If a future host bump introduces v5+ slots, append
//  them at the end of `OsrHostAPI` here AND update the corresponding
//  C header. Older mock hosts keep working because Swift's synthesized
//  memberwise init defaults trailing optionals to nil.
//

import Foundation

// MARK: - C ABI typealiases (mirrors osaurus_plugin.h)

public typealias OsrPluginCtx = UnsafeMutableRawPointer

public typealias OsrConfigGet = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrConfigSet = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrConfigDelete = @convention(c) (UnsafePointer<CChar>?) -> Void
public typealias OsrDbExec = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrDbQuery = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrLog = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
public typealias OsrDispatch = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrTaskStatus = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrDispatchCancel = @convention(c) (UnsafePointer<CChar>?) -> Void
public typealias OsrDispatchClarify = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrComplete = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrOnChunk = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
public typealias OsrCompleteStream =
    @convention(c) (
        UnsafePointer<CChar>?,
        OsrOnChunk?,
        UnsafeMutableRawPointer?
    ) -> UnsafePointer<CChar>?
public typealias OsrEmbed = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrListModels = @convention(c) () -> UnsafePointer<CChar>?
public typealias OsrHttpRequest = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrFileRead = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrListActiveTasks = @convention(c) () -> UnsafePointer<CChar>?
public typealias OsrSendDraft = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrDispatchInterrupt = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias OsrDispatchAddIssue =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
public typealias OsrCompleteCancel = @convention(c) (UnsafePointer<CChar>?) -> Void
public typealias OsrGetActiveAgentId = @convention(c) () -> UnsafePointer<CChar>?
public typealias OsrLogStructured =
    @convention(c) (
        Int32,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Void
public typealias OsrHostFreeString = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Swift mirror of `osr_host_api` (v4). Field order is FROZEN. Future
/// host versions append new optional slots at the end; the synthesized
/// memberwise init lets older mock hosts keep working because trailing
/// optionals default to nil.
public struct OsrHostAPI {
    public var version: UInt32

    // Config + Storage + Logging
    public var configGet: OsrConfigGet?
    public var configSet: OsrConfigSet?
    public var configDelete: OsrConfigDelete?
    public var dbExec: OsrDbExec?
    public var dbQuery: OsrDbQuery?
    public var log: OsrLog?

    // Agent Dispatch
    public var dispatch: OsrDispatch?
    public var taskStatus: OsrTaskStatus?
    public var dispatchCancel: OsrDispatchCancel?
    public var dispatchClarify: OsrDispatchClarify?

    // Inference
    public var complete: OsrComplete?
    public var completeStream: OsrCompleteStream?
    public var embed: OsrEmbed?
    public var listModels: OsrListModels?

    // HTTP / File I/O
    public var httpRequest: OsrHttpRequest?
    public var fileRead: OsrFileRead?

    // Extended dispatch
    public var listActiveTasks: OsrListActiveTasks?
    public var sendDraft: OsrSendDraft?
    public var dispatchInterrupt: OsrDispatchInterrupt?
    public var dispatchAddIssue: OsrDispatchAddIssue?

    // Streaming control (v3)
    public var completeCancel: OsrCompleteCancel?

    // Agent context introspection (v4)
    public var getActiveAgentId: OsrGetActiveAgentId?

    // Structured logging (v5)
    public var logStructured: OsrLogStructured?

    // Host-side free for host-returned strings (v6)
    public var freeString: OsrHostFreeString?

    public init(
        version: UInt32 = 6,
        configGet: OsrConfigGet? = nil,
        configSet: OsrConfigSet? = nil,
        configDelete: OsrConfigDelete? = nil,
        dbExec: OsrDbExec? = nil,
        dbQuery: OsrDbQuery? = nil,
        log: OsrLog? = nil,
        dispatch: OsrDispatch? = nil,
        taskStatus: OsrTaskStatus? = nil,
        dispatchCancel: OsrDispatchCancel? = nil,
        dispatchClarify: OsrDispatchClarify? = nil,
        complete: OsrComplete? = nil,
        completeStream: OsrCompleteStream? = nil,
        embed: OsrEmbed? = nil,
        listModels: OsrListModels? = nil,
        httpRequest: OsrHttpRequest? = nil,
        fileRead: OsrFileRead? = nil,
        listActiveTasks: OsrListActiveTasks? = nil,
        sendDraft: OsrSendDraft? = nil,
        dispatchInterrupt: OsrDispatchInterrupt? = nil,
        dispatchAddIssue: OsrDispatchAddIssue? = nil,
        completeCancel: OsrCompleteCancel? = nil,
        getActiveAgentId: OsrGetActiveAgentId? = nil,
        logStructured: OsrLogStructured? = nil,
        freeString: OsrHostFreeString? = nil
    ) {
        self.version = version
        self.configGet = configGet
        self.configSet = configSet
        self.configDelete = configDelete
        self.dbExec = dbExec
        self.dbQuery = dbQuery
        self.log = log
        self.dispatch = dispatch
        self.taskStatus = taskStatus
        self.dispatchCancel = dispatchCancel
        self.dispatchClarify = dispatchClarify
        self.complete = complete
        self.completeStream = completeStream
        self.embed = embed
        self.listModels = listModels
        self.httpRequest = httpRequest
        self.fileRead = fileRead
        self.listActiveTasks = listActiveTasks
        self.sendDraft = sendDraft
        self.dispatchInterrupt = dispatchInterrupt
        self.dispatchAddIssue = dispatchAddIssue
        self.completeCancel = completeCancel
        self.getActiveAgentId = getActiveAgentId
        self.logStructured = logStructured
        self.freeString = freeString
    }
}
