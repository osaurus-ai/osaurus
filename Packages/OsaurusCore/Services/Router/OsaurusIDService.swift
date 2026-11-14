//
//  OsaurusIDService.swift
//  OsaurusCore
//
//  Client-side owner of the router's Osaurus ID profile: the `@handle` a
//  person claims for their master key. The server is the source of truth;
//  this object caches the profile in memory for the Identity tab and any
//  surface that wants to show the handle, and keeps one silent `osk_…`
//  session token so routine reads/edits never re-touch the master key.
//

import AppKit
import Foundation

@MainActor
public final class OsaurusIDService: ObservableObject {
    public static let shared = OsaurusIDService()

    enum State: Equatable, Sendable {
        /// Nothing fetched yet (or the router is unreachable).
        case unknown
        /// The router authoritatively reports no Osaurus ID for this account.
        case unclaimed
        /// A profile exists.
        case claimed
    }

    /// Outcome of `claim` for the Identity tab.
    enum ClaimOutcome: Equatable, Sendable {
        case claimed(OsaurusIDProfile)
        /// The account already had an Osaurus ID (claimed on another
        /// machine); the existing profile was adopted instead of erroring.
        case adopted(OsaurusIDProfile)
        case failed(String)
    }

    enum RefreshOutcome: Equatable, Sendable {
        case claimed(OsaurusIDProfile)
        case unclaimed
        case unavailable(String)
    }

    enum UpdateOutcome: Equatable, Sendable {
        case updated(OsaurusIDProfile)
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var profile: OsaurusIDProfile?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isClaiming = false
    @Published private(set) var isSaving = false
    /// Last transport/server error from any call, or nil. Cleared on the
    /// next success.
    @Published private(set) var lastError: String?

    private let client: OsaurusRouterAPIClient
    private let canReachOverride: Bool?
    private var identityObserver: NSObjectProtocol?

    init(
        client: OsaurusRouterAPIClient = .shared,
        canReachOverride: Bool? = nil,
        observesNotifications: Bool = true
    ) {
        self.client = client
        self.canReachOverride = canReachOverride
        guard observesNotifications else { return }
        identityObserver = NotificationCenter.default.addObserver(
            forName: .osaurusIdentityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleIdentityChanged() }
        }
    }

    /// Both gates for any `/id/*` traffic: the router master switch and a
    /// master key to sign with (or a session token derived from one). Never
    /// under tests: identity tests post `.osaurusIdentityChanged` freely, and
    /// developer machines carry real credentials.
    var canReach: Bool {
        if let canReachOverride { return canReachOverride }
        return !RuntimeEnvironment.isUnderTests
            && OsaurusRouter.isEnabled && OsaurusIdentity.existsCached()
    }

    /// The claimed handle (`rex-42`, no `@`) or nil. Cheap for hot paths.
    var claimedHandle: String? {
        state == .claimed ? profile?.osaurusID : nil
    }

    // MARK: - Refresh (server truth)

    /// Pull `GET /id/me`. A 404 `NOT_FOUND` is the authoritative "no Osaurus
    /// ID yet" answer. Transient failures keep the prior state.
    @discardableResult
    func refresh() async -> RefreshOutcome {
        guard canReach else {
            return .unavailable(L("Osaurus Router or secure identity is unavailable."))
        }
        guard !isRefreshing else {
            return .unavailable(L("Osaurus ID refresh is already in progress."))
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await client.osaurusIDProfile()
            apply(fetched)
            return .claimed(fetched)
        } catch let error as OsaurusRouterAPIError where error.isOsaurusIDNotFound {
            profile = nil
            state = .unclaimed
            lastError = nil
            return .unclaimed
        } catch {
            lastError = error.localizedDescription
            return .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Availability

    /// Pre-claim availability for the claim field. Returns nil when the
    /// check can't run right now (router off, no master key, network) — the
    /// claim itself remains the authority either way.
    func checkAvailability(_ candidate: String) async -> OsaurusIDAvailabilityStatus? {
        guard OsaurusIDValidator.isValid(candidate) else { return .invalid }
        guard canReach else { return nil }
        return try? await client.osaurusIDAvailability(candidate).status
    }

    // MARK: - Claim

    /// Claim `handle` for this account and best-effort mint a session token
    /// for future `/id/*` calls. When the account already has an Osaurus ID
    /// (claimed on another machine), the existing profile is adopted.
    func claim(handle rawHandle: String) async -> ClaimOutcome {
        let handle = rawHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard OsaurusRouter.isEnabled else {
            return .failed(L("Turn on the Osaurus Router in Settings to claim an Osaurus ID."))
        }
        guard OsaurusIDValidator.isValid(handle) else {
            return .failed(L("Osaurus IDs are 3–20 characters: a–z, 0–9, and hyphens."))
        }
        guard !isClaiming else {
            return .failed(L("A claim is already in progress."))
        }
        isClaiming = true
        defer { isClaiming = false }

        do {
            let claimed = try await client.claimOsaurusID(handle: handle)
            apply(claimed)
            await bootstrapSessionIfNeeded()
            return .claimed(claimed)
        } catch let error as OsaurusRouterAPIError {
            if error.indicatesAccountAlreadyHasOsaurusID,
                let existing = try? await client.osaurusIDProfile()
            {
                apply(existing)
                await bootstrapSessionIfNeeded()
                return .adopted(existing)
            }
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Profile edits

    /// Push a display-name / bio edit to the server. `displayName == ""`
    /// clears the display name (clients fall back to the handle). Pass nil
    /// to leave a field alone. The server response is applied back so a
    /// rejected or adjusted PATCH reconverges local state to server truth.
    func update(displayName: String? = nil, bio: String? = nil) async -> UpdateOutcome {
        guard canReach else {
            return .failed(L("Osaurus Router or secure identity is unavailable."))
        }
        guard !isSaving else {
            return .failed(L("A save is already in progress."))
        }
        let patch = OsaurusIDProfilePatch(
            displayName: displayName.map(OsaurusIDDisplayName.sanitized),
            bio: bio.map(OsaurusIDBio.sanitized)
        )
        guard patch.displayName != nil || patch.bio != nil else {
            if let profile { return .updated(profile) }
            return .failed(L("Nothing to save."))
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await client.updateOsaurusIDProfile(patch)
            apply(updated)
            return .updated(updated)
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func apply(_ profile: OsaurusIDProfile) {
        self.profile = profile
        state = .claimed
        lastError = nil
    }

    /// Mint and store an `osk_…` session token once, so routine `/id/*`
    /// calls never re-touch the master key. Failure is fine — wallet signing
    /// keeps working.
    private func bootstrapSessionIfNeeded() async {
        guard OsaurusIDSessionStore.token() == nil else { return }
        let label = Host.current().localizedName ?? "Mac"
        guard let response = try? await client.createOsaurusIDSession(label: label) else { return }
        OsaurusIDSessionStore.save(
            token: response.token,
            sessionID: response.session.id,
            expiresAt: OsaurusIDSessionStore.expiryDate(from: response.session.expiresAt)
        )
    }

    /// The master key was created, restored, or wiped: the old session token
    /// (bound to the previous wallet) is dead, and whatever profile we held
    /// may belong to a different account. Reset and re-resolve.
    func handleIdentityChanged() {
        OsaurusIDSessionStore.clear()
        profile = nil
        state = .unknown
        lastError = nil
        Task { await refresh() }
    }
}
