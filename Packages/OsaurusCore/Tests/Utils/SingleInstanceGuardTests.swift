//
//  SingleInstanceGuardTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct SingleInstanceGuardTests {
    private typealias Instance = SingleInstanceGuard.Instance
    private let now = Date()

    @Test func laterCopyDefersToTheRunningOne() {
        let own = Instance(pid: 200, launchDate: now)
        let running = Instance(pid: 100, launchDate: now.addingTimeInterval(-60))
        #expect(SingleInstanceGuard.earlierInstance(than: own, among: [running, own]) == running)
    }

    @Test func firstCopyKeepsRunning() {
        let own = Instance(pid: 100, launchDate: now.addingTimeInterval(-60))
        let later = Instance(pid: 200, launchDate: now)
        #expect(SingleInstanceGuard.earlierInstance(than: own, among: [own, later]) == nil)
    }

    @Test func simultaneousLaunchesAgreeOnTheLowerPid() {
        let a = Instance(pid: 100, launchDate: now)
        let b = Instance(pid: 200, launchDate: now)
        #expect(SingleInstanceGuard.earlierInstance(than: a, among: [a, b]) == nil)
        #expect(SingleInstanceGuard.earlierInstance(than: b, among: [a, b]) == a)
    }

    @Test func aloneMeansNoDeferral() {
        let own = Instance(pid: 100, launchDate: now)
        #expect(SingleInstanceGuard.earlierInstance(than: own, among: [own]) == nil)
    }
}

struct CLIServeRequestTests {
    @Test func plainServeLeavesExposureAlone() {
        let request = AppDelegate.CLIServeRequest(userInfo: [:])
        #expect(request.expose == nil)
        #expect(request.port == nil)
    }

    @Test func exposeFlagsInBothDirections() {
        #expect(AppDelegate.CLIServeRequest(userInfo: ["expose": true]).expose == true)
        #expect(AppDelegate.CLIServeRequest(userInfo: ["expose": false]).expose == false)
        #expect(AppDelegate.CLIServeRequest(userInfo: ["expose": "no"]).expose == false)
        #expect(AppDelegate.CLIServeRequest(userInfo: ["expose": "yes"]).expose == true)
        #expect(AppDelegate.CLIServeRequest(userInfo: ["expose": "maybe"]).expose == nil)
    }

    @Test func portAsIntOrString() {
        #expect(AppDelegate.CLIServeRequest(userInfo: ["port": 8080]).port == 8080)
        #expect(AppDelegate.CLIServeRequest(userInfo: ["port": "9090"]).port == 9090)
    }
}
