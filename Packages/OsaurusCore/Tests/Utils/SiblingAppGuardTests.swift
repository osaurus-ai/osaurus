//
//  SiblingAppGuardTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

struct SiblingAppGuardTests {
    @Test func stableAndBetaGuardEachOther() {
        #expect(SiblingAppGuard.siblingBundleId(of: "com.dinoki.osaurus") == "com.dinoki.osaurus.beta")
        #expect(SiblingAppGuard.siblingBundleId(of: "com.dinoki.osaurus.beta") == "com.dinoki.osaurus")
    }

    @Test func otherBuildsAreNotGuarded() {
        #expect(SiblingAppGuard.siblingBundleId(of: nil) == nil)
        #expect(SiblingAppGuard.siblingBundleId(of: "com.dinoki.osaurus.proof") == nil)
        #expect(SiblingAppGuard.siblingBundleId(of: "com.apple.dt.xctest.tool") == nil)
    }
}
