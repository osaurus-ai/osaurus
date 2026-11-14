// Copyright © 2026 osaurus.

import AppKit
import Foundation
import LocalAuthentication
import Testing

@testable import OsaurusCore

/// Show and Copy on the Keys page ask for Touch ID or the password first.
@Suite("Credential reveal", .serialized)
@MainActor
struct CredentialRevealTests {
    @Test("a refused prompt reveals nothing; one approval covers the next minute")
    func promptGatesReads() async {
        CredentialReveal._resetForTesting()
        defer { CredentialReveal._resetForTesting() }

        let refused = StubContext(allows: false)
        CredentialReveal.makeContext = { refused }
        #expect(await CredentialReveal.read(reason: "show") { "secret" } == nil)
        #expect(refused.prompts == 1)

        let approved = StubContext(allows: true)
        CredentialReveal.makeContext = { approved }
        #expect(await CredentialReveal.read(reason: "show") { "secret" } == "secret")
        #expect(await CredentialReveal.read(reason: "show") { "secret" } == "secret")
        #expect(approved.prompts == 1)
    }

    @Test("no Touch ID or password available reveals nothing")
    func unavailablePolicy() async {
        CredentialReveal._resetForTesting()
        defer { CredentialReveal._resetForTesting() }
        let unavailable = StubContext(allows: true, canEvaluate: false)
        CredentialReveal.makeContext = { unavailable }
        #expect(await CredentialReveal.read(reason: "show") { "secret" } == nil)
        #expect(unavailable.prompts == 0)
    }

    @Test("an account action asks first, and passes only on a Mac with no password")
    func confirmOwner() async {
        CredentialReveal._resetForTesting()
        defer { CredentialReveal._resetForTesting() }
        let refused = StubContext(allows: false)
        CredentialReveal.makeContext = { refused }
        #expect(await CredentialReveal.confirmOwner(reason: "sign out") == false)
        #expect(refused.prompts == 1)

        let noPassword = StubContext(allows: false, canEvaluate: false, unavailable: .passcodeNotSet)
        CredentialReveal.makeContext = { noPassword }
        #expect(await CredentialReveal.confirmOwner(reason: "sign out"))
        #expect(noPassword.prompts == 0)

        let lockedOut = StubContext(allows: false, canEvaluate: false, unavailable: .biometryLockout)
        CredentialReveal.makeContext = { lockedOut }
        #expect(await CredentialReveal.confirmOwner(reason: "sign out") == false)
    }

    @Test("copy puts the value on the pasteboard")
    func copyWritesValue() {
        let pasteboard = NSPasteboard(name: .init("osaurus.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        CredentialReveal.copy("secret", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "secret")
    }
}

private final class StubContext: LAContext {
    let allows: Bool
    let canEvaluate: Bool
    let unavailable: LAError.Code?
    private(set) var prompts = 0

    init(allows: Bool, canEvaluate: Bool = true, unavailable: LAError.Code? = nil) {
        self.allows = allows
        self.canEvaluate = canEvaluate
        self.unavailable = unavailable
        super.init()
    }

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        if !canEvaluate, let unavailable {
            error?.pointee = NSError(domain: LAErrorDomain, code: unavailable.rawValue)
        }
        return canEvaluate
    }

    override func evaluatePolicy(
        _ policy: LAPolicy, localizedReason: String, reply: @escaping (Bool, Error?) -> Void
    ) {
        prompts += 1
        reply(allows, allows ? nil : LAError(.userCancel))
    }
}
