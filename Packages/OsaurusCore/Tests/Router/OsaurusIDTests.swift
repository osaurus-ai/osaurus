//
//  OsaurusIDTests.swift
//  OsaurusCoreTests
//
//  Osaurus ID (`/id/*`): handle rules, wire types, the session-token-first
//  transport, the Keychain session store, and the service's claim / adopt /
//  reset contracts. Contract: osaurus-router/docs/OSAURUS_ID.md.
//

import Foundation
import Security
import Testing

@testable import OsaurusCore

// MARK: - Handle rules

@Suite("Osaurus ID handle rules")
struct OsaurusIDValidatorTests {
    @Test func acceptsServerShapedHandles() {
        for handle in ["rex", "rex-42", "a1b", "abc-def-ghi", String(repeating: "a", count: 20)] {
            #expect(OsaurusIDValidator.isValid(handle), "\(handle) should be valid")
        }
    }

    @Test func rejectsMalformedHandles() {
        for handle in [
            "", "ab", "Rex", "rex_42", "-rex", "rex-", "rex--42", "rex 42", "réx",
            String(repeating: "a", count: 21), "@rex",
        ] {
            #expect(!OsaurusIDValidator.isValid(handle), "\(handle) should be invalid")
        }
    }

    @Test func sanitizerShapesLiveInput() {
        #expect(OsaurusIDValidator.sanitizedInput("Rex 42") == "rex-42")
        #expect(OsaurusIDValidator.sanitizedInput("rex__42") == "rex-42")
        #expect(OsaurusIDValidator.sanitizedInput("--rex") == "rex")
        #expect(OsaurusIDValidator.sanitizedInput("rex--42--") == "rex-42-")
        #expect(OsaurusIDValidator.sanitizedInput("r@x!42") == "rx42")
        #expect(OsaurusIDValidator.sanitizedInput(String(repeating: "a", count: 30)).count == 20)
    }

    @Test func displayNameAndBioAreTrimmedStrippedAndCapped() {
        #expect(OsaurusIDDisplayName.sanitized("  Rexy \n") == "Rexy")
        #expect(OsaurusIDDisplayName.sanitized("Rex\u{0}y") == "Rexy")
        #expect(OsaurusIDDisplayName.sanitized(String(repeating: "x", count: 60)).count == 50)
        #expect(OsaurusIDDisplayName.sanitized("   ") == "")
        #expect(OsaurusIDBio.sanitized("line one\nline two\u{7} ") == "line one\nline two")
        #expect(OsaurusIDBio.sanitized(String(repeating: "b", count: 600)).count == 500)
    }
}

// MARK: - Wire types

@Suite("Osaurus ID wire types")
struct OsaurusIDWireTypeTests {
    private let decoder = JSONDecoder()

    @Test func profileDecodesWithDefaultsAndFallsBackToHandle() throws {
        let bare = try decoder.decode(
            OsaurusIDProfile.self,
            from: Data(#"{"osaurus_id":"rex-42","display_name":"","email":null,"email_public":false,"bio":""}"#.utf8)
        )
        #expect(bare.osaurusID == "rex-42")
        #expect(bare.displayName == "")
        #expect(bare.effectiveName == "rex-42")
        #expect(bare.handle == "@rex-42")
        #expect(bare.email == nil)

        let named = try decoder.decode(
            OsaurusIDProfile.self,
            from: Data(
                #"{"osaurus_id":"rex-42","display_name":"Rexy","email":"rex@example.com","email_public":true,"bio":"hi","created_at":"2026-09-01T00:00:00.000Z","updated_at":"2026-09-02T00:00:00.000Z"}"#
                    .utf8
            )
        )
        #expect(named.effectiveName == "Rexy")
        #expect(named.emailPublic)
        #expect(named.bio == "hi")
        #expect(named.createdAt == "2026-09-01T00:00:00.000Z")

        // Fields a future router might omit still decode.
        let minimal = try decoder.decode(OsaurusIDProfile.self, from: Data(#"{"osaurus_id":"rex"}"#.utf8))
        #expect(minimal.effectiveName == "rex")
    }

    @Test func availabilityDecodesKnownStatusesAndReadsUnknownAsInvalid() throws {
        for (raw, expected): (String, OsaurusIDAvailabilityStatus) in [
            ("available", .available), ("taken", .taken), ("reserved", .reserved), ("invalid", .invalid),
            ("quarantined", .invalid),
        ] {
            let decoded = try decoder.decode(
                OsaurusIDAvailability.self,
                from: Data(#"{"osaurus_id":"rex-42","status":"\#(raw)"}"#.utf8)
            )
            #expect(decoded.status == expected, "\(raw)")
            #expect(decoded.osaurusID == "rex-42")
        }
    }

    @Test func patchOmitsUnsetFieldsAndSendsEmptyStringToClear() throws {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: false)
        let nameOnly = try String(decoding: encoder.encode(OsaurusIDProfilePatch(displayName: "")), as: UTF8.self)
        #expect(nameOnly == #"{"display_name":""}"#)
        let bioOnly = try String(decoding: encoder.encode(OsaurusIDProfilePatch(bio: "hello")), as: UTF8.self)
        #expect(bioOnly == #"{"bio":"hello"}"#)
        let both = try String(
            decoding: encoder.encode(OsaurusIDProfilePatch(displayName: "Rexy", bio: "hi")),
            as: UTF8.self
        )
        #expect(both == #"{"bio":"hi","display_name":"Rexy"}"#)
    }

    @Test func errorRefinementsMatchRouterShapes() {
        #expect(
            OsaurusRouterAPIError.server(
                code: "NOT_FOUND",
                message: "no Osaurus ID claimed for this account",
                status: 404
            ).isOsaurusIDNotFound
        )
        #expect(!OsaurusRouterAPIError.server(code: "NOT_FOUND", message: "not found", status: 200).isOsaurusIDNotFound)
        #expect(!OsaurusRouterAPIError.server(code: "INVALID_STATE", message: "x", status: 404).isOsaurusIDNotFound)
        #expect(
            OsaurusRouterAPIError.server(
                code: "INVALID_STATE",
                message: "this account already has an Osaurus ID",
                status: 409
            ).indicatesAccountAlreadyHasOsaurusID
        )
        #expect(
            !OsaurusRouterAPIError.server(
                code: "INVALID_STATE",
                message: "this Osaurus ID is already taken",
                status: 409
            )
            .indicatesAccountAlreadyHasOsaurusID
        )
        #expect(!OsaurusRouterAPIError.unauthorized.indicatesAccountAlreadyHasOsaurusID)
    }
}

// MARK: - API client

@Suite("Osaurus ID API client", .serialized)
struct OsaurusIDAPIClientTests {
    @Test func availability_isSignedGETWithHandleQuery() async throws {
        let client = try makeClient(token: { nil }) { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/id/availability")
            #expect(request.url?.query == "osaurus_id=rex-42")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == TestKeys.aliceAddress.lowercased())
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return json(#"{"osaurus_id":"rex-42","status":"available"}"#)
        }
        let availability = try await client.osaurusIDAvailability("rex-42")
        #expect(availability.status == .available)
    }

    /// Claiming and session minting are wallet-signed even when a session
    /// token is stored — a leaked token must never mint another.
    @Test func claimAndSessionMint_areAlwaysWalletSignedEvenWithStoredToken() async throws {
        let client = try makeClient(token: { "osk_stored" }) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == TestKeys.aliceAddress.lowercased())
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/id"):
                #expect(bodyString(request) == #"{"osaurus_id":"rex-42"}"#)
                return json(
                    #"{"osaurus_id":"rex-42","display_name":"","email":null,"email_public":false,"bio":""}"#,
                    status: 201
                )
            case ("POST", "/id/sessions"):
                #expect(bodyString(request) == #"{"label":"MacBook"}"#)
                return json(
                    #"{"token":"osk_new","session":{"id":"s1","label":"MacBook","expires_at":"2026-12-11T00:00:00.000Z","created_at":"2026-09-12T00:00:00.000Z"}}"#,
                    status: 201
                )
            default:
                Issue.record("unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }
        let profile = try await client.claimOsaurusID(handle: "rex-42")
        #expect(profile.osaurusID == "rex-42")
        let minted = try await client.createOsaurusIDSession(label: "MacBook")
        #expect(minted.token == "osk_new")
        #expect(minted.session.id == "s1")
    }

    @Test func profile_prefersBearerTokenAndDecodes() async throws {
        let client = try makeClient(token: { "osk_stored" }) { request in
            #expect(request.url?.path == "/id/me")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer osk_stored")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == nil)
            return json(#"{"osaurus_id":"rex-42","display_name":"Rexy","email":null,"email_public":false,"bio":"hi"}"#)
        }
        let profile = try await client.osaurusIDProfile()
        #expect(profile.effectiveName == "Rexy")
    }

    @Test func profile_notFoundSurfacesAsUnclaimed() async throws {
        let client = try makeClient(token: { nil }) { _ in
            json(#"{"error":{"code":"NOT_FOUND","message":"no Osaurus ID claimed for this account"}}"#, status: 404)
        }
        do {
            _ = try await client.osaurusIDProfile()
            Issue.record("expected NOT_FOUND")
        } catch let error as OsaurusRouterAPIError {
            #expect(error.isOsaurusIDNotFound)
        }
    }

    /// A dead token (revoked / expired server-side) is dropped and the call
    /// is retried wallet-signed exactly once.
    @Test func bearer401_clearsTokenAndRetriesWalletSigned() async throws {
        let cleared = Counter()
        let attempts = Counter()
        let client = try makeClient(token: { "osk_dead" }, clear: { _ = cleared.increment() }) { request in
            let n = attempts.increment()
            #expect(request.url?.path == "/id/me")
            if n == 1 {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer osk_dead")
                return json(#"{"error":{"code":"UNAUTHORIZED","message":"session token invalid"}}"#, status: 401)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == TestKeys.aliceAddress.lowercased())
            return json(#"{"osaurus_id":"rex-42","display_name":"","email":null,"email_public":false,"bio":""}"#)
        }
        let profile = try await client.osaurusIDProfile()
        #expect(profile.osaurusID == "rex-42")
        #expect(attempts.current == 2)
        #expect(cleared.current == 1)
    }

    /// A non-401 failure under a bearer token is the answer: no wallet retry,
    /// no token drop (the token is fine; the request wasn't).
    @Test func bearerNon401Error_isNotRetried() async throws {
        let cleared = Counter()
        let attempts = Counter()
        let client = try makeClient(token: { "osk_ok" }, clear: { _ = cleared.increment() }) { _ in
            _ = attempts.increment()
            return json(#"{"error":{"code":"ACCOUNT_FROZEN","message":"frozen"}}"#, status: 403)
        }
        do {
            _ = try await client.updateOsaurusIDProfile(OsaurusIDProfilePatch(bio: "x"))
            Issue.record("expected ACCOUNT_FROZEN")
        } catch let error as OsaurusRouterAPIError {
            if case .accountFrozen = error {} else { Issue.record("unexpected \(error)") }
        }
        #expect(attempts.current == 1)
        #expect(cleared.current == 0)
    }

    @Test func updateProfile_isPATCHWithCanonicalBody() async throws {
        let client = try makeClient(token: { "osk_stored" }) { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/id/me")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(bodyString(request) == #"{"display_name":"Rexy"}"#)
            return json(#"{"osaurus_id":"rex-42","display_name":"Rexy","email":null,"email_public":false,"bio":""}"#)
        }
        let updated = try await client.updateOsaurusIDProfile(OsaurusIDProfilePatch(displayName: "Rexy"))
        #expect(updated.displayName == "Rexy")
    }

    @Test func sessions_listAndRevoke() async throws {
        let client = try makeClient(token: { "osk_stored" }) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/id/sessions"):
                return json(
                    #"{"data":[{"id":"s1","label":"MacBook","status":"active","expires_at":"2026-12-11T00:00:00.000Z","last_used_at":null,"revoked_at":null,"created_at":"2026-09-12T00:00:00.000Z"}]}"#
                )
            case ("DELETE", "/id/sessions/s1"):
                return json(#"{"revoked":true}"#)
            default:
                Issue.record("unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }
        let sessions = try await client.listOsaurusIDSessions()
        #expect(sessions.map(\.id) == ["s1"])
        #expect(sessions[0].status == "active")
        try await client.revokeOsaurusIDSession(id: "s1")
    }

    @Test func revokeSession_rejectsUnsafePathComponent() async throws {
        let client = try makeClient(token: { nil }) { _ in
            Issue.record("no request expected")
            throw URLError(.badURL)
        }
        do {
            try await client.revokeOsaurusIDSession(id: "s1/../../admin")
            Issue.record("expected invalidURL")
        } catch let error as OsaurusRouterAPIError {
            if case .invalidURL = error {} else { Issue.record("unexpected \(error)") }
        }
    }

    // MARK: helpers

    private func makeClient(
        token: @escaping @Sendable () -> String?,
        clear: @escaping @Sendable () -> Void = {},
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    ) throws -> OsaurusRouterAPIClient {
        OsaurusIDClientURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OsaurusIDClientURLProtocol.self]
        let session = URLSession(configuration: config)
        let baseURL = try #require(URL(string: "https://router.test"))
        return OsaurusRouterAPIClient(
            baseURL: baseURL,
            session: session,
            authOverride: { request, _ in
                request.setValue(TestKeys.aliceAddress.lowercased(), forHTTPHeaderField: "x-wallet-address")
                request.setValue("1717171717", forHTTPHeaderField: "x-wallet-timestamp")
                request.setValue("0x" + String(repeating: "1", count: 130), forHTTPHeaderField: "x-wallet-signature")
            },
            idSessionToken: token,
            clearIDSession: clear
        )
    }
}

// MARK: - Session store + service

/// `OsaurusIDSessionStore` is process-global, so the store tests and the
/// service tests (which mint into it) share one serialized parent suite.
@Suite("Osaurus ID store and service", .serialized)
struct OsaurusIDStoreAndServiceTests {}

extension OsaurusIDStoreAndServiceTests {
    @Suite("Osaurus ID session store", .serialized)
    struct OsaurusIDSessionStoreTests {
        private func withFakeStorage<T>(_ storage: InMemorySessionStorage, _ body: () throws -> T) rethrows -> T {
            OsaurusIDSessionStore._setStorageForTesting(storage)
            defer { OsaurusIDSessionStore._setStorageForTesting(nil) }
            return try body()
        }

        @Test func saveRoundTripsThroughStorageAndCache() throws {
            let storage = InMemorySessionStorage()
            try withFakeStorage(storage) {
                #expect(OsaurusIDSessionStore.token() == nil)
                let expires = Date().addingTimeInterval(3600)
                OsaurusIDSessionStore.save(token: "osk_abc", sessionID: "s1", expiresAt: expires)
                #expect(OsaurusIDSessionStore.token() == "osk_abc")

                let stored = try #require(storage.data)
                let decoded = try JSONDecoder().decode(OsaurusIDSessionStore.StoredSession.self, from: stored)
                #expect(decoded.token == "osk_abc")
                #expect(decoded.sessionID == "s1")

                // A fresh process reads it back from storage.
                OsaurusIDSessionStore._resetCacheForTesting()
                #expect(OsaurusIDSessionStore.token() == "osk_abc")

                OsaurusIDSessionStore.clear()
                #expect(OsaurusIDSessionStore.token() == nil)
                #expect(storage.data == nil)
            }
        }

        /// A locked / unavailable keychain must not be latched as "no session"
        /// for the rest of the process.
        @Test func transientReadFailureIsNotCached() {
            let storage = InMemorySessionStorage()
            storage.forcedRead = .unavailable(errSecInteractionNotAllowed)
            withFakeStorage(storage) {
                #expect(OsaurusIDSessionStore.token() == nil)
                storage.forcedRead = nil
                let blob = try? JSONEncoder().encode(
                    OsaurusIDSessionStore.StoredSession(token: "osk_late", sessionID: nil, expiresAt: nil)
                )
                storage.data = blob
                #expect(OsaurusIDSessionStore.token() == "osk_late")
            }
        }

        @Test func expiredTokenIsDroppedInsteadOfSent() {
            let storage = InMemorySessionStorage()
            withFakeStorage(storage) {
                let now = Date()
                OsaurusIDSessionStore.save(token: "osk_old", sessionID: "s1", expiresAt: now.addingTimeInterval(60))
                #expect(OsaurusIDSessionStore.token(now: now) == "osk_old")
                #expect(OsaurusIDSessionStore.token(now: now.addingTimeInterval(61)) == nil)
                // Cleared as a side effect, not just hidden.
                #expect(OsaurusIDSessionStore.token(now: now) == nil)
                #expect(storage.data == nil)
            }
        }

        @Test func expiryDateParsesBothISOShapes() {
            #expect(OsaurusIDSessionStore.expiryDate(from: "2026-12-11T00:00:00.000Z") != nil)
            #expect(OsaurusIDSessionStore.expiryDate(from: "2026-12-11T00:00:00Z") != nil)
            #expect(OsaurusIDSessionStore.expiryDate(from: nil) == nil)
            #expect(OsaurusIDSessionStore.expiryDate(from: "") == nil)
            #expect(OsaurusIDSessionStore.expiryDate(from: "yesterday") == nil)
        }

        @Test func serviceIsRegisteredForFactoryReset() {
            #expect(OsaurusKeychainServices.all.contains(OsaurusKeychainServices.osaurusID))
        }
    }
}

// MARK: - Service

extension OsaurusIDStoreAndServiceTests {
    @Suite("Osaurus ID service", .serialized)
    @MainActor
    struct OsaurusIDServiceTests {
        private let profileJSON =
            #"{"osaurus_id":"rex-42","display_name":"","email":null,"email_public":false,"bio":""}"#

        @Test func refresh_resolvesClaimedUnclaimedAndUnavailable() async throws {
            try await withFakeStorage {
                let mode = Box("claimed")
                let service = try makeService { request in
                    #expect(request.url?.path == "/id/me")
                    switch mode.value {
                    case "claimed": return json(profileJSON)
                    case "unclaimed":
                        return json(
                            #"{"error":{"code":"NOT_FOUND","message":"no Osaurus ID claimed for this account"}}"#,
                            status: 404
                        )
                    default: throw URLError(.notConnectedToInternet)
                    }
                }
                #expect(service.state == .unknown)

                #expect(await service.refresh() == .claimed(OsaurusIDProfile(osaurusID: "rex-42")))
                #expect(service.state == .claimed)
                #expect(service.claimedHandle == "rex-42")

                mode.value = "unclaimed"
                #expect(await service.refresh() == .unclaimed)
                #expect(service.state == .unclaimed)
                #expect(service.profile == nil)
                #expect(service.claimedHandle == nil)

                // Transient failure keeps the prior authoritative state.
                mode.value = "offline"
                if case .unavailable = await service.refresh() {} else { Issue.record("expected unavailable") }
                #expect(service.state == .unclaimed)
                #expect(service.lastError != nil)
            }
        }

        @Test func claim_storesProfileAndMintsOneSession() async throws {
            try await withFakeStorage {
                let mints = Counter()
                let service = try makeService { request in
                    switch (request.httpMethod, request.url?.path) {
                    case ("POST", "/id"):
                        #expect(bodyString(request) == #"{"osaurus_id":"rex-42"}"#)
                        return json(profileJSON, status: 201)
                    case ("POST", "/id/sessions"):
                        _ = mints.increment()
                        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                        return json(
                            #"{"token":"osk_minted","session":{"id":"s1","label":"Mac","expires_at":"2099-01-01T00:00:00Z"}}"#,
                            status: 201
                        )
                    default:
                        Issue.record("unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                        throw URLError(.badURL)
                    }
                }
                // Input is trimmed and lowercased before the claim.
                let outcome = await service.claim(handle: "  Rex-42 ")
                #expect(outcome == .claimed(OsaurusIDProfile(osaurusID: "rex-42")))
                #expect(service.state == .claimed)
                #expect(OsaurusIDSessionStore.token() == "osk_minted")
                #expect(mints.current == 1)

                // A second claim on this account would not mint again.
                _ = await service.claim(handle: "rex-42")
                #expect(mints.current == 1)
            }
        }

        @Test func claim_rejectsMalformedHandleWithoutNetwork() async throws {
            try await withFakeStorage {
                let service = try makeService { _ in
                    Issue.record("no request expected")
                    throw URLError(.badURL)
                }
                if case .failed = await service.claim(handle: "Rex!") {} else { Issue.record("expected failure") }
                #expect(service.state == .unknown)
            }
        }

        /// 409 "already has an Osaurus ID" (claimed on another machine) adopts the
        /// existing profile instead of failing; 409 "taken" is a plain failure
        /// the claim field can show.
        @Test func claim_adoptsExistingProfileOnAlreadyHasAndFailsOnTaken() async throws {
            try await withFakeStorage {
                let service = try makeService { request in
                    switch (request.httpMethod, request.url?.path) {
                    case ("POST", "/id"):
                        return json(
                            #"{"error":{"code":"INVALID_STATE","message":"this account already has an Osaurus ID"}}"#,
                            status: 409
                        )
                    case ("GET", "/id/me"):
                        return json(
                            #"{"osaurus_id":"first-pick","display_name":"","email":null,"email_public":false,"bio":""}"#
                        )
                    case ("POST", "/id/sessions"):
                        return json(#"{"token":"osk_minted","session":{"id":"s1","label":"Mac"}}"#, status: 201)
                    default:
                        Issue.record("unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                        throw URLError(.badURL)
                    }
                }
                #expect(await service.claim(handle: "rex-42") == .adopted(OsaurusIDProfile(osaurusID: "first-pick")))
                #expect(service.claimedHandle == "first-pick")

                let fresh = try makeService { request in
                    switch (request.httpMethod, request.url?.path) {
                    case ("POST", "/id"):
                        return json(
                            #"{"error":{"code":"INVALID_STATE","message":"this Osaurus ID is already taken"}}"#,
                            status: 409
                        )
                    default:
                        Issue.record("unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                        throw URLError(.badURL)
                    }
                }
                guard case .failed(let message) = await fresh.claim(handle: "rex-42") else {
                    Issue.record("expected failure")
                    return
                }
                #expect(message.contains("already taken"))
                #expect(fresh.state == .unknown)
            }
        }

        @Test func update_patchesOnlyChangedFieldsAndAppliesServerTruth() async throws {
            try await withFakeStorage {
                let service = try makeService { request in
                    switch (request.httpMethod, request.url?.path) {
                    case ("GET", "/id/me"): return json(profileJSON)
                    case ("PATCH", "/id/me"):
                        #expect(bodyString(request) == #"{"bio":"hello","display_name":"Rexy"}"#)
                        // The server may normalize; the client adopts its answer.
                        return json(
                            #"{"osaurus_id":"rex-42","display_name":"Rexy","email":null,"email_public":false,"bio":"hello"}"#
                        )
                    default:
                        Issue.record("unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                        throw URLError(.badURL)
                    }
                }
                await service.refresh()
                let outcome = await service.update(displayName: " Rexy ", bio: "hello\n")
                guard case .updated(let profile) = outcome else {
                    Issue.record("expected update: \(outcome)")
                    return
                }
                #expect(profile.displayName == "Rexy")
                #expect(service.profile?.bio == "hello")

                // Nothing to send: no request, current profile returned.
                #expect(await service.update() == .updated(profile))
            }
        }

        /// Master key created / restored / wiped: the session token belonged to
        /// the old wallet and the profile may belong to another account.
        @Test func identityChange_clearsSessionAndResolvesAgain() async throws {
            try await withFakeStorage {
                let service = try makeService { request in
                    #expect(request.url?.path == "/id/me")
                    // A token minted for the previous wallet is rejected by the
                    // router; the wallet-signed retry then answers authoritatively.
                    if request.value(forHTTPHeaderField: "Authorization") != nil {
                        return json(
                            #"{"error":{"code":"UNAUTHORIZED","message":"session token invalid"}}"#,
                            status: 401
                        )
                    }
                    return json(
                        #"{"error":{"code":"NOT_FOUND","message":"no Osaurus ID claimed for this account"}}"#,
                        status: 404
                    )
                }
                OsaurusIDSessionStore.save(token: "osk_old_wallet", sessionID: "s0", expiresAt: nil)
                _ = await service.refresh()
                #expect(service.state == .unclaimed)
                #expect(OsaurusIDSessionStore.token() == nil, "the dead bearer token is dropped on 401")

                OsaurusIDSessionStore.save(token: "osk_old_wallet", sessionID: "s0", expiresAt: nil)
                service.handleIdentityChanged()
                #expect(OsaurusIDSessionStore.token() == nil)
                #expect(service.state == .unknown)
                // The follow-up refresh runs on the main actor; let it settle.
                for _ in 0 ..< 50 where service.state == .unknown {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(service.state == .unclaimed)
            }
        }

        // MARK: helpers

        private func withFakeStorage<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
            OsaurusIDSessionStore._setStorageForTesting(InMemorySessionStorage())
            defer { OsaurusIDSessionStore._setStorageForTesting(nil) }
            return try await body()
        }

        private func makeService(
            handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
        ) throws -> OsaurusIDService {
            OsaurusIDServiceURLProtocol.handler = handler
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OsaurusIDServiceURLProtocol.self]
            let session = URLSession(configuration: config)
            let baseURL = try #require(URL(string: "https://router.test"))
            let client = OsaurusRouterAPIClient(
                baseURL: baseURL,
                session: session,
                authOverride: { request, _ in
                    request.setValue(TestKeys.aliceAddress.lowercased(), forHTTPHeaderField: "x-wallet-address")
                }
            )
            return OsaurusIDService(client: client, canReachOverride: true, observesNotifications: false)
        }
    }
}

// MARK: - Test doubles

private typealias StubHandler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

/// Stub transport. Each suite gets its own subclass (and so its own static
/// handler slot) because suites run in parallel with each other.
private class OsaurusIDStubURLProtocol: URLProtocol, @unchecked Sendable {
    class var handler: StubHandler? {
        get { nil }
        set {}
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = type(of: self).handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data, headers) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OsaurusIDClientURLProtocol: OsaurusIDStubURLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stored: StubHandler?
    override class var handler: StubHandler? {
        get { stored }
        set { stored = newValue }
    }
}

private final class OsaurusIDServiceURLProtocol: OsaurusIDStubURLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stored: StubHandler?
    override class var handler: StubHandler? {
        get { stored }
        set { stored = newValue }
    }
}

/// In-memory session storage so store/service tests never touch the login
/// keychain (with or without `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS`) and never
/// share the process-global `Keychain` backend override with `KeychainTests`.
private final class InMemorySessionStorage: OsaurusIDSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var forced: KeychainReadOutcome?

    var data: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }

    /// When set, every read returns this outcome (locked keychain, etc.).
    var forcedRead: KeychainReadOutcome? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return forced
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            forced = newValue
        }
    }

    func read() -> KeychainReadOutcome {
        if let forcedRead { return forcedRead }
        if let data { return .found(data) }
        return .notFound
    }

    func write(_ data: Data) { self.data = data }
    func delete() { data = nil }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

private func json(_ body: String, status: Int = 200) -> (Int, Data, [String: String]) {
    (status, Data(body.utf8), ["content-type": "application/json"])
}

private func bodyString(_ request: URLRequest) -> String {
    if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let size = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: size)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}
