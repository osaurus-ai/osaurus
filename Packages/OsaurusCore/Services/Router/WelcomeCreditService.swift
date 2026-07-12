//
//  WelcomeCreditService.swift
//  osaurus
//
//  Client for the Router's one-time welcome credit
//  (`POST /credits/welcome/claim`). Claims automatically on the user's
//  behalf — right after identity setup, at app launch, and on app
//  activation — so brand-new users never have to redeem anything by hand.
//
//  Claim semantics (see docs/osaurus-integration.md in osaurus-router):
//  - The request is wallet-signed like every other route; the body carries a
//    stable per-Mac `device_id` hash (`WelcomeCreditDeviceID`) so one machine
//    can't claim repeatedly across reinstalls.
//  - A retry of the same claim returns `already_granted: true` — network
//    failures are safe to retry, and both shapes count as success here.
//  - 403 is intentionally unexplained (feature off, not a new account, or
//    the wallet/device already claimed): terminal — hide the offer silently,
//    never retry.
//  - 400 means the request itself is malformed (a client bug, since our
//    `device_id` is always a valid 64-char hash): also terminal, so a
//    shipped bug degrades to a hidden offer instead of an error loop.
//  - 429 has a strict dedicated limit: honor `retry-after` and never burn
//    attempts by hammering the endpoint.
//

import AppKit
import Foundation

@MainActor
final class WelcomeCreditService {
    static let shared = WelcomeCreditService()

    /// Terminal outcome of the claim flow, persisted so it survives restarts.
    enum Resolution: String {
        /// The credit landed (or had already landed for this wallet). Done.
        case granted
        /// The Router refused the claim (403/400). The offer must be hidden
        /// and the claim never retried.
        case hidden
    }

    // MARK: - Persistence keys

    static let resolutionDefaultsKey = "ai.osaurus.router.welcome.resolution"

    /// Fallback backoff when a 429 arrives without a parseable `retry-after`.
    static let defaultRateLimitBackoff: TimeInterval = 600

    // MARK: - State

    private var isClaiming = false

    private let client: OsaurusRouterAPIClient
    private let defaults: UserDefaults
    private let identityExists: @MainActor () -> Bool
    private let isRouterEnabled: () -> Bool
    private let deviceId: () -> String?
    /// Post-grant hook: refresh the balance (and the ledger, where the promo
    /// entry appears). Injectable so tests don't touch the live account
    /// service.
    private let onGranted: @MainActor () async -> Void

    /// Earliest moment the next claim attempt may fire after a 429.
    /// In-memory on purpose: the triggers are rare (launch, identity change,
    /// app activation), so persisting the deadline buys nothing.
    private(set) var retryNotBefore: Date?

    private var identityObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    init(
        client: OsaurusRouterAPIClient = .shared,
        defaults: UserDefaults = .standard,
        identityExists: @escaping @MainActor () -> Bool = { OsaurusIdentity.existsCached() },
        isRouterEnabled: @escaping () -> Bool = { OsaurusRouter.isEnabled },
        deviceId: @escaping () -> String? = { WelcomeCreditDeviceID.current() },
        onGranted: (@MainActor () async -> Void)? = nil,
        observesNotifications: Bool = true
    ) {
        self.client = client
        self.defaults = defaults
        self.identityExists = identityExists
        self.isRouterEnabled = isRouterEnabled
        self.deviceId = deviceId
        self.onGranted =
            onGranted
            ?? {
                await OsaurusRouterAccountService.shared.refreshBalance()
                await OsaurusRouterAccountService.shared.refreshTransactions(reset: true)
            }

        guard observesNotifications else { return }
        // First setup: identity creation posts this the moment the master key
        // exists — the earliest point a signed claim can succeed.
        identityObserver = NotificationCenter.default.addObserver(
            forName: .osaurusIdentityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.claimIfNeeded() }
        }
        // Recovery: an attempt that failed transiently (offline at setup)
        // retries when the user comes back to the app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.claimIfNeeded() }
        }
    }

    // MARK: - Public surface

    /// Persisted terminal outcome, if any.
    var resolution: Resolution? {
        defaults.string(forKey: Self.resolutionDefaultsKey).flatMap(Resolution.init(rawValue:))
    }

    /// Launch-time entry point: retry a claim a previous session couldn't
    /// finish (e.g. the first launch was offline).
    func bootstrapAtLaunch() {
        Task { await claimIfNeeded() }
    }

    /// Attempt the one-time claim if every precondition holds. Returns true
    /// when the flow is settled as granted (now or previously); false when it
    /// remains pending or is terminally hidden.
    @discardableResult
    func claimIfNeeded() async -> Bool {
        switch resolution {
        case .granted: return true
        case .hidden: return false
        case nil: break
        }
        guard isRouterEnabled(), identityExists() else { return false }
        // No stable per-Mac id, no claim: the server rejects a missing
        // device_id, and a random fallback would break the one-per-Mac
        // invariant.
        guard let deviceId = deviceId() else { return false }
        guard !isClaiming else { return false }
        if let deadline = retryNotBefore, Date() < deadline { return false }

        isClaiming = true
        defer { isClaiming = false }

        do {
            _ = try await client.claimWelcomeCredit(deviceId: deviceId)
            // `granted` or `already_granted` — either way the credit is on
            // the wallet.
            resolve(.granted)
            await onGranted()
            return true
        } catch let error as OsaurusRouterAPIError {
            handleClaimError(error)
            return false
        } catch {
            // Unknown transport-level failure: retry on the next trigger
            // (the claim is idempotent server-side).
            return false
        }
    }

    // MARK: - Error handling

    private func handleClaimError(_ error: OsaurusRouterAPIError) {
        switch error {
        case .rateLimited(let retryAfter):
            // Strict dedicated limit — never hammer. Honor `retry-after`,
            // fall back to a conservative pause when it's absent/unparseable.
            retryNotBefore = Date().addingTimeInterval(
                Self.backoffInterval(retryAfter: retryAfter)
            )
        case .server(_, _, let status) where status == 403 || status == 400:
            // 403 is intentionally unexplained (disabled, not a new account,
            // or already claimed by wallet/device); 400 means the request is
            // malformed. Both are terminal: hide the offer, never retry.
            resolve(.hidden)
        case .unauthorized, .accountFrozen, .noIdentity, .invalidURL:
            // Not claim verdicts: signing/identity/config problems. A later
            // trigger (identity ready, clock fixed) may succeed.
            break
        case .transport, .invalidResponse, .server, .insufficientFunds,
            .belowMinimumTopUp, .rateLimited:
            // Transient or unrelated server-side trouble: retry on the next
            // trigger.
            break
        }
    }

    private func resolve(_ resolution: Resolution) {
        defaults.set(resolution.rawValue, forKey: Self.resolutionDefaultsKey)
        retryNotBefore = nil
    }

    /// Seconds to wait after a 429. `retry-after` arrives as delta-seconds or
    /// an HTTP-date; anything unparseable gets the conservative default.
    static func backoffInterval(retryAfter: String?) -> TimeInterval {
        guard let raw = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return defaultRateLimitBackoff }
        if let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        if let date = formatter.date(from: raw) {
            return max(1, date.timeIntervalSinceNow)
        }
        return defaultRateLimitBackoff
    }
}
