import Foundation

/// Presentation-ready state for redeem-code entry. Each UI surface owns its
/// own instance so typed codes and errors do not leak between onboarding and
/// Settings, while all Router and error semantics stay in one place.
@MainActor
final class RedeemCodeService: ObservableObject {
    enum Context: Equatable {
        case onboarding
        case credits
    }

    enum SubmissionState: Equatable {
        case idle
        case submitting
        case success(OsaurusRouterRedeemCodeResponse)
        case failure(String)
    }

    @Published var code = ""
    @Published private(set) var state: SubmissionState = .idle
    @Published private(set) var retryNotBefore: Date?

    private let context: Context
    private let client: OsaurusRouterAPIClient
    private let ensureIdentity: @MainActor () async throws -> Void
    private let refreshFixedCredit: @MainActor () async -> Void
    private let onAcquisitionRedemption: @MainActor () -> Void
    private let acquisitionGateBlocking: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async -> Void
    private var retryReleaseTask: Task<Void, Never>?

    init(
        context: Context,
        client: OsaurusRouterAPIClient = .shared,
        ensureIdentity: (@MainActor () async throws -> Void)? = nil,
        refreshFixedCredit: (@MainActor () async -> Void)? = nil,
        onAcquisitionRedemption: (@MainActor () -> Void)? = nil,
        acquisitionGateBlocking: (@MainActor () -> Bool)? = nil,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: (@MainActor (TimeInterval) async -> Void)? = nil
    ) {
        self.context = context
        self.client = client
        self.ensureIdentity =
            ensureIdentity
            ?? {
                if !OsaurusIdentity.exists() {
                    _ = try await OsaurusIdentity.setup()
                }
            }
        self.refreshFixedCredit =
            refreshFixedCredit
            ?? {
                await OsaurusRouterAccountService.shared.refreshBalance()
                await OsaurusRouterAccountService.shared.refreshTransactions(reset: true)
            }
        self.onAcquisitionRedemption =
            onAcquisitionRedemption
            ?? {
                WelcomeCreditService.shared.suppressAfterCodeRedemption()
                RouterCreditAcquisitionCoordinator.shared.resolveAfterCodeRedemption()
            }
        self.acquisitionGateBlocking =
            acquisitionGateBlocking
            ?? { RouterCreditAcquisitionCoordinator.shared.blocksGeneralSignedRequests }
        self.now = now
        self.sleep =
            sleep
            ?? { delay in
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
    }

    deinit {
        retryReleaseTask?.cancel()
    }

    var normalizedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        guard !normalizedCode.isEmpty, state != .submitting else { return false }
        if let retryNotBefore, now() < retryNotBefore { return false }
        return true
    }

    var isSubmitting: Bool {
        state == .submitting
    }

    var succeeded: Bool {
        if case .success = state { return true }
        return false
    }

    func submit() async {
        let submittedCode = normalizedCode
        guard !submittedCode.isEmpty else {
            state = .failure(L("Enter a redeemable code."))
            return
        }
        guard canSubmit else { return }

        // Freeze the exact normalized value displayed to the user for this
        // attempt. A retry without an edit therefore signs identical JSON.
        code = submittedCode
        state = .submitting

        do {
            try await ensureIdentity()
        } catch let error as OsaurusRouterAPIError {
            handle(error)
            return
        } catch {
            // Identity setup is a local keychain operation, not a network
            // call — "check your connection" would point the user at the
            // wrong problem.
            state = .failure(L("We couldn’t set up your Osaurus Identity. Please try again."))
            return
        }

        do {
            let rawResponse = try await client.redeemCode(submittedCode)
            guard rawResponse.redeemed else {
                throw OsaurusRouterAPIError.invalidResponse
            }

            let response = Self.presentationSafe(rawResponse)
            if context == .onboarding || acquisitionGateBlocking() {
                // A redeemed code settles the wallet's first-action choice:
                // suppress the mutually exclusive welcome claim and open the
                // signing gate before refreshing balance, so the refresh is
                // intentionally the next signed Router request. Outside a
                // blocking phase (existing installs redeeming from Credits)
                // welcome-credit behavior is left untouched.
                onAcquisitionRedemption()
            }
            if (Int64(response.amountMicro) ?? 0) != 0 {
                await refreshFixedCredit()
            }
            retryNotBefore = nil
            retryReleaseTask?.cancel()
            state = .success(response)
        } catch let error as OsaurusRouterAPIError {
            handle(error)
        } catch {
            state = .failure(L("We couldn’t redeem this code. Check your connection and try again."))
        }
    }

    func resetForAnotherCode() {
        guard !isSubmitting else { return }
        code = ""
        state = .idle
    }

    func noteCodeEdited() {
        guard !isSubmitting else { return }
        if case .failure = state {
            state = .idle
        }
    }

    private func handle(_ error: OsaurusRouterAPIError) {
        switch error {
        case .rateLimited(let retryAfter):
            applyRateLimit(retryAfter)
            state = .failure(L("Too many attempts. Please wait before trying again."))
        case .server(_, _, let status) where status == 400:
            state = .failure(L("Check the code and try again."))
        case .server(_, _, let status) where status == 403:
            state = .failure(L("This code isn’t available for this account."))
        case .server(_, _, let status) where status >= 500:
            state = .failure(L("The redeem service is temporarily unavailable. Please try again."))
        case .unauthorized:
            state = .failure(L("We couldn’t verify your identity. Please try again."))
        case .accountFrozen:
            state = .failure(L("This code isn’t available for this account."))
        case .transport:
            state = .failure(L("We couldn’t redeem this code. Check your connection and try again."))
        case .firstActionPending:
            state = .failure(L("Finish the welcome-credit choice before trying this code."))
        case .noIdentity:
            state = .failure(L("Set up your Osaurus Identity before redeeming a code."))
        case .invalidResponse:
            state = .failure(L("The redeem service returned an invalid response. Please try again."))
        case .invalidURL, .server, .belowMinimumTopUp, .insufficientFunds,
            .paidWebDisabled, .idempotencyConflict:
            state = .failure(error.localizedDescription)
        }
    }

    private func applyRateLimit(_ retryAfter: String?) {
        retryReleaseTask?.cancel()
        let delay = WelcomeCreditService.backoffInterval(retryAfter: retryAfter)
        let deadline = now().addingTimeInterval(delay)
        retryNotBefore = deadline
        retryReleaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            if self.now() >= deadline {
                self.retryNotBefore = nil
            }
        }
    }

    /// The Router contract caps this at 500 characters. Clamp defensively so a
    /// malformed response can never turn into an unbounded UI payload.
    private static func presentationSafe(
        _ response: OsaurusRouterRedeemCodeResponse
    ) -> OsaurusRouterRedeemCodeResponse {
        OsaurusRouterRedeemCodeResponse(
            redeemed: response.redeemed,
            alreadyRedeemed: response.alreadyRedeemed,
            campaignKind: response.campaignKind,
            amountMicro: response.amountMicro,
            referralPending: response.referralPending,
            redemptionMessage: String(response.redemptionMessage.prefix(500))
        )
    }
}
