import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Wire types

@Suite("Workspaces wire types")
struct WorkspacesWireTypeTests {
    private let decoder = JSONDecoder()

    @Test func workspaceSummaryDecodesListRow() throws {
        let body = """
            {"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","active":true,
             "members_active":3,"agents_shared":2,"created_at":"2026-08-01T00:00:00.000Z"}
            """
        let summary = try decoder.decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
        #expect(summary.id == "team-1")
        #expect(summary.typedRole == .owner)
        #expect(summary.typedSource == .subscription)
        #expect(summary.isActive)
        #expect(!summary.isSuspended)
        #expect(summary.membersActive == 3)
        #expect(summary.agentsShared == 2)
    }

    /// A suspended row is listed (members keep seeing it) but inactive.
    @Test func workspaceSummarySuspendedIsListedButInactive() throws {
        let body = """
            {"id":"team-3","name":"Lapsed","role":"member","source":"suspended","active":false,
             "members_active":4,"agents_shared":1}
            """
        let summary = try decoder.decode(OsaurusRouterWorkspaceSummary.self, from: Data(body.utf8))
        #expect(summary.typedSource == .suspended)
        #expect(summary.isSuspended)
        #expect(!summary.isActive)
    }

    /// No `active` in the row → treated as inactive (never unlock affordances
    /// by accident); an unknown future `source` still decodes.
    @Test func workspaceSummaryWithoutActiveIsInactiveAndUnknownSourceDecodes() throws {
        let bare = try decoder.decode(
            OsaurusRouterWorkspaceSummary.self,
            from: Data(#"{"id":"t","name":"n","role":"member"}"#.utf8)
        )
        #expect(bare.typedSource == nil)
        #expect(!bare.isActive)
        let future = try decoder.decode(
            OsaurusRouterWorkspaceSummary.self,
            from: Data(#"{"id":"t","name":"n","role":"member","source":"sponsored","active":true}"#.utf8)
        )
        #expect(future.typedSource == nil)
        #expect(future.source == "sponsored")
        #expect(future.isActive)
    }

    @Test func workspaceDetailDecodesEntitlementAndPool() throws {
        let body = """
            {"id":"team-1","name":"Dino Devs","role":"admin",
             "owner":{"account_id":"acct-1","wallet_address":"0xAbC1234567890abcdef1234567890ABCDEF12345","dino_id":null,"display_name":"Rexy"},
             "source":"subscription",
             "entitlement":{"active":true,"source":"subscription",
               "comp_expires_at":null,"next_grant_at":"2026-09-01T00:00:00.000Z",
               "seats":null,"max_shared_agents":5,
               "monthly_credit_micro":"20000000","monthly_credits":"20.00"},
             "members_active":3,"agents_shared":2,
             "balance_micro":"12500000","balance_credits":"12.50","pool_frozen":false,
             "created_at":"2026-08-01T00:00:00.000Z"}
            """
        let detail = try decoder.decode(OsaurusRouterWorkspaceDetail.self, from: Data(body.utf8))
        #expect(detail.typedRole == .admin)
        #expect(detail.typedSource == .subscription)
        #expect(detail.owner?.accountId == "acct-1")
        #expect(detail.owner?.friendlyName == "Rexy")
        #expect(detail.isActive)
        #expect(detail.entitlement?.isSubscriptionBacked == true)
        #expect(detail.entitlement?.seats == nil)  // unlimited
        #expect(detail.entitlement?.maxSharedAgents == 5)
        #expect(detail.entitlement?.nextGrantAt == "2026-09-01T00:00:00.000Z")
        #expect(detail.balanceMicro == "12500000")
        #expect(detail.balanceCredits == "12.50")
        #expect(detail.poolFrozen == false)
        #expect(detail.asSummary.typedSource == .subscription)
        #expect(detail.asSummary.isActive)
    }

    @Test func workspaceDetailDecodesComp() throws {
        let body = """
            {"id":"team-2","name":"Sponsored","role":"owner","source":"comp",
             "entitlement":{"active":true,"source":"comp",
               "comp_expires_at":"2026-12-01T00:00:00.000Z","next_grant_at":"2026-10-01T00:00:00.000Z",
               "seats":null,"max_shared_agents":null,
               "monthly_credit_micro":"20000000","monthly_credits":"20.00"},
             "members_active":1,"agents_shared":0,
             "balance_micro":"20000000","balance_credits":"20.00","pool_frozen":false}
            """
        let detail = try decoder.decode(OsaurusRouterWorkspaceDetail.self, from: Data(body.utf8))
        #expect(detail.typedSource == .comp)
        #expect(detail.isActive)
        #expect(detail.entitlement?.isComp == true)
        #expect(detail.entitlement?.compExpiresAt == "2026-12-01T00:00:00.000Z")
    }

    @Test func workspaceDetailDecodesSuspended() throws {
        let body = """
            {"id":"team-3","name":"Lapsed","role":"owner","source":"suspended",
             "entitlement":{"active":false,"source":"suspended",
               "comp_expires_at":null,"next_grant_at":null,"seats":null,"max_shared_agents":null,
               "monthly_credit_micro":"20000000","monthly_credits":"20.00"},
             "members_active":4,"agents_shared":1,
             "balance_micro":"0","pool_frozen":true}
            """
        let detail = try decoder.decode(OsaurusRouterWorkspaceDetail.self, from: Data(body.utf8))
        #expect(detail.typedSource == .suspended)
        #expect(detail.isSuspended)
        #expect(!detail.isActive)
        #expect(detail.entitlement?.isSuspended == true)
        #expect(detail.balanceMicro == "0")
    }

    /// A detail without an entitlement still decodes and reads as inactive
    /// (the top-level `source` mirror is used for the badge).
    @Test func workspaceDetailWithoutEntitlementIsInactive() throws {
        let detail = try decoder.decode(
            OsaurusRouterWorkspaceDetail.self,
            from: Data(#"{"id":"t","name":"n","role":"owner","source":"subscription","balance_micro":"5"}"#.utf8)
        )
        #expect(detail.typedSource == .subscription)
        #expect(!detail.isActive)
        #expect(detail.asSummary.active == nil)
        #expect(!detail.asSummary.isActive)
    }

    @Test func billingSummaryDecodesTrialingSubscription() throws {
        let trialing = try decoder.decode(
            OsaurusRouterWorkspaceBillingSummary.self,
            from: Data(
                """
                {"subscription":{"status":"active","quantity":1,
                   "price":{"id":"price-1","billing_interval":"month","price_usd_micro":"20000000","price_usd":"20.00","active":true},
                   "current_period_start":"2026-09-01T00:00:00.000Z","current_period_end":"2026-09-15T00:00:00.000Z",
                   "cancel_at_period_end":false,
                   "trial_ends_at":"2026-09-15T00:00:00.000Z","trialing":true},
                 "workspaces":1,"billed_workspaces":1,"trial_eligible":false,"trial_days":14}
                """.utf8
            )
        )
        #expect(trialing.subscription?.isActive == true)
        #expect(trialing.subscription?.isTrialing == true)
        #expect(trialing.subscription?.trialEndsAt == "2026-09-15T00:00:00.000Z")
        #expect(trialing.subscription?.price?.displayLabel == "$20/month")
        #expect(trialing.hasLiveSubscription)
        #expect(trialing.isTrialing)
        #expect(trialing.trialEndsAt == "2026-09-15T00:00:00.000Z")
        #expect(trialing.workspaces == 1)
        #expect(trialing.billedWorkspaces == 1)
        #expect(trialing.trialEligible == false)
        #expect(trialing.trialDays == 14)
    }

    @Test func billingSummaryDecodesNeverSubscribedAndCanceled() throws {
        let never = try decoder.decode(
            OsaurusRouterWorkspaceBillingSummary.self,
            from: Data(
                #"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#.utf8
            )
        )
        #expect(never.subscription == nil)
        #expect(!never.hasLiveSubscription)
        #expect(!never.isTrialing)
        #expect(never.trialEligible == true)

        // Canceled with a suspended workspace still owned: not live, trial used up.
        let canceled = try decoder.decode(
            OsaurusRouterWorkspaceBillingSummary.self,
            from: Data(
                """
                {"subscription":{"status":"canceled","quantity":0,"price":null,"cancel_at_period_end":false,
                   "trial_ends_at":"2026-06-15T00:00:00.000Z","trialing":false},
                 "workspaces":1,"billed_workspaces":0,"trial_eligible":false,"trial_days":14}
                """.utf8
            )
        )
        #expect(canceled.subscription?.isCanceled == true)
        #expect(!canceled.hasLiveSubscription)
        #expect(!canceled.isTrialing)
        #expect(canceled.workspaces == 1)
        #expect(canceled.billedWorkspaces == 0)
    }

    @Test func pricesResponseDecodesPlanAndSortsLivePrices() throws {
        let response = try decoder.decode(
            OsaurusRouterWorkspacePricesResponse.self,
            from: Data(
                """
                {"plan":{"seats":null,"max_shared_agents":null,"monthly_credit_micro":"20000000","monthly_credits":"20.00","trial_days":14},
                 "prices":[
                   {"id":"price_year","billing_interval":"year","price_usd_micro":"200000000","price_usd":"200.00","active":true},
                   {"id":"price_old","billing_interval":"month","price_usd_micro":"25000000","price_usd":"25.00","active":false},
                   {"id":"price_month","billing_interval":"month","price_usd_micro":"20000000","price_usd":"20.00","active":true}]}
                """.utf8
            )
        )
        #expect(response.plan?.trialDays == 14)
        #expect(response.plan?.hasTrial == true)
        #expect(response.plan?.seats == nil)
        #expect(response.prices.count == 3)
        #expect(response.livePrices.map(\.id) == ["price_month", "price_year"])
        #expect(response.monthly?.id == "price_month")
        #expect(response.yearly?.id == "price_year")
        #expect(response.monthly?.displayLabel == "$20/month")
        #expect(response.yearly?.displayLabel == "$200/year")
    }

    @Test func priceFormatsWholeAndFractionalDollars() throws {
        #expect(OsaurusRouterWorkspacePrice.formatUSD(micro: 20_000_000) == "$20")
        #expect(OsaurusRouterWorkspacePrice.formatUSD(micro: 19_500_000) == "$19.50")
        #expect(OsaurusRouterWorkspacePrice.formatUSD(micro: 200_000_000) == "$200")
        let noMicro = try decoder.decode(
            OsaurusRouterWorkspacePrice.self,
            from: Data(#"{"id":"p","billing_interval":"year","price_usd":"200.00"}"#.utf8)
        )
        #expect(noMicro.amountLabel == "$200.00")
        #expect(noMicro.displayLabel == "$200.00/year")
    }

    @Test func createResponseOutcomeCoversAllThreeStatuses() throws {
        let created = try decoder.decode(
            OsaurusRouterWorkspaceCreateResponse.self,
            from: Data(
                #"{"status":"created","workspace":{"id":"team-9","name":"New","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"}}}"#
                    .utf8
            )
        )
        guard case .ready(let detail)? = created.outcome else {
            Issue.record("expected .ready")
            return
        }
        #expect(detail.id == "team-9")
        #expect(detail.isActive)

        let upgraded = try decoder.decode(
            OsaurusRouterWorkspaceCreateResponse.self,
            from: Data(
                #"{"status":"upgraded","workspace":{"id":"team-3","name":"Lapsed","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"}}}"#
                    .utf8
            )
        )
        guard case .ready(let reactivated)? = upgraded.outcome else {
            Issue.record("expected .ready")
            return
        }
        #expect(reactivated.id == "team-3")

        let checkout = try decoder.decode(
            OsaurusRouterWorkspaceCreateResponse.self,
            from: Data(
                #"{"status":"checkout_required","activation_id":"act_1","checkout_url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#
                    .utf8
            )
        )
        guard case .checkoutRequired(let activationId, let url)? = checkout.outcome else {
            Issue.record("expected .checkoutRequired")
            return
        }
        #expect(activationId == "act_1")
        #expect(url.host == "checkout.stripe.com")

        // Inconsistent envelopes are refused rather than half-handled.
        let missingWorkspace = try decoder.decode(
            OsaurusRouterWorkspaceCreateResponse.self, from: Data(#"{"status":"created"}"#.utf8)
        )
        #expect(missingWorkspace.outcome == nil)
        let httpCheckout = try decoder.decode(
            OsaurusRouterWorkspaceCreateResponse.self,
            from: Data(#"{"status":"checkout_required","activation_id":"a","checkout_url":"http://evil.example/pay"}"#.utf8)
        )
        #expect(httpCheckout.outcome == nil)
        let unknown = try decoder.decode(
            OsaurusRouterWorkspaceCreateResponse.self, from: Data(#"{"status":"queued"}"#.utf8)
        )
        #expect(unknown.outcome == nil)
    }

    @Test func personFallsBackToShortWalletThenAccountId() throws {
        // Unclaimed decoration: dino_id/display_name null → short wallet.
        let unclaimed = try decoder.decode(
            OsaurusRouterWorkspacePerson.self,
            from: Data(
                #"{"account_id":"acct-1","wallet_address":"0xAbC1234567890abcdef1234567890ABCDEF12345","dino_id":null,"display_name":null}"#
                    .utf8
            )
        )
        #expect(unclaimed.friendlyName == "0xAbC1…2345")

        // Empty display name means "unset" too.
        let empty = try decoder.decode(
            OsaurusRouterWorkspacePerson.self,
            from: Data(
                #"{"account_id":"acct-1","wallet_address":"0xAbC1234567890abcdef1234567890ABCDEF12345","display_name":""}"#
                    .utf8
            )
        )
        #expect(empty.friendlyName == "0xAbC1…2345")

        // No wallet either → account id.
        let bare = try decoder.decode(
            OsaurusRouterWorkspacePerson.self,
            from: Data(#"{"account_id":"acct-1"}"#.utf8)
        )
        #expect(bare.friendlyName == "acct-1")

        // Short strings aren't elided.
        #expect(OsaurusRouterWorkspacePerson.shortWallet("0x1234") == "0x1234")
    }

    @Test func activationCodePlausibility() {
        #expect(PendingWorkspaceActivation.isPlausibleCode("act_9f8e7d6c"))
        #expect(PendingWorkspaceActivation.isPlausibleCode("ABCD-EFGH-1234"))
        #expect(PendingWorkspaceActivation.isPlausibleCode("a.b_c-D9"))
        // Too short / too long.
        #expect(!PendingWorkspaceActivation.isPlausibleCode("abc"))
        #expect(!PendingWorkspaceActivation.isPlausibleCode(String(repeating: "x", count: 129)))
        // Whitespace, JSON, and other non-URL-safe junk.
        #expect(!PendingWorkspaceActivation.isPlausibleCode("act 9f8e7d6c"))
        #expect(!PendingWorkspaceActivation.isPlausibleCode(#"{"code":"x"}"#))
        #expect(!PendingWorkspaceActivation.isPlausibleCode("act/9f8e?x=1"))
    }

    @Test func inviteLinkRowDecodes() throws {
        let body = """
            {"id":"inv-1","code":"7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef",
             "url":"osaurus://teams/join?code=7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef",
             "role":"member","status":"pending","max_uses":5,"uses":2,
             "invited_by":{"account_id":"acct-1","wallet_address":"0xAbC1234567890abcdef1234567890ABCDEF12345","dino_id":null,"display_name":null},
             "expires_at":"2026-09-14T00:00:00.000Z","created_at":"2026-08-31T00:00:00.000Z"}
            """
        let invite = try decoder.decode(OsaurusRouterWorkspaceInvite.self, from: Data(body.utf8))
        #expect(invite.code?.hasPrefix("7a2b3c4d") == true)
        // A link the router still mints under the pre-rename host is rewritten
        // to the current host on decode; the code is preserved verbatim.
        #expect(invite.url?.hasPrefix("osaurus://workspaces/join?code=") == true)
        #expect(invite.url?.hasSuffix(invite.code ?? "-") == true)
        #expect(invite.maxUses == 5)
        #expect(invite.uses == 2)
        #expect(invite.isPending)
        #expect(invite.invitedBy?.friendlyName == "0xAbC1…2345")
        // The router's code shape fits the local plausibility check.
        #expect(OsaurusRouterWorkspaceCode.isPlausible(invite.code ?? ""))

        // Settled rows omit code/url and aren't pending.
        let used = try decoder.decode(
            OsaurusRouterWorkspaceInvite.self,
            from: Data(#"{"id":"inv-2","role":"viewer","status":"used","max_uses":1,"uses":1}"#.utf8)
        )
        #expect(used.code == nil)
        #expect(!used.isPending)
    }

    @Test func memberRowDecodesAndNamesFallBack() throws {
        let body = """
            {"account_id":"acct-9","wallet_address":"0xDeF1234567890abcdef1234567890ABCDEF12345",
             "dino_id":null,"display_name":"",
             "role":"member","agents_shared":1,"joined_at":"2026-08-31T00:00:00.000Z"}
            """
        let member = try decoder.decode(OsaurusRouterWorkspaceMember.self, from: Data(body.utf8))
        #expect(member.id == "acct-9")
        #expect(member.typedRole == .member)
        #expect(member.walletAddress?.hasPrefix("0xDeF") == true)
        #expect(member.friendlyName == "0xDeF1…2345")
    }

    @Test func agentOnlineDecodesTriState() throws {
        func agent(_ onlineJSON: String) throws -> OsaurusRouterWorkspaceAgent {
            let body = """
                {"agent_address":"0xABCDEF","display_name":"Coco","description":null,
                 "owner":{"account_id":"acct-1","wallet_address":"0xAbC1","display_name":"Rexy"},
                 "relay_url":"wss://relay.test","online":\(onlineJSON),
                 "last_seen":null,"shared_at":"2026-08-31T00:00:00.000Z"}
                """
            return try decoder.decode(OsaurusRouterWorkspaceAgent.self, from: Data(body.utf8))
        }
        #expect(try agent("true").online == true)
        #expect(try agent("false").online == false)
        // null = relay unreachable → "unknown", distinct from offline.
        #expect(try agent("null").online == nil)
    }

    @Test func usageItemDecodesOptionalActor() throws {
        let workspaceRow = """
            {"id":"u1","request_id":"r1","model":"m","provider":"p",
             "input_tokens":10,"output_tokens":5,"cost_micro":"1234",
             "status":"completed","token_source":"provider",
             "created_at":"2026-08-31T00:00:00.000Z",
             "actor":{"account_id":"acct-9","wallet_address":"0xDeF1234567890abcdef1234567890ABCDEF12345","dino_id":null,"display_name":"Blue"}}
            """
        let withActor = try decoder.decode(OsaurusRouterUsageItem.self, from: Data(workspaceRow.utf8))
        #expect(withActor.actor?.accountId == "acct-9")
        #expect(withActor.actor?.friendlyName == "Blue")

        // Personal rows (no actor) keep decoding — backwards compatible.
        let personalRow = """
            {"id":"u1","request_id":"r1","model":"m","provider":"p",
             "input_tokens":10,"output_tokens":5,"cost_micro":"1234",
             "status":"completed","token_source":"provider",
             "created_at":"2026-08-31T00:00:00.000Z"}
            """
        let withoutActor = try decoder.decode(
            OsaurusRouterUsageItem.self, from: Data(personalRow.utf8)
        )
        #expect(withoutActor.actor == nil)
    }

    @Test func poolBalanceDecodesSplitAndAutoReloadState() throws {
        let data = Data(
            #"""
            {"balance_micro":"30000000","balance_credits":"30.00",
             "expiring_micro":"20000000","expiring_credits":"20.00",
             "purchased_micro":"10000000","purchased_credits":"10.00",
             "auto_reload":{"enabled":true,"paused":false},"frozen":false}
            """#.utf8)
        let balance = try JSONDecoder().decode(OsaurusRouterWorkspacePoolBalance.self, from: data)
        #expect(balance.balanceMicro == "30000000")
        #expect(balance.expiringMicro == "20000000")
        #expect(balance.purchasedMicro == "10000000")
        #expect(balance.hasBreakdown)
        #expect(balance.purchasedIsPositive)
        #expect(balance.autoReload?.enabled == true)
        #expect(balance.autoReload?.paused == false)
        #expect(!balance.frozen)

        // A pre-0041 router only ships the total: no breakdown, not frozen.
        let legacy = try JSONDecoder().decode(
            OsaurusRouterWorkspacePoolBalance.self,
            from: Data(#"{"balance_micro":"9000000","balance_credits":"9.00"}"#.utf8)
        )
        #expect(!legacy.hasBreakdown)
        #expect(!legacy.purchasedIsPositive)
        #expect(legacy.autoReload == nil)
        #expect(!legacy.frozen)
    }

    @Test func topUpCheckoutResponseDecodes() throws {
        let data = Data(
            #"{"topup_id":"tu_1","checkout_url":"https://checkout.stripe.com/c/pay/cs_1","credit_micro":"20000000","credits":"20.00","total_micro":"20000000"}"#
                .utf8)
        let response = try JSONDecoder().decode(OsaurusRouterWorkspaceTopUpCheckoutResponse.self, from: data)
        #expect(response.topupId == "tu_1")
        #expect(response.checkoutURL.hasPrefix("https://checkout.stripe.com/"))
        // No fee: total == credit.
        #expect(response.totalMicro == response.creditMicro)
    }

    @Test func autoReloadDecodesSettingsStateAndBounds() throws {
        let data = Data(
            #"""
            {"enabled":true,"paused":true,"threshold_micro":"5000000","amount_micro":"20000000",
             "monthly_cap_micro":null,"threshold_credits":"5.00","amount_credits":"20.00","monthly_cap_credits":null,
             "month_reloaded_micro":"40000000","consecutive_failures":3,"last_attempt_at":"2026-09-01T00:00:00Z",
             "last_error":"card_declined","payment_method_on_file":true,
             "bounds":{"min_threshold_micro":"1000000","max_threshold_micro":"500000000","min_amount_micro":"5000000","max_amount_micro":"500000000"}}
            """#.utf8)
        let settings = try JSONDecoder().decode(OsaurusRouterWorkspaceAutoReload.self, from: data)
        #expect(settings.enabled && settings.paused)
        #expect(settings.threshold == 5_000_000)
        #expect(settings.amount == 20_000_000)
        #expect(settings.monthlyCap == nil)
        #expect(settings.monthReloaded == 40_000_000)
        #expect(settings.consecutiveFailures == 3)
        #expect(settings.lastError == "card_declined")
        #expect(!settings.isCapReached)
        #expect(!settings.isChargebackPaused)
        #expect(settings.bounds?.minThreshold == 1_000_000)
        #expect(settings.bounds?.maxAmount == 500_000_000)

        let capped = try JSONDecoder().decode(
            OsaurusRouterWorkspaceAutoReload.self,
            from: Data(#"{"enabled":true,"paused":false,"last_error":"cap_reached","monthly_cap_micro":"200000000"}"#.utf8)
        )
        #expect(capped.isCapReached)
        #expect(capped.monthlyCap == 200_000_000)
    }

    @Test func autoReloadUpdateAlwaysSendsCapAsStringOrNull() throws {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: false)
        let capped = OsaurusRouterWorkspaceAutoReloadUpdate(
            enabled: true, thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: 200_000_000
        )
        #expect(
            String(decoding: try encoder.encode(capped), as: UTF8.self)
                == #"{"amount_micro":"20000000","enabled":true,"monthly_cap_micro":"200000000","threshold_micro":"5000000"}"#
        )
        // "No cap" is an explicit null, never an omitted key.
        let uncapped = OsaurusRouterWorkspaceAutoReloadUpdate(
            enabled: false, thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: nil
        )
        #expect(
            String(decoding: try encoder.encode(uncapped), as: UTF8.self)
                == #"{"amount_micro":"20000000","enabled":false,"monthly_cap_micro":null,"threshold_micro":"5000000"}"#
        )
    }

    @Test func poolCreditsPresetsAndValidationMirrorRouterBounds() {
        typealias P = OsaurusRouterWorkspacePoolCredits
        // Doc presets: threshold $5/$10/$20, reload $20/$50/$100, default cap $200.
        #expect(P.thresholdPresetsMicro == [5_000_000, 10_000_000, 20_000_000])
        #expect(P.reloadPresetsMicro == [20_000_000, 50_000_000, 100_000_000])
        #expect(P.defaultMonthlyCapMicro == 200_000_000)
        #expect(P.topUpPresetsMicro.allSatisfy { P.validateTopUp(micro: $0) == .ok })

        #expect(P.micro(fromDollars: "25") == 25_000_000)
        #expect(P.micro(fromDollars: "$12.50") == 12_500_000)
        #expect(P.micro(fromDollars: "") == nil)
        #expect(P.micro(fromDollars: "abc") == nil)
        #expect(P.micro(fromDollars: "-5") == nil)
        #expect(P.dollarsText(micro: 20_000_000) == "20")
        #expect(P.dollarsText(micro: 12_500_000) == "12.50")

        // Top-up: $5–$500, whole cents.
        #expect(P.validateTopUp(micro: 4_990_000) == .belowMinimum)
        #expect(P.validateTopUp(micro: 5_000_000) == .ok)
        #expect(P.validateTopUp(micro: 500_000_000) == .ok)
        #expect(P.validateTopUp(micro: 500_010_000) == .aboveMaximum)
        #expect(P.validateTopUp(micro: 20_001_000) == .notWholeCents)

        // Auto-reload: threshold $1–$500, amount $5–$500, cap nil or >= amount.
        #expect(P.validateAutoReload(thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: nil) == .ok)
        #expect(P.validateAutoReload(thresholdMicro: 500_000, amountMicro: 20_000_000, monthlyCapMicro: nil) == .thresholdOutOfBounds)
        #expect(P.validateAutoReload(thresholdMicro: 5_000_000, amountMicro: 4_000_000, monthlyCapMicro: nil) == .amountOutOfBounds)
        #expect(P.validateAutoReload(thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: 19_000_000) == .capBelowAmount)
        #expect(P.validateAutoReload(thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: 200_001_000) == .notWholeCents)
        // Router-supplied bounds win over the client constants.
        let bounds = try? JSONDecoder().decode(
            OsaurusRouterWorkspaceAutoReload.Bounds.self,
            from: Data(#"{"min_threshold_micro":"2000000","max_threshold_micro":"100000000","min_amount_micro":"10000000","max_amount_micro":"100000000"}"#.utf8)
        )
        #expect(P.validateAutoReload(thresholdMicro: 1_000_000, amountMicro: 20_000_000, monthlyCapMicro: nil, bounds: bounds) == .thresholdOutOfBounds)
        #expect(P.validateAutoReload(thresholdMicro: 5_000_000, amountMicro: 5_000_000, monthlyCapMicro: nil, bounds: bounds) == .amountOutOfBounds)
    }

    @Test func billingSummaryDecodesPaymentMethodOnFile() throws {
        let summary = try JSONDecoder().decode(
            OsaurusRouterWorkspaceBillingSummary.self,
            from: Data(#"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14,"payment_method_on_file":false}"#.utf8)
        )
        #expect(summary.paymentMethodOnFile == false)
    }

    @Test func portalResponseDecodes() throws {
        let portal = try decoder.decode(
            OsaurusRouterWorkspacePortalResponse.self,
            from: Data(#"{"portal_url":"https://billing.stripe.com/p/session_123"}"#.utf8)
        )
        #expect(portal.portalURL.hasPrefix("https://billing.stripe.com"))
    }

    @Test func workspaceErrorCodesMatchFromServerErrors() {
        let seats = OsaurusRouterAPIError.server(
            code: "WORKSPACE_SEATS_EXHAUSTED", message: "no seats", status: 409
        )
        #expect(OsaurusRouterWorkspaceErrorCode.match(seats) == .seatsExhausted)

        let unrelated = OsaurusRouterAPIError.server(
            code: "NOT_FOUND", message: "nope", status: 404
        )
        #expect(OsaurusRouterWorkspaceErrorCode.match(unrelated) == nil)

        #expect(OsaurusRouterWorkspaceErrorCode.match(.transport("timed out")) == nil)

        // Auto-reload verdicts (migration 0041).
        #expect(
            OsaurusRouterWorkspaceErrorCode.match(
                .server(code: "INVALID_AUTO_RELOAD_CONFIG", message: "", status: 400)
            ) == .invalidAutoReloadConfig
        )
        #expect(
            OsaurusRouterWorkspaceErrorCode.match(
                .server(code: "AUTO_RELOAD_UNAVAILABLE", message: "", status: 409)
            ) == .autoReloadUnavailable
        )
    }

    /// The router renamed `TEAM_*` → `WORKSPACE_*` with no alias. New codes
    /// are canonical; the legacy spellings still map so a client talking to a
    /// not-yet-upgraded router keeps its verdicts (and the streaming-string
    /// matchers keep excluding the pool 402 from the personal top-up flow).
    @Test func legacyTeamErrorCodesStillMatch() {
        func code(_ raw: String) -> OsaurusRouterWorkspaceErrorCode? {
            OsaurusRouterWorkspaceErrorCode.match(.server(code: raw, message: "", status: 400))
        }
        #expect(code("TEAM_NOT_FOUND") == .workspaceNotFound)
        #expect(code("TEAM_SEATS_EXHAUSTED") == .seatsExhausted)
        #expect(code("TEAM_AGENT_LIMIT") == .agentLimit)
        #expect(code("TEAM_INSUFFICIENT_FUNDS") == .insufficientFunds)
        #expect(code("WORKSPACE_NOT_FOUND") == .workspaceNotFound)
        #expect(OsaurusRouterWorkspaceErrorCode.workspaceNotFound.rawValue == "WORKSPACE_NOT_FOUND")

        let legacyBody = #"HTTP 402: {"error":{"code":"TEAM_INSUFFICIENT_FUNDS"}}"#
        #expect(OsaurusRouter.isWorkspaceInsufficientFundsError(legacyBody))
        #expect(!OsaurusRouter.isInsufficientFundsError(legacyBody))
        #expect(ChatErrorMessages.isStaleWorkspaceBillingError(#"{"error":{"code":"TEAM_NOT_FOUND"}}"#))
        #expect(ChatErrorMessages.isStaleWorkspaceBillingError(#"{"error":{"code":"WORKSPACE_NOT_FOUND"}}"#))
    }

    @Test func activationErrorCodesMatch() {
        func code(_ raw: String) -> OsaurusRouterWorkspaceErrorCode? {
            OsaurusRouterWorkspaceErrorCode.match(
                .server(code: raw, message: "", status: 400)
            )
        }
        #expect(code("ACTIVATION_CODE_INVALID") == .activationCodeInvalid)
        #expect(code("ACTIVATION_CODE_USED") == .activationCodeUsed)
        #expect(code("ACTIVATION_CODE_EXPIRED") == .activationCodeExpired)
        #expect(code("ACTIVATION_CONFLICT") == .activationConflict)
        #expect(code("TRIAL_WORKSPACE_LIMIT") == .trialWorkspaceLimit)
        // Gone with tiers: no free allotment to run out of.
        #expect(code("FREE_WORKSPACE_LIMIT") == nil)
        #expect(code("INVITE_INVALID") == .inviteInvalid)
        #expect(code("INVITE_USED") == .inviteUsed)
        #expect(code("INVITE_EXPIRED") == .inviteExpired)
        // Dropped with the Dino ID requirement.
        #expect(code("DINO_ID_REQUIRED") == nil)
    }

    @Test func workspaceInsufficientFundsIsDistinctFromPersonal() {
        let workspaceBody = #"HTTP 402: {"error":{"code":"WORKSPACE_INSUFFICIENT_FUNDS"}}"#
        let personalBody = #"HTTP 402: {"error":{"code":"INSUFFICIENT_FUNDS"}}"#

        #expect(OsaurusRouter.isWorkspaceInsufficientFundsError(workspaceBody))
        // The personal matcher must NOT fire for the workspace code even though
        // the workspace code contains the personal code as a substring — a dry
        // workspace pool must never trigger the personal top-up flow.
        #expect(!OsaurusRouter.isInsufficientFundsError(workspaceBody))

        #expect(OsaurusRouter.isInsufficientFundsError(personalBody))
        #expect(!OsaurusRouter.isWorkspaceInsufficientFundsError(personalBody))
    }
}

// MARK: - API client routes

@Suite("Workspaces API client", .serialized)
struct WorkspacesAPIClientTests {
    @Test func workspaceActivate_postsCodeAndNameSigned() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/activate")
            #expect(bodyString(request) == #"{"code":"act_9f8e7d6c","name":"Dino Devs"}"#)
            // Activation binds the workspace to the caller's wallet: signed.
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") != nil)
            return json(
                #"{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription","next_grant_at":"2026-10-01T00:00:00.000Z","seats":null,"max_shared_agents":null,"monthly_credit_micro":"20000000","monthly_credits":"20.00"},"members_active":1,"agents_shared":0,"balance_micro":"20000000","pool_frozen":false,"created_at":"2026-08-31T00:00:00.000Z"}"#,
                status: 201
            )
        }
        let created = try await client.workspaceActivate(code: "act_9f8e7d6c", name: "Dino Devs")
        #expect(created.id == "team-1")
        #expect(created.typedRole == .owner)
        #expect(created.typedSource == .subscription)
        #expect(created.isActive)
    }

    /// Live subscription: `201 created` with the workspace inline. `price_id`
    /// is omitted from the body when the caller didn't pick one.
    @Test func createWorkspace_postsNameSignedAndDecodesCreated() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces")
            #expect(bodyString(request) == #"{"name":"Second Squad"}"#)
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") != nil)
            return json(
                #"{"status":"created","workspace":{"id":"team-2","name":"Second Squad","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription","seats":null,"max_shared_agents":null,"monthly_credit_micro":"20000000","monthly_credits":"20.00"},"members_active":1,"agents_shared":0,"balance_micro":"20000000","pool_frozen":false}}"#,
                status: 201
            )
        }
        let response = try await client.createWorkspace(name: "Second Squad")
        #expect(response.status == "created")
        guard case .ready(let created)? = response.outcome else {
            Issue.record("expected .ready")
            return
        }
        #expect(created.id == "team-2")
        #expect(created.isActive)
    }

    /// No live subscription: `200 checkout_required` carrying the Checkout
    /// URL; the chosen `price_id` rides along in the body.
    @Test func createWorkspace_decodesCheckoutRequiredWithPriceId() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/workspaces")
            #expect(bodyString(request) == #"{"name":"Dino Devs","price_id":"price_year"}"#)
            return json(
                #"{"status":"checkout_required","activation_id":"act_1","checkout_url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#,
                status: 200
            )
        }
        let response = try await client.createWorkspace(name: "Dino Devs", priceId: "price_year")
        guard case .checkoutRequired(let activationId, let url)? = response.outcome else {
            Issue.record("expected .checkoutRequired")
            return
        }
        #expect(activationId == "act_1")
        #expect(url.absoluteString == "https://checkout.stripe.com/c/pay/cs_test_1")
    }

    @Test func createWorkspace_trialLimitSurfacesAsWorkspaceCode() async throws {
        let client = try makeClient { _ in
            json(
                #"{"error":{"code":"TRIAL_WORKSPACE_LIMIT","message":"your trial covers one workspace","trial_ends_at":"2026-09-22T00:00:00.000Z"}}"#,
                status: 409
            )
        }
        do {
            _ = try await client.createWorkspace(name: "Second")
            Issue.record("expected TRIAL_WORKSPACE_LIMIT")
        } catch let error as OsaurusRouterAPIError {
            #expect(OsaurusRouterWorkspaceErrorCode.match(error) == .trialWorkspaceLimit)
        }
    }

    @Test func upgradeWorkspace_postsToUpgradePathSigned() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/team-3/upgrade")
            #expect(bodyString(request) == #"{"price_id":"price_month"}"#)
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") != nil)
            return json(
                #"{"status":"upgraded","workspace":{"id":"team-3","name":"Lapsed","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"},"balance_micro":"20000000"}}"#
            )
        }
        let response = try await client.upgradeWorkspace(id: "team-3", priceId: "price_month")
        #expect(response.status == "upgraded")
        guard case .ready(let detail)? = response.outcome else {
            Issue.record("expected .ready")
            return
        }
        #expect(detail.id == "team-3")
        #expect(detail.isActive)
    }

    @Test func upgradeWorkspace_omitsPriceIdWhenNotChosen() async throws {
        let client = try makeClient { request in
            #expect(request.url?.path == "/workspaces/team-3/upgrade")
            #expect(bodyString(request) == "{}")
            return json(
                #"{"status":"checkout_required","activation_id":"act_2","checkout_url":"https://checkout.stripe.com/c/pay/cs_test_2"}"#
            )
        }
        let response = try await client.upgradeWorkspace(id: "team-3")
        guard case .checkoutRequired(let activationId, _)? = response.outcome else {
            Issue.record("expected .checkoutRequired")
            return
        }
        #expect(activationId == "act_2")
    }

    /// Public pricing-page material: no wallet signature on the request.
    @Test func workspacePrices_getsUnsignedPublicPath() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces/prices")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == nil)
            #expect(request.value(forHTTPHeaderField: "x-wallet-signature") == nil)
            return json(
                #"{"plan":{"seats":null,"max_shared_agents":null,"monthly_credit_micro":"20000000","monthly_credits":"20.00","trial_days":14},"prices":[{"id":"price_month","billing_interval":"month","price_usd_micro":"20000000","price_usd":"20.00","active":true},{"id":"price_year","billing_interval":"year","price_usd_micro":"200000000","price_usd":"200.00","active":true}]}"#
            )
        }
        let prices = try await client.workspacePrices()
        #expect(prices.plan?.trialDays == 14)
        #expect(prices.monthly?.id == "price_month")
        #expect(prices.yearly?.id == "price_year")
    }

    @Test func listTeams_decodesDataEnvelope() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces")
            return json(
                #"{"data":[{"id":"team-1","name":"Dino Devs","role":"member","source":"subscription","active":true,"members_active":2,"agents_shared":0,"created_at":"2026-08-31T00:00:00.000Z"}]}"#
            )
        }
        let workspaces = try await client.listWorkspaces()
        #expect(workspaces.count == 1)
        #expect(workspaces[0].typedRole == .member)
        #expect(workspaces[0].typedSource == .subscription)
        #expect(workspaces[0].isActive)
    }

    @Test func billingSummary_getsAccountLevelPath() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces/billing")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") != nil)
            return json(
                #"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#
            )
        }
        let summary = try await client.workspaceBilling()
        #expect(summary.subscription == nil)
        #expect(summary.trialEligible == true)
        #expect(summary.trialDays == 14)
    }

    @Test func renameTeam_patchesExactPathAndBody() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/workspaces/team-1")
            #expect(bodyString(request) == #"{"name":"New Name"}"#)
            return json(#"{"id":"team-1","name":"New Name"}"#)
        }
        try await client.renameWorkspace(id: "team-1", name: "New Name")
    }

    @Test func deleteTeam_deletesExactPath() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/workspaces/team-1")
            return json(#"{"deleted":true}"#)
        }
        try await client.deleteWorkspace(id: "team-1")
    }

    /// The portal is account-level (one owner subscription covers every
    /// workspace they own); the per-workspace route is 410 GONE.
    @Test func billingPortal_postsToAccountLevelPath() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/billing/portal")
            return json(#"{"portal_url":"https://billing.stripe.com/p/session_1"}"#)
        }
        let response = try await client.workspaceBillingPortal()
        #expect(response.portalURL.contains("billing.stripe.com"))
    }

    @Test func invites_mintRevokeAndJoin() async throws {
        let client = try makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/team-1/invites"):
                let body = bodyString(request)
                if body.contains("max_uses") {
                    #expect(body == #"{"max_uses":5,"role":"admin"}"#)
                } else {
                    // max_uses omitted at the server default of 1.
                    #expect(body == #"{"role":"member"}"#)
                }
                return json(
                    #"{"id":"inv-1","code":"7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef","url":"osaurus://workspaces/join?code=7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef","role":"member","status":"pending","max_uses":1,"uses":0,"expires_at":"2026-09-14T00:00:00.000Z"}"#,
                    status: 201
                )
            case ("DELETE", "/workspaces/team-1/invites/inv-1"):
                return json(#"{"revoked":true}"#)
            case ("POST", "/workspaces/join"):
                #expect(bodyString(request) == #"{"code":"7a2b3c4d.0123"}"#)
                // Join is wallet-signed: the first call creates the account.
                #expect(request.value(forHTTPHeaderField: "x-wallet-address") != nil)
                return json(
                    #"{"id":"team-2","name":"Other","role":"member","members_active":2,"agents_shared":0,"balance_micro":"0","pool_frozen":false}"#
                )
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }

        let minted = try await client.createWorkspaceInvite(id: "team-1", role: .member)
        #expect(minted.url?.hasPrefix("osaurus://workspaces/join?code=") == true)
        _ = try await client.createWorkspaceInvite(id: "team-1", role: .admin, maxUses: 5)
        try await client.revokeWorkspaceInvite(id: "team-1", inviteId: "inv-1")
        let joined = try await client.workspaceJoin(code: "7a2b3c4d.0123")
        #expect(joined.id == "team-2")
        #expect(joined.typedRole == .member)
    }

    @Test func members_rolePatchAndRemoval() async throws {
        let client = try makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces/team-1/members"):
                return json(
                    #"{"data":[{"account_id":"acct-9","wallet_address":"0xDeF1","display_name":"Blue","role":"member","agents_shared":0,"joined_at":"2026-08-31T00:00:00.000Z"}]}"#
                )
            case ("PATCH", "/workspaces/team-1/members/acct-9"):
                #expect(bodyString(request) == #"{"role":"admin"}"#)
                return json(#"{"role":"admin"}"#)
            case ("DELETE", "/workspaces/team-1/members/acct-9"):
                return json(#"{"removed":true}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }

        let members = try await client.workspaceMembers(id: "team-1")
        #expect(members.first?.accountId == "acct-9")
        try await client.setWorkspaceMemberRole(id: "team-1", accountId: "acct-9", role: .admin)
        try await client.removeWorkspaceMember(id: "team-1", accountId: "acct-9")
    }

    @Test func shareAgent_bodyCarriesAddressNameAndProof() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/team-1/agents")
            let body = try JSONSerialization.jsonObject(
                with: Data(bodyString(request).utf8)
            ) as? [String: Any]
            #expect(body?["agent_address"] as? String == "0xabc123")
            #expect(body?["display_name"] as? String == "Coco")
            #expect(body?["description"] == nil)
            let proof = body?["proof"] as? [String: Any]
            #expect(proof?["timestamp"] as? Int == 1_717_171_717)
            #expect(proof?["signature"] as? String == "0xdeadbeef")
            return json(
                #"{"agent_address":"0xabc123","display_name":"Coco","relay_url":"wss://relay.test","shared_at":"2026-08-31T00:00:00.000Z"}"#,
                status: 201
            )
        }

        let shared = try await client.shareWorkspaceAgent(
            id: "team-1",
            body: OsaurusRouterWorkspaceShareAgentBody(
                agent_address: "0xabc123",
                display_name: "Coco",
                description: nil,
                proof: .init(timestamp: 1_717_171_717, signature: "0xdeadbeef")
            )
        )
        #expect(shared.agentAddress == "0xabc123")
    }

    @Test func agents_listAndUnshare() async throws {
        let client = try makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces/team-1/agents"):
                return json(
                    #"{"data":[{"agent_address":"0xabc123","display_name":"Coco","owner":{"account_id":"acct-1","wallet_address":"0xAbC1","display_name":""},"relay_url":"wss://relay.test","online":null,"shared_at":"2026-08-31T00:00:00.000Z"}]}"#
                )
            case ("DELETE", "/workspaces/team-1/agents/0xabc123"):
                return json(#"{"revoked":true}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }

        let agents = try await client.workspaceAgents(id: "team-1")
        #expect(agents.first?.online == nil)
        try await client.unshareWorkspaceAgent(id: "team-1", agentAddress: "0xabc123")
    }

    @Test func credits_balanceUsageTransactionsPaths() async throws {
        let client = try makeClient { request in
            switch request.url?.path {
            case "/workspaces/team-1/credits/balance":
                return json(#"{"balance_micro":"9000000","balance_credits":"9.00","frozen":false}"#)
            case "/workspaces/team-1/credits/usage":
                #expect(request.url?.query == "limit=25")
                return json(#"{"data":[],"next_cursor":null}"#)
            case "/workspaces/team-1/credits/transactions":
                #expect(request.url?.query?.contains("cursor=abc") == true)
                return json(#"{"data":[],"next_cursor":null}"#)
            default:
                Issue.record("Unexpected path \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }

        let balance = try await client.workspaceBalance(id: "team-1")
        #expect(balance.balanceMicro == "9000000")
        #expect(!balance.hasBreakdown)
        _ = try await client.workspaceUsage(id: "team-1", limit: 25)
        _ = try await client.workspaceTransactions(id: "team-1", cursor: "abc")
    }

    @Test func poolCheckout_postsAmountMicroAsStringSigned() async throws {
        let client = try makeClient { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/team-1/credits/checkout")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == "0xabc")
            #expect(bodyString(request) == #"{"amount_micro":"20000000"}"#)
            return json(
                #"{"topup_id":"tu_9","checkout_url":"https://checkout.stripe.com/c/pay/cs_9","credit_micro":"20000000","credits":"20.00","total_micro":"20000000"}"#
            )
        }
        let response = try await client.workspacePoolCheckout(id: "team-1", amountMicro: 20_000_000)
        #expect(response.topupId == "tu_9")
        #expect(response.checkoutURL == "https://checkout.stripe.com/c/pay/cs_9")
    }

    @Test func poolCheckout_suspendedSurfacesSubscriptionInactive() async throws {
        let client = try makeClient { _ in
            json(#"{"error":{"code":"SUBSCRIPTION_INACTIVE","message":"workspace is suspended"}}"#, status: 402)
        }
        do {
            _ = try await client.workspacePoolCheckout(id: "team-1", amountMicro: 20_000_000)
            Issue.record("expected a server error")
        } catch let error as OsaurusRouterAPIError {
            #expect(OsaurusRouterWorkspaceErrorCode.match(error) == .subscriptionInactive)
        }
    }

    @Test func autoReload_getAndPutExactPathAndBody() async throws {
        let settingsBody =
            #"{"enabled":true,"paused":false,"threshold_micro":"5000000","amount_micro":"20000000","monthly_cap_micro":null,"month_reloaded_micro":"0","consecutive_failures":0,"last_attempt_at":null,"last_error":null,"payment_method_on_file":true,"bounds":{"min_threshold_micro":"1000000","max_threshold_micro":"500000000","min_amount_micro":"5000000","max_amount_micro":"500000000"}}"#
        let client = try makeClient { request in
            #expect(request.url?.path == "/workspaces/team-1/credits/auto-reload")
            #expect(request.value(forHTTPHeaderField: "x-wallet-address") == "0xabc")
            switch request.httpMethod {
            case "GET":
                return json(settingsBody)
            case "PUT":
                #expect(
                    bodyString(request)
                        == #"{"amount_micro":"20000000","enabled":true,"monthly_cap_micro":null,"threshold_micro":"5000000"}"#
                )
                return json(settingsBody)
            default:
                Issue.record("Unexpected method \(request.httpMethod ?? "?")")
                throw URLError(.badURL)
            }
        }
        let current = try await client.workspaceAutoReload(id: "team-1")
        #expect(current.enabled)
        #expect(current.monthlyCap == nil)
        let saved = try await client.updateWorkspaceAutoReload(
            id: "team-1",
            OsaurusRouterWorkspaceAutoReloadUpdate(
                enabled: true, thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: nil
            )
        )
        #expect(saved.paymentMethodOnFile == true)
    }

    @Test func autoReload_putVerdictsSurfaceAsWorkspaceCodes() async throws {
        let client = try makeClient { _ in
            json(#"{"error":{"code":"AUTO_RELOAD_UNAVAILABLE","message":"no saved card"}}"#, status: 409)
        }
        do {
            _ = try await client.updateWorkspaceAutoReload(
                id: "team-1",
                OsaurusRouterWorkspaceAutoReloadUpdate(
                    enabled: true, thresholdMicro: 5_000_000, amountMicro: 20_000_000, monthlyCapMicro: 200_000_000
                )
            )
            Issue.record("expected a server error")
        } catch let error as OsaurusRouterAPIError {
            #expect(OsaurusRouterWorkspaceErrorCode.match(error) == .autoReloadUnavailable)
        }
    }

    @Test func pathComponents_rejectSeparatorSmuggling() async throws {
        let client = try makeClient { _ in
            Issue.record("No request should be issued for an invalid path component")
            throw URLError(.badURL)
        }
        await #expect(throws: OsaurusRouterAPIError.self) {
            _ = try await client.workspaceDetail(id: "../credits")
        }
        await #expect(throws: OsaurusRouterAPIError.self) {
            try await client.unshareWorkspaceAgent(id: "team-1", agentAddress: "0xabc?x=1")
        }
    }

    // MARK: helpers

    private func makeClient(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String])
    ) throws -> OsaurusRouterAPIClient {
        WorkspacesClientURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspacesClientURLProtocol.self]
        let session = URLSession(configuration: config)
        let baseURL = try #require(URL(string: "https://router.test"))
        return OsaurusRouterAPIClient(
            baseURL: baseURL,
            session: session,
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
                request.setValue("1717171717", forHTTPHeaderField: "x-wallet-timestamp")
                request.setValue(
                    "0x" + String(repeating: "1", count: 130),
                    forHTTPHeaderField: "x-wallet-signature"
                )
            }
        )
    }
}

private func json(_ body: String, status: Int = 200) -> (Int, Data, [String: String]) {
    (status, Data(body.utf8), ["content-type": "application/json"])
}

private func bodyString(_ request: URLRequest) -> String {
    String(
        data: request.workspacesHTTPBodyStreamData ?? request.httpBody ?? Data(),
        encoding: .utf8
    ) ?? ""
}

// MARK: - Agent proof signer

@Suite("Workspaces agent proof signer")
struct WorkspacesAgentProofSignerTests {
    @Test func proofMessage_layoutAndLowercasedAddress() {
        let message = WorkspacesAgentProofSigner.proofMessage(
            workspaceId: "team-1",
            agentAddress: "0xABCdef0123",
            timestamp: 1_717_171_717
        )
        #expect(message == "osaurus-workspaces:share:team-1:0xabcdef0123:1717171717")
    }

    @Test func signProof_recoversToDerivedAgentKey() throws {
        let agentIndex: UInt32 = 7
        var childKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: agentIndex)
        defer { childKey.zeroOut() }
        let agentAddress = try OsaurusRouterAuthSigner.evmAddress(privateKey: childKey)

        let timestamp = 1_717_171_717
        let proof = try WorkspacesAgentProofSigner.signProof(
            workspaceId: "team-1",
            agentAddress: agentAddress,
            timestamp: timestamp,
            masterKey: TestKeys.alicePrivateKey,
            agentIndex: agentIndex
        )
        #expect(proof.timestamp == timestamp)
        #expect(proof.signature.hasPrefix("0x"))

        // The router verifies exactly this: ecrecover(message) == agent key,
        // proving control of the AGENT key (not the master key).
        let message = WorkspacesAgentProofSigner.proofMessage(
            workspaceId: "team-1", agentAddress: agentAddress, timestamp: timestamp
        )
        let signature = try #require(Data(hexEncoded: String(proof.signature.dropFirst(2))))
        let recovered = try recoverAddress(
            payload: Data(message.utf8),
            signature: signature,
            domainPrefix: "Ethereum Signed Message"
        )
        #expect(recovered.lowercased() == agentAddress.lowercased())
    }

    @Test func signProof_differentAgentIndexYieldsDifferentSigner() throws {
        var childKey = AgentKey.derive(masterKey: TestKeys.alicePrivateKey, index: 1)
        defer { childKey.zeroOut() }
        let addressOfIndex1 = try OsaurusRouterAuthSigner.evmAddress(privateKey: childKey)

        // Signed with index 2, so the recovered signer must NOT be index 1's
        // address (INVALID_AGENT_PROOF server-side).
        let proof = try WorkspacesAgentProofSigner.signProof(
            workspaceId: "team-1",
            agentAddress: addressOfIndex1,
            timestamp: 1_717_171_717,
            masterKey: TestKeys.alicePrivateKey,
            agentIndex: 2
        )
        let message = WorkspacesAgentProofSigner.proofMessage(
            workspaceId: "team-1", agentAddress: addressOfIndex1, timestamp: 1_717_171_717
        )
        let signature = try #require(Data(hexEncoded: String(proof.signature.dropFirst(2))))
        let recovered = try recoverAddress(
            payload: Data(message.utf8),
            signature: signature,
            domainPrefix: "Ethereum Signed Message"
        )
        #expect(recovered.lowercased() != addressOfIndex1.lowercased())
    }
}

// MARK: - Service

@Suite("Workspaces service", .serialized)
@MainActor
struct WorkspacesServiceTests {
    @Test func workspaceErrorCodesMapToFriendlyCopy() {
        func message(_ code: String) -> String {
            WorkspacesService.message(
                for: .server(code: code, message: "raw server text", status: 409)
            )
        }
        #expect(message("WORKSPACE_SEATS_EXHAUSTED").contains("full"))
        #expect(message("SUBSCRIPTION_INACTIVE").contains("isn't active"))
        #expect(message("INVALID_AGENT_PROOF").contains("proof"))
        #expect(message("INVITE_EXPIRED").contains("expired"))
        #expect(message("WORKSPACE_INSUFFICIENT_FUNDS").contains("out of credits"))
        // Activation verdicts (doc copy table) point back at the purchase.
        #expect(message("ACTIVATION_CODE_INVALID").contains("isn't valid"))
        #expect(message("ACTIVATION_CODE_USED").contains("already activated"))
        #expect(message("ACTIVATION_CODE_EXPIRED").contains("expired"))
        #expect(message("ACTIVATION_CONFLICT").contains("already has a workspace subscription"))
        // Invite-link verdicts point back at the teammate.
        #expect(message("INVITE_INVALID").contains("isn't valid"))
        #expect(message("INVITE_USED").contains("already been used"))
        // The trial cap says what it is and when it lifts — no tier names.
        #expect(message("TRIAL_WORKSPACE_LIMIT").contains("free trial covers one workspace"))
        #expect(!message("TRIAL_WORKSPACE_LIMIT").contains("Business"))
        // Gone with tiers: an unknown code falls through to the server text.
        #expect(message("FREE_WORKSPACE_LIMIT") == "raw server text")
        #expect(!message("SUBSCRIPTION_INACTIVE").contains("Business"))
        // INVALID_STATE is a plain server message.
        #expect(message("INVALID_STATE") == "raw server text")
        // Dino ID is no longer a Workspaces concept.
        #expect(!message("DINO_ID_REQUIRED").contains("Dino"))
        // Non-workspace server errors surface the server's own message.
        #expect(message("NOT_FOUND") == "raw server text")
    }

    @Test func isSelf_matchesLastSignedWalletCaseInsensitively() {
        let service = WorkspacesService()
        OsaurusRouterWalletCache.reset(to: "0xAbC1234567890abcdef1234567890ABCDEF12345")
        defer { OsaurusRouterWalletCache.reset() }

        let me = OsaurusRouterWorkspacePerson(
            accountId: "acct-1",
            walletAddress: "0xabc1234567890ABCDEF1234567890abcdef12345",
            displayName: nil
        )
        let other = OsaurusRouterWorkspacePerson(
            accountId: "acct-2", walletAddress: "0x0000000000000000000000000000000000000002",
            displayName: nil
        )
        #expect(service.isSelf(me))
        #expect(!service.isSelf(other))
        #expect(!service.isSelf(nil))
        #expect(!service.isSelf(walletAddress: ""))

        // Unknown until the first signed call lands — never a false positive.
        OsaurusRouterWalletCache.reset()
        #expect(!service.isSelf(me))
    }

    @Test func activate_rejectsBlankNameAndBadCodeWithoutNetworkCall() async throws {
        try await withService(handler: { _ in
            Issue.record("No request should be issued for invalid local input")
            throw URLError(.badURL)
        }) { service, _ in
            #expect(await service.activate(code: "act_9f8e7d6c", name: "   ") == nil)
            #expect(service.lastError?.contains("1–80") == true)
            service.lastError = nil

            #expect(await service.activate(code: "abc", name: "Dino Devs") == nil)
            #expect(service.lastError?.contains("activation code") == true)
        }
    }

    @Test func activate_createsWorkspaceClearsPendingAndSelectsIt() async throws {
        let detailBody =
            #"{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"},"members_active":1,"agents_shared":0,"balance_micro":"20000000","pool_frozen":false}"#
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/activate"):
                #expect(bodyString(request) == #"{"code":"act_9f8e7d6c","name":"Dino Devs"}"#)
                return json(detailBody, status: 201)
            case ("GET", "/workspaces"):
                return json(
                    #"{"data":[{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","active":true,"members_active":1,"agents_shared":0}]}"#
                )
            case ("GET", "/workspaces/billing"):
                return json(
                    #"{"subscription":{"status":"active","quantity":1,"price":null,"cancel_at_period_end":false,"trialing":false},"workspaces":1,"billed_workspaces":1,"trial_eligible":false,"trial_days":14}"#
                )
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            case ("GET", "/workspaces/team-1"):
                return json(detailBody)
            case ("GET", "/workspaces/team-1/members"),
                ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            service.pendingActivation = PendingWorkspaceActivation(
                code: "act_9f8e7d6c", suggestedName: "Dino Devs", planLabel: "Workspace S"
            )
            let detail = await service.activate(code: "act_9f8e7d6c", name: " Dino Devs ")
            #expect(detail?.id == "team-1")
            #expect(detail?.typedSource == .subscription)
            #expect(service.lastError == nil)
            #expect(service.pendingActivation == nil)
            #expect(service.workspaces.map(\.id) == ["team-1"])
            #expect(service.selectedWorkspaceId == "team-1")
            // The list refresh also picks up the account billing summary + prices.
            #expect(service.billing?.subscription?.isActive == true)
            #expect(service.hasLiveSubscription)
            #expect(!service.isTrialing)
            #expect(service.prices?.monthly?.id == "price_month")
            #expect(service.trialDays == 14)
        }
    }

    @Test func createWorkspace_rejectsBlankNameWithoutNetworkCall() async throws {
        try await withService(handler: { _ in
            Issue.record("No request should be issued for invalid local input")
            throw URLError(.badURL)
        }) { service, _ in
            #expect(await service.createWorkspace(name: "   ") == nil)
            #expect(service.lastError?.contains("1–80") == true)
            #expect(await service.createWorkspace(name: String(repeating: "x", count: 81)) == nil)
        }
    }

    /// Live subscription: `201 created` lands on the new workspace right away
    /// and no browser is opened.
    @Test func createWorkspace_onLiveSubscriptionCreatesSelectsAndRefreshesBilling() async throws {
        let detailBody =
            #"{"id":"team-2","name":"Second Squad","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription","seats":null,"max_shared_agents":null,"monthly_credit_micro":"20000000"},"members_active":1,"agents_shared":0,"balance_micro":"20000000","pool_frozen":false}"#
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces"):
                #expect(bodyString(request) == #"{"name":"Second Squad"}"#)
                return json(#"{"status":"created","workspace":\#(detailBody)}"#, status: 201)
            case ("GET", "/workspaces"):
                return json(
                    #"{"data":[{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","active":true},{"id":"team-2","name":"Second Squad","role":"owner","source":"subscription","active":true,"members_active":1,"agents_shared":0}]}"#
                )
            case ("GET", "/workspaces/billing"):
                return json(
                    #"{"subscription":{"status":"active","quantity":2,"price":{"id":"price_month","billing_interval":"month","price_usd_micro":"20000000","price_usd":"20.00","active":true},"cancel_at_period_end":false,"trialing":false},"workspaces":2,"billed_workspaces":2,"trial_eligible":false,"trial_days":14}"#
                )
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            case ("GET", "/workspaces/team-2"):
                return json(detailBody)
            case ("GET", "/workspaces/team-2/members"),
                ("GET", "/workspaces/team-2/invites"),
                ("GET", "/workspaces/team-2/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            let outcome = await service.createWorkspace(name: " Second Squad ")
            guard case .ready(let detail)? = outcome else {
                Issue.record("expected .ready, got \(String(describing: outcome))")
                return
            }
            #expect(detail.id == "team-2")
            #expect(detail.isActive)
            #expect(opened == nil)
            #expect(service.pendingConfirmation == nil)
            #expect(service.lastError == nil)
            #expect(service.lastErrorCode == nil)
            #expect(service.workspaces.map(\.id) == ["team-1", "team-2"])
            #expect(service.selectedWorkspaceId == "team-2")
            #expect(service.detail?.isActive == true)
            #expect(service.billing?.billedWorkspaces == 2)
            #expect(!service.isBusy("workspace.create"))
        }
    }

    /// No live subscription: the router hands back a Checkout; the service
    /// opens it, remembers what it is waiting for, and the next app
    /// activation finds the webhook-created workspace in the list and lands
    /// on it.
    @Test func createWorkspace_checkoutRequiredOpensBrowserThenPollLandsOnNewWorkspace() async throws {
        let listCalls = Counter()
        let newDetail =
            #"{"id":"team-9","name":"Dino Devs","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"},"members_active":1,"agents_shared":0,"balance_micro":"20000000","pool_frozen":false}"#
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces"):
                #expect(bodyString(request) == #"{"name":"Dino Devs","price_id":"price_year"}"#)
                return json(
                    #"{"status":"checkout_required","activation_id":"act_1","checkout_url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#
                )
            case ("GET", "/workspaces"):
                // 1: seed. 2: first poll — webhook hasn't landed (only the
                // member-role row we already knew). 3+: the new owner-role
                // row appears.
                let n = listCalls.increment()
                if n <= 2 {
                    return json(#"{"data":[{"id":"team-2","name":"Other","role":"member","source":"subscription","active":true}]}"#)
                }
                return json(
                    #"{"data":[{"id":"team-2","name":"Other","role":"member","source":"subscription","active":true},{"id":"team-9","name":"Dino Devs","role":"owner","source":"subscription","active":true,"members_active":1,"agents_shared":0}]}"#
                )
            case ("GET", "/workspaces/billing"):
                return json(
                    #"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#
                )
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            case ("GET", "/workspaces/team-9"):
                return json(newDetail)
            case ("GET", "/workspaces/team-9/members"),
                ("GET", "/workspaces/team-9/invites"),
                ("GET", "/workspaces/team-9/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            // Seed the known list (a workspace we're a member of).
            await service.refreshWorkspaces()
            #expect(service.workspaces.map(\.id) == ["team-2"])
            #expect(service.trialEligible)

            let outcome = await service.createWorkspace(name: "Dino Devs", priceId: "price_year")
            guard case .checkoutOpened(let activationId)? = outcome else {
                Issue.record("expected .checkoutOpened, got \(String(describing: outcome))")
                return
            }
            #expect(activationId == "act_1")
            #expect(opened?.host == "checkout.stripe.com")
            #expect(service.awaitingSubscriptionConfirmation)
            guard case .checkout(let pendingActivation, let name, let knownIds)? = service.pendingConfirmation else {
                Issue.record("expected .checkout pending confirmation")
                return
            }
            #expect(pendingActivation == "act_1")
            #expect(name == "Dino Devs")
            #expect(knownIds == ["team-2"])
            // Nothing was created yet: no selection, no audit-side effects.
            #expect(service.selectedWorkspaceId == nil)
            #expect(service.lastError == nil)

            // Return-to-app: webhook not there yet → keep waiting.
            await service.handleAppActivation()
            #expect(service.awaitingSubscriptionConfirmation)
            #expect(service.selectedWorkspaceId == nil)

            // Return-to-app again: the owner-role row is new → land on it.
            await service.handleAppActivation()
            #expect(!service.awaitingSubscriptionConfirmation)
            #expect(service.pendingConfirmation == nil)
            #expect(service.workspaces.map(\.id) == ["team-2", "team-9"])
            #expect(service.selectedWorkspaceId == "team-9")
            #expect(service.detail?.id == "team-9")
            #expect(service.detail?.isActive == true)
        }
    }

    /// A checkout the user never finishes must not wait forever: the pending
    /// confirmation self-clears after a bounded number of fruitless polls, and
    /// an explicit dismiss clears it immediately.
    @Test func createWorkspace_checkoutWaitSelfLimitsAndCanBeDismissed() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces"):
                return json(
                    #"{"status":"checkout_required","activation_id":"act_1","checkout_url":"https://checkout.stripe.com/c/pay/cs_test_1"}"#
                )
            case ("GET", "/workspaces"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/billing"):
                return json(#"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#)
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            service.openURL = { _ in }
            _ = await service.createWorkspace(name: "Dino Devs")
            #expect(service.awaitingSubscriptionConfirmation)
            for _ in 0..<9 {
                await service.handleAppActivation()
                #expect(service.awaitingSubscriptionConfirmation)
            }
            await service.handleAppActivation()
            #expect(!service.awaitingSubscriptionConfirmation)

            _ = await service.createWorkspace(name: "Dino Devs")
            #expect(service.awaitingSubscriptionConfirmation)
            service.dismissSubscriptionWait()
            #expect(!service.awaitingSubscriptionConfirmation)
            // Navigating between workspaces does NOT drop a new-workspace
            // checkout wait (it's account-level, not tied to a selection).
            _ = await service.createWorkspace(name: "Dino Devs")
            service.clearSelection()
            #expect(service.awaitingSubscriptionConfirmation)
        }
    }

    /// `TRIAL_WORKSPACE_LIMIT`: exposed as a code (the sheet renders the
    /// trial's end date from the refreshed billing summary), copy has no tier
    /// names, and nothing is opened.
    @Test func createWorkspace_trialLimitExposesCodeAndRefreshesBilling() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces"):
                return (
                    409,
                    Data(
                        #"{"error":{"code":"TRIAL_WORKSPACE_LIMIT","message":"your trial covers one workspace","trial_ends_at":"2026-09-22T00:00:00.000Z"}}"#
                            .utf8
                    ),
                    ["content-type": "application/json"]
                )
            case ("GET", "/workspaces/billing"):
                return json(
                    #"{"subscription":{"status":"active","quantity":1,"price":null,"cancel_at_period_end":false,"trial_ends_at":"2026-09-22T00:00:00.000Z","trialing":true},"workspaces":1,"billed_workspaces":1,"trial_eligible":false,"trial_days":14}"#
                )
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            let outcome = await service.createWorkspace(name: "Second")
            #expect(outcome == nil)
            #expect(opened == nil)
            #expect(service.lastErrorCode == .trialWorkspaceLimit)
            #expect(service.lastError?.contains("free trial covers one workspace") == true)
            #expect(service.lastError?.contains("Business") == false)
            #expect(service.pendingConfirmation == nil)
            // Billing was refreshed so the sheet can show the date.
            #expect(service.isTrialing)
            #expect(service.trialEndsAt == "2026-09-22T00:00:00.000Z")
            #expect(!service.isBusy("workspace.create"))
        }
    }

    /// A malformed create envelope (unknown status / missing companions) is a
    /// typed invalid-response error, not a half-applied state.
    @Test func createWorkspace_rejectsInconsistentEnvelope() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces"):
                return json(#"{"status":"checkout_required","activation_id":"act_1"}"#)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            #expect(await service.createWorkspace(name: "Dino Devs") == nil)
            #expect(opened == nil)
            #expect(service.pendingConfirmation == nil)
            #expect(service.lastError != nil)
            #expect(service.lastErrorCode == nil)
        }
    }

    /// Owner reactivates a suspended workspace on a live subscription:
    /// `200 upgraded` refreshes the detail in place.
    @Test func reactivateWorkspace_upgradedRefreshesDetailInPlace() async throws {
        let suspended =
            #"{"id":"team-3","name":"Lapsed","role":"owner","source":"suspended","entitlement":{"active":false,"source":"suspended"},"balance_micro":"0","pool_frozen":true}"#
        let live =
            #"{"id":"team-3","name":"Lapsed","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription","next_grant_at":"2026-10-01T00:00:00.000Z"},"balance_micro":"20000000","pool_frozen":false}"#
        let upgraded = Flag()
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/team-3/upgrade"):
                #expect(bodyString(request) == "{}")
                upgraded.set()
                return json(#"{"status":"upgraded","workspace":\#(live)}"#)
            case ("GET", "/workspaces"):
                let row = upgraded.isSet ? #""source":"subscription","active":true"# : #""source":"suspended","active":false"#
                return json(#"{"data":[{"id":"team-3","name":"Lapsed","role":"owner",\#(row)}]}"#)
            case ("GET", "/workspaces/billing"):
                return json(
                    #"{"subscription":{"status":"active","quantity":1,"price":null,"cancel_at_period_end":false,"trialing":false},"workspaces":1,"billed_workspaces":1,"trial_eligible":false,"trial_days":14}"#
                )
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            case ("GET", "/workspaces/team-3"):
                return json(upgraded.isSet ? live : suspended)
            case ("GET", "/workspaces/team-3/members"),
                ("GET", "/workspaces/team-3/invites"),
                ("GET", "/workspaces/team-3/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            await service.refreshWorkspaces()
            await service.selectWorkspace(id: "team-3")
            #expect(service.detail?.isSuspended == true)
            #expect(service.detail?.isActive == false)

            let outcome = await service.reactivateWorkspace(id: "team-3")
            guard case .ready(let detail)? = outcome else {
                Issue.record("expected .ready, got \(String(describing: outcome))")
                return
            }
            #expect(detail.isActive)
            #expect(opened == nil)
            #expect(service.pendingConfirmation == nil)
            #expect(service.selectedWorkspaceId == "team-3")
            #expect(service.detail?.isActive == true)
            #expect(service.detail?.typedSource == .subscription)
            #expect(service.workspaces.first?.isActive == true)
            #expect(!service.isBusy("workspace.reactivate"))
        }
    }

    /// Owner without a live subscription: reactivation goes through Checkout;
    /// app activation polls that workspace's detail until it is active.
    @Test func reactivateWorkspace_checkoutRequiredPollsDetailUntilActive() async throws {
        let detailCalls = Counter()
        let suspended =
            #"{"id":"team-3","name":"Lapsed","role":"owner","source":"suspended","entitlement":{"active":false,"source":"suspended"},"balance_micro":"0"}"#
        let live =
            #"{"id":"team-3","name":"Lapsed","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"},"balance_micro":"20000000"}"#
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/team-3/upgrade"):
                #expect(bodyString(request) == #"{"price_id":"price_month"}"#)
                return json(
                    #"{"status":"checkout_required","activation_id":"act_7","checkout_url":"https://checkout.stripe.com/c/pay/cs_test_7"}"#
                )
            case ("GET", "/workspaces"):
                return json(#"{"data":[{"id":"team-3","name":"Lapsed","role":"owner","source":"suspended","active":false}]}"#)
            case ("GET", "/workspaces/billing"):
                return json(
                    #"{"subscription":{"status":"canceled","quantity":0,"price":null,"trialing":false},"workspaces":1,"billed_workspaces":0,"trial_eligible":false,"trial_days":14}"#
                )
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            case ("GET", "/workspaces/team-3"):
                // Initial select + first poll: still suspended; then live.
                return json(detailCalls.increment() <= 2 ? suspended : live)
            case ("GET", "/workspaces/team-3/members"),
                ("GET", "/workspaces/team-3/invites"),
                ("GET", "/workspaces/team-3/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            await service.refreshWorkspaces()
            await service.selectWorkspace(id: "team-3")
            #expect(!service.hasLiveSubscription)

            let outcome = await service.reactivateWorkspace(id: "team-3", priceId: "price_month")
            guard case .checkoutOpened(let activationId)? = outcome else {
                Issue.record("expected .checkoutOpened, got \(String(describing: outcome))")
                return
            }
            #expect(activationId == "act_7")
            #expect(opened?.host == "checkout.stripe.com")
            #expect(service.pendingConfirmation == .reactivation(workspaceId: "team-3"))

            await service.handleAppActivation()
            #expect(service.awaitingSubscriptionConfirmation)
            #expect(service.detail?.isActive == false)

            await service.handleAppActivation()
            #expect(!service.awaitingSubscriptionConfirmation)
            #expect(service.detail?.isActive == true)
            #expect(service.selectedWorkspaceId == "team-3")
        }
    }

    // MARK: Pool top-ups and auto-reload

    @Test func selectWorkspace_loadsPoolBalanceSplitAlongsideDetail() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces/team-1"):
                return json(liveDetail(balanceMicro: "30000000"))
            case ("GET", "/workspaces/team-1/credits/balance"):
                return json(
                    #"{"balance_micro":"30000000","expiring_micro":"20000000","purchased_micro":"10000000","auto_reload":{"enabled":true,"paused":true},"frozen":false}"#
                )
            case ("GET", "/workspaces/team-1/members"), ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            default:
                throw URLError(.badURL)
            }
        }) { service, _ in
            await service.selectWorkspace(id: "team-1")
            #expect(service.poolBalance?.purchasedMicro == "10000000")
            #expect(service.poolBalance?.autoReload?.paused == true)
            service.clearSelection()
            #expect(service.poolBalance == nil)
            #expect(service.autoReload == nil)
        }
    }

    @Test func topUpPool_rejectsOutOfBoundsAmountWithoutNetworkCall() async throws {
        try await withService(handler: { _ in
            Issue.record("no request expected")
            throw URLError(.badURL)
        }) { service, _ in
            #expect(await service.topUpPool(workspaceId: "team-1", amountMicro: 4_000_000) == nil)
            #expect(service.lastError?.contains("Minimum") == true)
            #expect(await service.topUpPool(workspaceId: "team-1", amountMicro: 600_000_000) == nil)
            #expect(service.lastError?.contains("Maximum") == true)
            #expect(await service.topUpPool(workspaceId: "team-1", amountMicro: 20_001_000) == nil)
            #expect(service.lastError?.contains("whole cents") == true)
            #expect(service.pendingConfirmation == nil)
        }
    }

    /// Top-up: the router opens a Checkout; nothing is credited by the
    /// redirect. On return the service polls the pool and settles once the
    /// `workspace_topup` ledger entry for that amount (posted after the
    /// Checkout opened) is visible.
    @Test func topUpPool_opensCheckoutThenPollSettlesOnLedgerEntry() async throws {
        let ledgerCalls = Counter()
        let now = ISO8601DateFormatter().string(from: Date())
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces/team-1"):
                return json(liveDetail(balanceMicro: "1000000"))
            case ("GET", "/workspaces/team-1/members"), ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            case ("POST", "/workspaces/team-1/credits/checkout"):
                #expect(bodyString(request) == #"{"amount_micro":"20000000"}"#)
                return json(
                    #"{"topup_id":"tu_1","checkout_url":"https://checkout.stripe.com/c/pay/cs_1","credit_micro":"20000000","credits":"20.00","total_micro":"20000000"}"#
                )
            case ("GET", "/workspaces/team-1/credits/balance"):
                // Balance does not move until the webhook lands (2nd poll).
                return json(
                    ledgerCalls.current >= 1
                        ? #"{"balance_micro":"21000000","expiring_micro":"1000000","purchased_micro":"20000000","frozen":false}"#
                        : #"{"balance_micro":"1000000","expiring_micro":"1000000","purchased_micro":"0","frozen":false}"#
                )
            case ("GET", "/workspaces/team-1/credits/transactions"):
                let n = ledgerCalls.increment()
                // First poll: only an older top-up of the same amount (must
                // not settle); second poll: the fresh entry.
                if n == 1 {
                    return json(
                        #"{"data":[{"id":"l0","amount_micro":"20000000","entry_type":"workspace_topup","created_at":"2020-01-01T00:00:00Z"}],"next_cursor":null}"#
                    )
                }
                return json(
                    #"{"data":[{"id":"l1","amount_micro":"20000000","entry_type":"workspace_topup","created_at":"\#(now)"},{"id":"l0","amount_micro":"20000000","entry_type":"workspace_topup","created_at":"2020-01-01T00:00:00Z"}],"next_cursor":null}"#
                )
            case ("GET", "/workspaces"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/billing"), ("GET", "/workspaces/prices"):
                return json("{}", status: 404)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }
            await service.selectWorkspace(id: "team-1")

            let topupId = await service.topUpPool(workspaceId: "team-1", amountMicro: 20_000_000)
            #expect(topupId == "tu_1")
            #expect(opened?.host == "checkout.stripe.com")
            guard case .topUp("team-1", "tu_1", 20_000_000, 1_000_000, _)? = service.pendingConfirmation else {
                Issue.record("expected .topUp pending, got \(String(describing: service.pendingConfirmation))")
                return
            }

            await service.handleAppActivation()
            #expect(service.awaitingSubscriptionConfirmation)

            await service.handleAppActivation()
            #expect(!service.awaitingSubscriptionConfirmation)
            #expect(service.poolBalance?.purchasedMicro == "20000000")
        }
    }

    @Test func topUpLanded_ledgerEntryMustBeFreshAndBalanceFallbackNeedsFullAmount() throws {
        let started = Date()
        let balance = OsaurusRouterWorkspacePoolBalance(balanceMicro: "21000000")
        func ledger(_ createdAt: String, amount: String = "20000000", type: String = "workspace_topup") -> OsaurusRouterTransactionsResponse? {
            try? JSONDecoder().decode(
                OsaurusRouterTransactionsResponse.self,
                from: Data(#"{"data":[{"id":"l","amount_micro":"\#(amount)","entry_type":"\#(type)","created_at":"\#(createdAt)"}],"next_cursor":null}"#.utf8)
            )
        }
        let fresh = ISO8601DateFormatter().string(from: started.addingTimeInterval(5))
        // Fresh entry of the right amount: landed, whatever the balance did.
        #expect(WorkspacesService.topUpLanded(balance: balance, before: nil, amountMicro: 20_000_000, startedAt: started, ledger: ledger(fresh)))
        // Stale entry (an earlier purchase of the same amount): not this one.
        #expect(!WorkspacesService.topUpLanded(balance: balance, before: nil, amountMicro: 20_000_000, startedAt: started, ledger: ledger("2020-01-01T00:00:00Z")))
        // Wrong amount / wrong type: no.
        #expect(!WorkspacesService.topUpLanded(balance: balance, before: nil, amountMicro: 20_000_000, startedAt: started, ledger: ledger(fresh, amount: "5000000")))
        #expect(!WorkspacesService.topUpLanded(balance: balance, before: nil, amountMicro: 20_000_000, startedAt: started, ledger: ledger(fresh, type: "subscription_grant")))
        // No usable ledger: the balance must have risen by the full amount.
        #expect(WorkspacesService.topUpLanded(balance: balance, before: 1_000_000, amountMicro: 20_000_000, startedAt: started, ledger: nil))
        #expect(!WorkspacesService.topUpLanded(balance: balance, before: 5_000_000, amountMicro: 20_000_000, startedAt: started, ledger: nil))
        #expect(!WorkspacesService.topUpLanded(balance: balance, before: nil, amountMicro: 20_000_000, startedAt: started, ledger: nil))
    }

    @Test func saveAutoReload_rejectsBadConfigLocallyAndSavesValidOne() async throws {
        let puts = Counter()
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces/team-1"):
                return json(liveDetail(balanceMicro: "1000000"))
            case ("GET", "/workspaces/team-1/members"), ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/team-1/credits/balance"):
                return json(
                    puts.current > 0
                        ? #"{"balance_micro":"1000000","auto_reload":{"enabled":true,"paused":false},"frozen":false}"#
                        : #"{"balance_micro":"1000000","auto_reload":{"enabled":false,"paused":false},"frozen":false}"#
                )
            case ("GET", "/workspaces/team-1/credits/auto-reload"):
                return json(
                    #"{"enabled":false,"paused":false,"threshold_micro":null,"amount_micro":null,"monthly_cap_micro":null,"payment_method_on_file":true,"bounds":{"min_threshold_micro":"1000000","max_threshold_micro":"500000000","min_amount_micro":"5000000","max_amount_micro":"500000000"}}"#
                )
            case ("PUT", "/workspaces/team-1/credits/auto-reload"):
                puts.increment()
                #expect(
                    bodyString(request)
                        == #"{"amount_micro":"20000000","enabled":true,"monthly_cap_micro":"200000000","threshold_micro":"5000000"}"#
                )
                return json(
                    #"{"enabled":true,"paused":false,"threshold_micro":"5000000","amount_micro":"20000000","monthly_cap_micro":"200000000","month_reloaded_micro":"0","consecutive_failures":0,"payment_method_on_file":true}"#
                )
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            await service.selectWorkspace(id: "team-1")
            let loaded = await service.loadAutoReload(workspaceId: "team-1")
            #expect(loaded?.enabled == false)
            #expect(service.autoReload?.paymentMethodOnFile == true)

            // Cap below the reload amount never reaches the router.
            let rejected = await service.saveAutoReload(
                workspaceId: "team-1", enabled: true, thresholdMicro: 5_000_000, amountMicro: 20_000_000,
                monthlyCapMicro: 10_000_000
            )
            #expect(rejected == nil)
            #expect(service.lastErrorCode == .invalidAutoReloadConfig)
            #expect(service.lastError?.contains("cap") == true)
            #expect(puts.current == 0)

            let saved = await service.saveAutoReload(
                workspaceId: "team-1", enabled: true, thresholdMicro: 5_000_000, amountMicro: 20_000_000,
                monthlyCapMicro: 200_000_000
            )
            #expect(saved?.enabled == true)
            #expect(service.autoReload?.monthlyCap == 200_000_000)
            #expect(service.lastError == nil)
            // The balance's auto_reload flags follow the save.
            #expect(service.poolBalance?.autoReload?.enabled == true)
        }
    }

    @Test func saveAutoReload_unavailableWithoutCardSurfacesFriendlyCopy() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/workspaces/team-1/credits/auto-reload"):
                return json(#"{"error":{"code":"AUTO_RELOAD_UNAVAILABLE","message":"no saved card"}}"#, status: 409)
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            let saved = await service.saveAutoReload(
                workspaceId: "team-1", enabled: true, thresholdMicro: 5_000_000, amountMicro: 20_000_000,
                monthlyCapMicro: nil
            )
            #expect(saved == nil)
            #expect(service.lastErrorCode == .autoReloadUnavailable)
            #expect(service.lastError?.contains("saved card") == true)
        }
    }

    /// An older router without `/workspaces/billing` or `/workspaces/prices`
    /// must not raise a banner: the list is authoritative and the summaries
    /// just stay nil.
    @Test func refreshBilling_isQuietWhenRoutesAreMissing() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/billing"), ("GET", "/workspaces/prices"):
                return (404, Data(#"{"error":{"code":"NOT_FOUND","message":"not found"}}"#.utf8), ["content-type": "application/json"])
            default:
                Issue.record("Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            await service.refreshWorkspaces()
            #expect(service.lastError == nil)
            #expect(service.billing == nil)
            #expect(service.prices == nil)
            #expect(!service.hasLiveSubscription)
            #expect(!service.trialEligible)
            #expect(service.trialDays == nil)
        }
    }

    @Test func activate_keepsPendingOnServerRejection() async throws {
        try await withService(handler: { _ in
            (
                400,
                Data(
                    #"{"error":{"code":"ACTIVATION_CODE_USED","message":"used"}}"#.utf8
                ),
                ["content-type": "application/json"]
            )
        }) { service, _ in
            let pending = PendingWorkspaceActivation(
                code: "act_9f8e7d6c", suggestedName: nil, planLabel: nil
            )
            service.pendingActivation = pending
            let detail = await service.activate(code: pending.code, name: "Dino Devs")
            #expect(detail == nil)
            #expect(service.lastError?.contains("already activated") == true)
            // The user can retry or discard; we never lose the code for them.
            #expect(service.pendingActivation == pending)
            #expect(!service.isBusy("workspace.activate"))
        }
    }

    @Test func join_addsWorkspaceClearsPendingAndSelectsIt() async throws {
        let code = "7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"
        let detailBody =
            #"{"id":"team-2","name":"Other","role":"member","members_active":2,"agents_shared":0,"balance_micro":"0","pool_frozen":false}"#
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/join"):
                #expect(bodyString(request) == #"{"code":"\#(code)"}"#)
                return json(detailBody)
            case ("GET", "/workspaces"):
                return json(
                    #"{"data":[{"id":"team-2","name":"Other","role":"member","source":"subscription","active":true,"members_active":2,"agents_shared":0}]}"#
                )
            case ("GET", "/workspaces/billing"):
                return json(#"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#)
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            case ("GET", "/workspaces/team-2"):
                return json(detailBody)
            case ("GET", "/workspaces/team-2/members"),
                ("GET", "/workspaces/team-2/invites"),
                ("GET", "/workspaces/team-2/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            service.pendingJoin = PendingWorkspaceJoin(code: code)
            let detail = await service.join(code: " \(code) ")
            #expect(detail?.id == "team-2")
            #expect(service.lastError == nil)
            #expect(service.pendingJoin == nil)
            #expect(service.workspaces.map(\.id) == ["team-2"])
            #expect(service.selectedWorkspaceId == "team-2")
        }
    }

    @Test func join_keepsPendingOnRejectionAndValidatesLocally() async throws {
        let requests = CallCounter()
        try await withService(handler: { _ in
            requests.increment()
            return (
                404,
                Data(#"{"error":{"code":"INVITE_INVALID","message":"nope"}}"#.utf8),
                ["content-type": "application/json"]
            )
        }) { service, _ in
            // Garbage never reaches the network.
            #expect(await service.join(code: "{bad}") == nil)
            #expect(requests.value == 0)
            #expect(service.lastError?.contains("invite code") == true)
            service.lastError = nil

            let pending = PendingWorkspaceJoin(code: "7a2b3c4d.0123456789abcdef")
            service.pendingJoin = pending
            #expect(await service.join(code: pending.code) == nil)
            #expect(requests.value == 1)
            #expect(service.lastError?.contains("isn't valid") == true)
            // Retry or discard is the user's call; the code isn't dropped.
            #expect(service.pendingJoin == pending)
            #expect(!service.isBusy("workspace.join"))
        }
    }

    @Test func mintInvite_returnsLinkAndPrependsToSelectedWorkspaceRows() async throws {
        let inviteBody =
            #"{"id":"inv-9","code":"7a2b3c4d-0000-4000-8000-000000000009.0123456789abcdef0123456789abcdef","url":"osaurus://teams/join?code=7a2b3c4d-0000-4000-8000-000000000009.0123456789abcdef0123456789abcdef","role":"viewer","status":"pending","max_uses":3,"uses":0,"expires_at":"2026-09-14T00:00:00.000Z"}"#
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/team-1/invites"):
                #expect(bodyString(request) == #"{"max_uses":3,"role":"viewer"}"#)
                return json(inviteBody, status: 201)
            case ("GET", "/workspaces/team-1"):
                return json(
                    #"{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"},"members_active":1,"agents_shared":0,"balance_micro":"20000000","pool_frozen":false}"#
                )
            case ("GET", "/workspaces/team-1/members"),
                ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            await service.selectWorkspace(id: "team-1")
            let invite = await service.mintInvite(workspaceId: "team-1", role: .viewer, maxUses: 3)
            #expect(invite?.id == "inv-9")
            #expect(invite?.url?.hasPrefix("osaurus://workspaces/join?code=") == true)
            #expect(service.workspaceInvites.map(\.id) == ["inv-9"])
            #expect(service.lastError == nil)
        }
    }

    @Test func mintInvite_seatsExhaustedSurfacesFriendlyError() async throws {
        try await withService(handler: { _ in
            (
                409,
                Data(
                    #"{"error":{"code":"WORKSPACE_SEATS_EXHAUSTED","message":"seat limit reached"}}"#
                        .utf8
                ),
                ["content-type": "application/json"]
            )
        }) { service, _ in
            let invite = await service.mintInvite(workspaceId: "team-1", role: .member)
            #expect(invite == nil)
            #expect(service.lastError?.contains("full") == true)
            #expect(service.lastErrorCode == .seatsExhausted)
        }
    }

    @Test func billingPreference_roundTripsThroughDefaults() throws {
        let suite = "teams-billing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let agentId = UUID()
        #expect(WorkspacesService.workspaceContext(forAgentId: agentId, defaults: defaults) == nil)

        WorkspacesService.setBillingWorkspace(
            agentId: agentId,
            agentAddress: "0xABCdef",
            workspaceId: "team-1",
            defaults: defaults
        )
        let context = try #require(
            WorkspacesService.workspaceContext(forAgentId: agentId, defaults: defaults)
        )
        #expect(context.workspaceId == "team-1")
        // Stored lowercased so it matches the proof/server convention.
        #expect(context.agentAddress == "0xabcdef")

        // Other agents are unaffected.
        #expect(WorkspacesService.workspaceContext(forAgentId: UUID(), defaults: defaults) == nil)

        // Clearing removes the entry entirely.
        WorkspacesService.setBillingWorkspace(
            agentId: agentId, agentAddress: "0xABCdef", workspaceId: nil, defaults: defaults
        )
        #expect(WorkspacesService.workspaceContext(forAgentId: agentId, defaults: defaults) == nil)
    }

    @Test func refreshTeams_reconcilesBillingPrefsAgainstWorkspaceList() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces"):
                return json(
                    #"{"data":[{"id":"team-1","name":"Kept","role":"member","source":"subscription","active":true,"members_active":2,"agents_shared":0,"created_at":"2026-08-31T00:00:00.000Z"}]}"#
                )
            case ("GET", "/workspaces/billing"):
                return json(#"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#)
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, defaults in
            let keptAgent = UUID()
            let staleAgent = UUID()
            WorkspacesService.setBillingWorkspace(
                agentId: keptAgent, agentAddress: "0xaaa", workspaceId: "team-1",
                defaults: defaults
            )
            // workspace-2 no longer appears in the authoritative list (left /
            // removed / deleted) — its pref must not survive the refresh.
            WorkspacesService.setBillingWorkspace(
                agentId: staleAgent, agentAddress: "0xbbb", workspaceId: "team-2",
                defaults: defaults
            )

            await service.refreshWorkspaces()

            #expect(
                WorkspacesService.workspaceContext(forAgentId: keptAgent, defaults: defaults)?.workspaceId
                    == "team-1"
            )
            #expect(WorkspacesService.workspaceContext(forAgentId: staleAgent, defaults: defaults) == nil)
        }
    }

    @Test func refreshSelectedTeam_dropsPrefsForUnsharedAgents() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces/team-1"):
                return json(
                    #"{"id":"team-1","name":"Dino Devs","role":"member","members_active":2,"agents_shared":1,"created_at":"2026-08-31T00:00:00.000Z"}"#
                )
            case ("GET", "/workspaces/team-1/members"), ("GET", "/workspaces/team-1/invites"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/team-1/agents"):
                // Authoritative roster: only 0xaaa is still shared.
                return json(
                    #"{"data":[{"agent_address":"0xAAA","display_name":"Kept","owner":{"account_id":"acct-1","wallet_address":"0xAbC1","display_name":""},"relay_url":"wss://relay.test","online":true,"shared_at":"2026-08-31T00:00:00.000Z"}]}"#
                )
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, defaults in
            let keptAgent = UUID()
            let revokedAgent = UUID()
            let otherWorkspaceAgent = UUID()
            WorkspacesService.setBillingWorkspace(
                agentId: keptAgent, agentAddress: "0xAAA", workspaceId: "team-1",
                defaults: defaults
            )
            // Admin-unshared (or viewer-demotion auto-revoked): gone from the
            // roster, so its pref must drop.
            WorkspacesService.setBillingWorkspace(
                agentId: revokedAgent, agentAddress: "0xBBB", workspaceId: "team-1",
                defaults: defaults
            )
            // Different workspace: this refresh must not touch it.
            WorkspacesService.setBillingWorkspace(
                agentId: otherWorkspaceAgent, agentAddress: "0xccc", workspaceId: "team-9",
                defaults: defaults
            )

            await service.selectWorkspace(id: "team-1")

            #expect(
                WorkspacesService.workspaceContext(forAgentId: keptAgent, defaults: defaults) != nil
            )
            #expect(
                WorkspacesService.workspaceContext(forAgentId: revokedAgent, defaults: defaults) == nil
            )
            #expect(
                WorkspacesService.workspaceContext(forAgentId: otherWorkspaceAgent, defaults: defaults)?
                    .workspaceId == "team-9"
            )
        }
    }

    @Test func portalSpinner_clearsAfterBoundedPollsAndOnDismiss() async throws {
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/billing/portal"):
                // Account-level; the per-workspace route is gone.
                return json(#"{"portal_url":"https://billing.stripe.com/p/session_1"}"#)
            case ("GET", "/workspaces/team-1"):
                // Webhook never lands: nothing was changed in the portal.
                return json(pastDueDetailBody)
            case ("GET", "/workspaces/team-1/members"), ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/billing"):
                return json(#"{"subscription":{"status":"past_due","quantity":1},"workspaces":1,"billed_workspaces":1,"trial_eligible":false,"trial_days":14}"#)
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            var opened: URL?
            service.openURL = { opened = $0 }  // never open a real browser in tests
            await service.selectWorkspace(id: "team-1")
            #expect(service.detail?.isActive == false)

            #expect(await service.openBillingPortal())
            #expect(opened?.host == "billing.stripe.com")
            #expect(service.awaitingSubscriptionConfirmation)

            // Bounded polling: fruitless activation polls eventually clear
            // the wait state instead of spinning forever.
            for _ in 0..<10 {
                await service.handleAppActivation()
            }
            #expect(!service.awaitingSubscriptionConfirmation)

            // Explicit dismiss clears it immediately.
            #expect(await service.openBillingPortal())
            #expect(service.awaitingSubscriptionConfirmation)
            service.dismissSubscriptionWait()
            #expect(!service.awaitingSubscriptionConfirmation)
        }
    }

    /// The webhook lands mid-poll: the entitlement flips active, the wait
    /// clears, and both the detail and the list are refreshed.
    @Test func portalSpinner_clearsWhenEntitlementBecomesActive() async throws {
        let detailCalls = CallCounter()
        let listCalls = CallCounter()
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/workspaces/billing/portal"):
                return json(#"{"portal_url":"https://billing.stripe.com/p/session_1"}"#)
            case ("GET", "/workspaces/team-1"):
                detailCalls.increment()
                // 1: initial select (inactive). 2: first poll (still inactive).
                // 3+: webhook applied → active.
                if detailCalls.value <= 2 {
                    return json(pastDueDetailBody)
                }
                return json(
                    #"{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription"}}"#
                )
            case ("GET", "/workspaces/team-1/members"), ("GET", "/workspaces/team-1/invites"),
                ("GET", "/workspaces/team-1/agents"):
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces"):
                listCalls.increment()
                return json(
                    #"{"data":[{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","active":true}]}"#
                )
            case ("GET", "/workspaces/billing"):
                return json(#"{"subscription":{"status":"active","quantity":1},"workspaces":1,"billed_workspaces":1,"trial_eligible":false,"trial_days":14}"#)
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            // Selecting a workspace also reads the pool split (best-effort).
            case ("GET", let path?) where path.hasSuffix("/credits/balance"):
                return json(#"{"balance_micro":"0","frozen":false}"#)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            service.openURL = { _ in }
            // Recent root refresh so the throttled list poll doesn't muddy the count.
            service.lastRootRefresh = Date()
            await service.selectWorkspace(id: "team-1")
            #expect(await service.openBillingPortal())
            #expect(service.awaitingSubscriptionConfirmation)

            await service.handleAppActivation()  // still past due
            #expect(service.awaitingSubscriptionConfirmation)
            #expect(listCalls.value == 0)

            await service.handleAppActivation()  // webhook landed
            #expect(!service.awaitingSubscriptionConfirmation)
            #expect(service.detail?.isActive == true)
            #expect(service.detail?.typedSource == .subscription)
            // Success path refreshes the list (and with it the billing summary).
            #expect(listCalls.value == 1)
            #expect(service.billing?.subscription?.isActive == true)
        }
    }

    @Test func activationRootRefresh_isThrottled() async throws {
        let workspacesCalls = CallCounter()
        try await withService(handler: { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/workspaces"):
                workspacesCalls.increment()
                return json(#"{"data":[]}"#)
            case ("GET", "/workspaces/billing"):
                return json(#"{"subscription":null,"workspaces":0,"billed_workspaces":0,"trial_eligible":true,"trial_days":14}"#)
            case ("GET", "/workspaces/prices"):
                return json(pricesBody)
            default:
                Issue.record(
                    "Unexpected \(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
                )
                throw URLError(.badURL)
            }
        }) { service, _ in
            await service.refreshWorkspaces()
            #expect(workspacesCalls.value == 1)

            // Within the 60s window: activation must not refetch.
            await service.handleAppActivation()
            #expect(workspacesCalls.value == 1)

            // Backdate the last refresh past the interval: activation polls.
            service.lastRootRefresh = Date(timeIntervalSinceNow: -120)
            await service.handleAppActivation()
            #expect(workspacesCalls.value == 2)
        }
    }

    /// The composer chip in a team-agent chat reads `poolBalances` for a
    /// workspace that is not selected in Settings, so the per-workspace read
    /// must work without a selection, dedupe bursts, and refresh after a
    /// workspace-billed step.
    @Test func poolBalances_readableWithoutSelectionAndRefreshedOnBilling() async throws {
        let balanceCalls = Counter()
        try await withService(handler: { request in
            switch request.url?.path {
            case "/workspaces/team-1/credits/balance":
                let n = balanceCalls.increment()
                let micro = n == 1 ? "200000000" : "199990000"
                return json(#"{"balance_micro":"\#(micro)","frozen":false}"#)
            default:
                Issue.record("Unexpected path \(request.url?.path ?? "?")")
                throw URLError(.badURL)
            }
        }) { service, _ in
            #expect(service.selectedWorkspaceId == nil)
            #expect(service.poolBalances["team-1"] == nil)

            let first = await service.refreshPoolBalance(workspaceId: "team-1")
            #expect(first?.balanceMicro == "200000000")
            #expect(service.poolBalances["team-1"]?.balanceMicro == "200000000")
            // Selection-scoped state stays untouched.
            #expect(service.poolBalance == nil)

            // A second ask inside the rate-limit window is served from cache.
            let second = await service.refreshPoolBalance(workspaceId: "team-1")
            #expect(second?.balanceMicro == "200000000")
            #expect(balanceCalls.current == 1)

            // A workspace-billed step forces a fresh read even when the
            // workspace isn't selected; bursts coalesce into one request.
            service.noteWorkspaceBilled(workspaceId: "team-1")
            service.noteWorkspaceBilled(workspaceId: "team-1")
            service.noteWorkspaceBilled(workspaceId: "team-1")
            for _ in 0..<40 where balanceCalls.current < 2 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(balanceCalls.current == 2)
            #expect(service.poolBalances["team-1"]?.balanceMicro == "199990000")
        }
    }

    // MARK: helpers

    private func withService(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data, [String: String]),
        _ body: @MainActor (WorkspacesService, UserDefaults) async throws -> Void
    ) async rethrows {
        WorkspacesServiceURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspacesServiceURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OsaurusRouterAPIClient(
            baseURL: URL(string: "https://router.test")!,
            session: session,
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
            }
        )

        let suite = "teams-service-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = WorkspacesService(client: client, defaults: defaults)
        try await body(service, defaults)
    }
}

// MARK: - Workspace-billed inference

@Suite("Workspace billed inference", .serialized)
struct WorkspaceBilledInferenceTests {
    @Test func remoteChatRequest_encodesWorkspaceContextOnlyWhenSet() throws {
        var request = RemoteChatRequest(
            model: "osaurus/minimax-m3",
            messages: [ChatMessage(role: "user", content: "hi")],
            temperature: nil,
            max_completion_tokens: nil,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        )

        let withoutData = try JSONEncoder().encode(request)
        let withoutPayload =
            try JSONSerialization.jsonObject(with: withoutData) as? [String: Any]
        #expect(withoutPayload?["workspace_context"] == nil)

        request.workspaceContext = OsaurusRouterWorkspaceContext(
            workspaceId: "team-1", agentAddress: "0xabc123"
        )
        let withData = try JSONEncoder().encode(request)
        let payload = try JSONSerialization.jsonObject(with: withData) as? [String: Any]
        let workspaceContext = payload?["workspace_context"] as? [String: Any]
        #expect(workspaceContext?["workspace_id"] as? String == "team-1")
        #expect(workspaceContext?["agent_address"] as? String == "0xabc123")
        // Only the current wire name goes out — never both.
        #expect(workspaceContext?["team_id"] == nil)
        #expect(payload?["team_context"] == nil)
    }

    @Test func workspaceContext_decodesLegacyTeamIdButEncodesWorkspaceId() throws {
        let legacy = try JSONDecoder().decode(
            OsaurusRouterWorkspaceContext.self,
            from: Data(#"{"team_id":"team-1","agent_address":"0xabc"}"#.utf8)
        )
        #expect(legacy.workspaceId == "team-1")

        let current = try JSONDecoder().decode(
            OsaurusRouterWorkspaceContext.self,
            from: Data(#"{"workspace_id":"ws-2","team_id":"stale","agent_address":"0xabc"}"#.utf8)
        )
        #expect(current.workspaceId == "ws-2", "workspace_id wins when both are present")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        #expect(encoded?["workspace_id"] as? String == "team-1")
        #expect(encoded?["team_id"] == nil)
    }

    /// Billing preferences written before the rename are keyed `team_id`;
    /// they must keep resolving, and a rewrite lands on `workspace_id`.
    @Test func billingPreference_readsLegacyTeamIdKey() {
        let suiteName = "WorkspacesBillingLegacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let agentId = UUID()
        defaults.set(
            [agentId.uuidString: ["team_id": "team-old", "agent_address": "0xabc"]],
            forKey: WorkspacesService.agentBillingDefaultsKey
        )
        let context = WorkspacesService.workspaceContext(forAgentId: agentId, defaults: defaults)
        #expect(context?.workspaceId == "team-old")

        WorkspacesService.setBillingWorkspace(
            agentId: agentId, agentAddress: "0xabc", workspaceId: "ws-new", defaults: defaults
        )
        let map = defaults.dictionary(forKey: WorkspacesService.agentBillingDefaultsKey) as? [String: [String: String]]
        #expect(map?[agentId.uuidString]?["workspace_id"] == "ws-new")
        #expect(map?[agentId.uuidString]?["team_id"] == nil)
    }

    @Test func buildChatRequest_injectsWorkspaceContextForRouterAgentOnly() async throws {
        // The billing preference lives in standard defaults (the inference
        // path reads them); a unique agent UUID keys the entry so parallel
        // suites can't collide, and the entry is removed on exit.
        let agentId = UUID()
        WorkspacesService.setBillingWorkspace(
            agentId: agentId, agentAddress: "0xABC123", workspaceId: "team-9"
        )
        defer {
            WorkspacesService.setBillingWorkspace(
                agentId: agentId, agentAddress: "0xABC123", workspaceId: nil
            )
        }

        func service(providerType: RemoteProviderType) -> RemoteProviderService {
            RemoteProviderService(
                provider: RemoteProvider(
                    name: "p",
                    host: providerType == .osaurusRouter ? "router.osaurus.ai" : "api.x.ai",
                    providerProtocol: .https,
                    port: nil,
                    basePath: "/v1",
                    authType: .none,
                    providerType: providerType
                ),
                models: ["m"],
                resolvedHeaders: [:]
            )
        }
        let params = GenerationParameters(temperature: 0.7, maxTokens: 128)

        // Router + bound agent: context rides in the body.
        let routerRequest = await ChatExecutionContext.$currentAgentId.withValue(agentId) {
            await service(providerType: .osaurusRouter).buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: params,
                model: "osaurus/minimax-m3",
                stream: true,
                tools: nil,
                toolChoice: nil
            )
        }
        #expect(routerRequest.workspaceContext?.workspaceId == "team-9")
        #expect(routerRequest.workspaceContext?.agentAddress == "0xabc123")

        // Router + no bound agent: personal billing, no context.
        let noAgentRequest = await service(providerType: .osaurusRouter).buildChatRequest(
            messages: [ChatMessage(role: "user", content: "hi")],
            parameters: params,
            model: "osaurus/minimax-m3",
            stream: true,
            tools: nil,
            toolChoice: nil
        )
        #expect(noAgentRequest.workspaceContext == nil)

        // Non-router provider + bound agent: the field must never leak to
        // other OpenAI-compat upstreams (some 422 on unknown keys).
        let compatRequest = await ChatExecutionContext.$currentAgentId.withValue(agentId) {
            await service(providerType: .openaiLegacy).buildChatRequest(
                messages: [ChatMessage(role: "user", content: "hi")],
                parameters: params,
                model: "grok-4",
                stream: true,
                tools: nil,
                toolChoice: nil
            )
        }
        #expect(compatRequest.workspaceContext == nil)
    }

    @Test func summaryEvent_decodesBilledToAndParsesWorkspaceId() throws {
        let body = """
            {"osaurus":{"request_id":"r1","cost_micro":"1234","status":"completed",
             "token_source":"provider","input_tokens":10,"output_tokens":5,
             "billed_to":"workspace:team-1"}}
            """
        let event = try JSONDecoder().decode(
            OsaurusRouterSummaryEvent.self, from: Data(body.utf8)
        )
        #expect(event.osaurus.billedTo == "workspace:team-1")
        #expect(event.osaurus.billedWorkspaceId == "team-1")

        // Pre-rename routers emitted `team:<id>` (no alias on the router side,
        // so the client must keep understanding it to avoid a phantom personal
        // deduction against an older router).
        let legacyTag = """
            {"osaurus":{"request_id":"r1","cost_micro":"1234","status":"completed",
             "token_source":"provider","input_tokens":10,"output_tokens":5,
             "billed_to":"team:team-1"}}
            """
        let legacyEvent = try JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: Data(legacyTag.utf8))
        #expect(legacyEvent.osaurus.billedWorkspaceId == "team-1")
        #expect(
            try JSONDecoder().decode(
                OsaurusRouterSummaryEvent.self,
                from: Data(legacyTag.replacingOccurrences(of: "team:team-1", with: "workspace:").utf8)
            ).osaurus.billedWorkspaceId == nil, "an empty id is not a workspace")

        // Personal summaries (no billed_to) keep decoding and parse to nil.
        let personal = """
            {"osaurus":{"request_id":"r1","cost_micro":"1234","status":"completed",
             "token_source":"provider","input_tokens":10,"output_tokens":5}}
            """
        let personalEvent = try JSONDecoder().decode(
            OsaurusRouterSummaryEvent.self, from: Data(personal.utf8)
        )
        #expect(personalEvent.osaurus.billedTo == nil)
        #expect(personalEvent.osaurus.billedWorkspaceId == nil)

        // Billing summary carries the tag through to the ledger/turn stamp.
        let summary = RouterBillingSummary(event.osaurus)
        #expect(summary.billedTo == "workspace:team-1")

        // Pre-Workspaces persisted ledger entries decode without the field.
        let legacy = try JSONDecoder().decode(
            RouterBillingSummary.self,
            from: Data(
                #"{"costMicro":"9","status":"completed","tokenSource":"provider","inputTokens":1,"outputTokens":1}"#
                    .utf8
            )
        )
        #expect(legacy.billedTo == nil)
    }

    @Test func chatErrorCopy_distinguishesWorkspaceFromPersonal() {
        // Reproduce the real streaming-error pipeline: the router's 402 body
        // goes through `extractErrorMessage` ("message (code: CODE)"), gets
        // wrapped in `requestFailed("HTTP 402: …")`, and its
        // `localizedDescription` passes through the diagnostic redactor
        // before `ChatErrorMessages` matches on it. (A raw `"code":"…"` JSON
        // field would be masked by the redactor — the `(code: …)` shape is
        // what actually reaches the matcher.)
        func chatCopy(forRouter402 body: String) -> String {
            let extracted = RemoteProviderService.extractErrorMessage(
                from: Data(body.utf8), statusCode: 402
            )
            let error = RemoteProviderServiceError.requestFailed("HTTP 402: \(extracted)")
            return ChatErrorMessages.assistantMessage(for: error)
        }

        let workspaceCopy = chatCopy(
            forRouter402:
                #"{"error":{"code":"WORKSPACE_INSUFFICIENT_FUNDS","message":"team pool exhausted"}}"#
        )
        #expect(workspaceCopy.contains("workspace's pool is out of credits"))
        // The router fires an armed auto-reload on this failure, so the copy
        // says to retry — and points at the owner, never at a personal top-up.
        #expect(workspaceCopy.contains("auto-reload"))
        #expect(workspaceCopy.contains("ask the owner to add credits"))
        #expect(!workspaceCopy.contains("Add credits to continue"))

        let personalCopy = chatCopy(
            forRouter402:
                #"{"error":{"code":"INSUFFICIENT_FUNDS","message":"balance below estimated max cost"}}"#
        )
        #expect(personalCopy.contains("Add credits to continue"))
    }
}

/// A past-due workspace: the entitlement stays inactive until the owner's
/// subscription is current again.
private let pastDueDetailBody =
    #"{"id":"team-1","name":"Dino Devs","role":"owner","source":"subscription","entitlement":{"active":false,"source":"subscription"},"created_at":"2026-08-31T00:00:00.000Z"}"#

/// `GET /workspaces/prices`: the single plan with a 14-day trial and live
/// monthly/yearly prices.
private let pricesBody =
    #"{"plan":{"seats":null,"max_shared_agents":null,"monthly_credit_micro":"20000000","monthly_credits":"20.00","trial_days":14},"prices":[{"id":"price_month","billing_interval":"month","price_usd_micro":"20000000","price_usd":"20.00","active":true},{"id":"price_year","billing_interval":"year","price_usd_micro":"200000000","price_usd":"200.00","active":true}]}"#

/// Thread-safe request counter for stub handlers (`@Sendable` closures).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Counter whose `increment()` returns the new value (for "nth call" stubs).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// An active, subscription-backed, owner-role `team-1` detail with the given
/// pool balance.
private func liveDetail(balanceMicro: String) -> String {
    #"{"id":"team-1","name":"Pool","role":"owner","source":"subscription","entitlement":{"active":true,"source":"subscription","monthly_credit_micro":"20000000"},"balance_micro":"\#(balanceMicro)","pool_frozen":false}"#
}

/// One-way latch for stub handlers that change shape after a mutation.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Stub transport

/// One URLProtocol subclass (with its own handler storage) per suite: suites
/// are `.serialized` internally but run in parallel with each other.
private final class WorkspacesClientURLProtocol: WorkspacesStubURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static var handler: Handler?
    override class var currentHandler: Handler? { handler }
}

private final class WorkspacesServiceURLProtocol: WorkspacesStubURLProtocolBase, @unchecked Sendable {
    nonisolated(unsafe) static var handler: Handler?
    override class var currentHandler: Handler? { handler }
}

private class WorkspacesStubURLProtocolBase: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    class var currentHandler: Handler? { nil }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = type(of: self).currentHandler else {
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

private extension URLRequest {
    var workspacesHTTPBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Deeplink

@Suite("Workspace auto-connect")
struct WorkspaceAutoConnectTests {
    private func agent(
        _ address: String,
        owner: String? = "0xOWNER",
        online: Bool? = true
    ) -> OsaurusRouterWorkspaceAgent {
        OsaurusRouterWorkspaceAgent(
            agentAddress: address,
            displayName: "Agent \(address)",
            description: nil,
            owner: OsaurusRouterWorkspacePerson(
                accountId: nil, walletAddress: owner, displayName: nil
            ),
            relayURL: nil,
            online: online,
            lastSeen: nil,
            sharedAt: nil
        )
    }

    @Test func candidatesAreOthersUnpairedAndNotOffline() {
        let now = Date()
        let roster = [
            agent("0xA"),  // eligible
            agent("0xB", owner: "0xme"),  // mine (case-insensitive match)
            agent("0xC"),  // already paired
            agent("0xD"),  // handshake in flight
            agent("0xE", online: false),  // host known offline
            agent("0xF", online: nil),  // presence unknown → still try once
        ]
        let picked = WorkspaceAgentConnectService.autoConnectCandidates(
            agents: roster,
            myWalletAddress: "0xME",
            pairedAddresses: ["0xc"],
            connectingAddresses: ["0xd"],
            lastAttempts: [:],
            now: now
        )
        #expect(picked.map(\.agentAddress) == ["0xA", "0xF"])
    }

    @Test func recentFailuresWaitOutTheCooldown() {
        let now = Date()
        let roster = [agent("0xA"), agent("0xB")]
        let recent = now.addingTimeInterval(-WorkspaceAgentConnectService.autoConnectRetryInterval / 2)
        let old = now.addingTimeInterval(
            -(WorkspaceAgentConnectService.autoConnectRetryInterval + 1)
        )
        let picked = WorkspaceAgentConnectService.autoConnectCandidates(
            agents: roster,
            myWalletAddress: nil,
            pairedAddresses: [],
            connectingAddresses: [],
            lastAttempts: ["0xa": recent, "0xb": old],
            now: now
        )
        #expect(picked.map(\.agentAddress) == ["0xB"])
    }

    @Test func unknownSelfWalletNeverExcludesAgents() {
        // Before the first signed router call the local wallet is unknown;
        // the owner check must not accidentally match everything or nothing.
        let picked = WorkspaceAgentConnectService.autoConnectCandidates(
            agents: [agent("0xA", owner: nil), agent("0xB")],
            myWalletAddress: nil,
            pairedAddresses: [],
            connectingAddresses: [],
            lastAttempts: [:]
        )
        #expect(picked.count == 2)
    }
}

@Suite("Workspaces deeplinks")
struct WorkspacesDeepLinkTests {
    private func parse(_ raw: String) -> PendingWorkspaceActivation? {
        WorkspacesDeepLinkRouter.parseActivation(URL(string: raw)!)
    }

    private func parseJoin(_ raw: String) -> PendingWorkspaceJoin? {
        WorkspacesDeepLinkRouter.parseJoin(URL(string: raw)!)
    }

    @Test func parsesJoinLinkExactlyAsRouterMintsIt() throws {
        let code = "7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"
        let pending = try #require(parseJoin("osaurus://workspaces/join?code=\(code)"))
        #expect(pending.code == code)

        // Case/whitespace tolerance matches activation.
        #expect(parseJoin("OSAURUS://Workspaces/join?CODE=%20\(code)%20")?.code == code)
    }

    @Test func legacyTeamsHostIsStillAccepted() throws {
        // Invite/activation links minted before the Teams → Workspaces rename
        // keep working for their lifetime; the web/router flip independently.
        let code = "7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"
        #expect(try #require(parseJoin("osaurus://teams/join?code=\(code)")).code == code)
        #expect(try #require(parse("osaurus://teams/activate?code=act_9f8e7d6c")).code == "act_9f8e7d6c")
        #expect(WorkspacesDeepLinkRouter.claims(URL(string: "osaurus://teams/join?code=\(code)")!))
        #expect(WorkspacesDeepLinkRouter.claims(URL(string: "osaurus://workspaces/join?code=\(code)")!))
        #expect(!WorkspacesDeepLinkRouter.claims(URL(string: "osaurus://team/join?code=\(code)")!))
        #expect(!WorkspacesDeepLinkRouter.claims(URL(string: "https://workspaces/join?code=\(code)")!))
    }

    @Test func normalizedRewritesOnlyLegacyHost() {
        let code = "7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"
        #expect(
            WorkspacesDeepLinkRouter.normalized("osaurus://teams/join?code=\(code)")
                == "osaurus://workspaces/join?code=\(code)"
        )
        #expect(
            WorkspacesDeepLinkRouter.normalized("OSAURUS://Teams/activate?code=act_1")
                == "osaurus://workspaces/activate?code=act_1"
        )
        // Current-host links and unrelated strings pass through untouched.
        let current = "osaurus://workspaces/join?code=\(code)"
        #expect(WorkspacesDeepLinkRouter.normalized(current) == current)
        #expect(WorkspacesDeepLinkRouter.normalized("https://osaurus.ai/teams") == "https://osaurus.ai/teams")
        #expect(WorkspacesDeepLinkRouter.normalized(code) == code)
    }

    @Test func joinAndActivateDoNotCrossParse() {
        let code = "7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"
        #expect(parse("osaurus://workspaces/join?code=\(code)") == nil)
        #expect(parseJoin("osaurus://workspaces/activate?code=\(code)") == nil)
    }

    @Test func rejectsMalformedJoinLinks() {
        #expect(parseJoin("osaurus://workspaces/join") == nil)
        #expect(parseJoin("osaurus://workspaces/join?code=") == nil)
        #expect(parseJoin("osaurus://workspaces/join?code=abc") == nil)
        #expect(parseJoin("osaurus://workspaces/join?code=has%20space") == nil)
        #expect(parseJoin("osaurus://workspaces/joined?code=act_9f8e7d6c") == nil)
        #expect(parseJoin("https://workspaces/join?code=act_9f8e7d6c") == nil)
    }

    @Test @MainActor func handleStagesJoinAndActivationSeparately() {
        let service = WorkspacesService.shared
        service.pendingActivation = nil
        service.pendingJoin = nil
        defer {
            service.pendingActivation = nil
            service.pendingJoin = nil
        }

        let code = "7a2b3c4d-0000-4000-8000-000000000001.0123456789abcdef0123456789abcdef"
        #expect(WorkspacesDeepLinkRouter.handle(URL(string: "osaurus://workspaces/join?code=\(code)")!))
        #expect(service.pendingJoin?.code == code)
        #expect(service.pendingActivation == nil)

        #expect(WorkspacesDeepLinkRouter.handle(URL(string: "osaurus://workspaces/activate?code=act_9f8e7d6c")!))
        #expect(service.pendingActivation?.code == "act_9f8e7d6c")
        // Staging an activation leaves an earlier join untouched.
        #expect(service.pendingJoin?.code == code)

        // Other hosts are not ours.
        #expect(!WorkspacesDeepLinkRouter.handle(URL(string: "osaurus://pair?code=x")!))

        // The pre-rename host is claimed and staged exactly like the new one.
        service.pendingJoin = nil
        #expect(WorkspacesDeepLinkRouter.handle(URL(string: "osaurus://teams/join?code=\(code)")!))
        #expect(service.pendingJoin?.code == code)
    }

    @Test func legacySettingsTabIdResolvesToWorkspaces() {
        #expect(ManagementTab.resolved(from: "teams") == .workspaces)
        #expect(ManagementTab.resolved(from: "workspaces") == .workspaces)
    }

    @Test func parsesCodeNameAndPlan() throws {
        let pending = try #require(
            parse("osaurus://workspaces/activate?code=act_9f8e7d6c&name=Dino%20Devs&plan=Workspace%20S")
        )
        #expect(pending.code == "act_9f8e7d6c")
        #expect(pending.suggestedName == "Dino Devs")
        #expect(pending.planLabel == "Workspace S")
    }

    @Test func nameAndPlanAreOptional() throws {
        let pending = try #require(parse("osaurus://workspaces/activate?code=act_9f8e7d6c"))
        #expect(pending.suggestedName == nil)
        #expect(pending.planLabel == nil)

        // Empty values collapse to nil rather than an empty prefill.
        let empties = try #require(parse("osaurus://workspaces/activate?code=act_9f8e7d6c&name=&plan="))
        #expect(empties.suggestedName == nil)
        #expect(empties.planLabel == nil)
    }

    @Test func hostAndParamsAreCaseInsensitiveAndTrimmed() throws {
        let pending = try #require(parse("OSAURUS://Workspaces/activate?CODE=%20act_9f8e7d6c%20"))
        #expect(pending.code == "act_9f8e7d6c")
    }

    @Test func suggestedNameIsCappedToRouterLimit() throws {
        let long = String(repeating: "n", count: 120)
        let pending = try #require(parse("osaurus://workspaces/activate?code=act_9f8e7d6c&name=\(long)"))
        #expect(pending.suggestedName?.count == 80)
    }

    @Test func rejectsMalformedLinks() {
        // Missing / implausible code.
        #expect(parse("osaurus://workspaces/activate") == nil)
        #expect(parse("osaurus://workspaces/activate?code=") == nil)
        #expect(parse("osaurus://workspaces/activate?code=abc") == nil)
        #expect(parse("osaurus://workspaces/activate?code=has%20space%20inside") == nil)
        // Wrong path / host / scheme.
        #expect(parse("osaurus://workspaces/other?code=act_9f8e7d6c") == nil)
        #expect(parse("osaurus://teams?code=act_9f8e7d6c") == nil)
        #expect(parse("osaurus://themes-install?code=act_9f8e7d6c") == nil)
        #expect(parse("https://workspaces/activate?code=act_9f8e7d6c") == nil)
    }
}

// MARK: - Status badge

/// The list/detail pill: one plan, so a healthy paid workspace shows nothing;
/// trial / comp / suspended / past-due / inactive are the labelled states.
@Suite("Workspace status badge")
struct WorkspaceStatusBadgeTests {
    private func kind(
        _ source: OsaurusRouterWorkspaceBillingSource?,
        active: Bool,
        trialing: Bool = false,
        ownerStatus: String? = nil
    ) -> WorkspaceStatusBadge.Kind? {
        WorkspaceStatusBadge.kind(
            source: source, active: active, trialing: trialing, ownerSubscriptionStatus: ownerStatus
        )
    }

    @Test func healthyPaidWorkspaceHasNoBadge() {
        #expect(kind(.subscription, active: true) == nil)
        // Unknown-but-active source (future router) also stays quiet.
        #expect(kind(nil, active: true) == nil)
    }

    @Test func ownerTrialShowsTrialOnlyWhileActive() {
        #expect(kind(.subscription, active: true, trialing: true) == .trial)
        // A member never sees the owner's trial (trialing is false for them).
        #expect(kind(.subscription, active: true, trialing: false) == nil)
        // Suspension and inactivity win over the trial label.
        #expect(kind(.suspended, active: false, trialing: true) == .suspended)
        #expect(kind(.subscription, active: false, trialing: true) == .inactive)
    }

    @Test func compAndSuspendedAndPastDue() {
        #expect(kind(.comp, active: true) == .comp)
        #expect(kind(.suspended, active: false) == .suspended)
        #expect(kind(.suspended, active: true) == .suspended)
        #expect(kind(.subscription, active: false, ownerStatus: "past_due") == .pastDue)
        #expect(kind(.subscription, active: false, ownerStatus: "incomplete") == .inactive)
        #expect(kind(.subscription, active: false) == .inactive)
        #expect(kind(nil, active: false) == .inactive)
    }
}

// MARK: - Share agent sheet naming

/// The Share Agent sheet prefills the workspace display name from the picked
/// agent. Picking a different agent must replace an untouched prefill (else
/// agent B gets shared under agent A's name) while leaving a user-typed name
/// alone.
@Suite("Share agent sheet display name")
struct WorkspaceShareAgentSheetNamingTests {
    private typealias Sheet = WorkspaceShareAgentSheet

    @Test func emptyFieldTakesSelectedAgentName() {
        #expect(
            Sheet.nextDisplayName(current: "", prefilled: nil, selectedAgentName: "Dinoki")
                == "Dinoki"
        )
        #expect(
            Sheet.nextDisplayName(current: "   ", prefilled: nil, selectedAgentName: "Dinoki")
                == "Dinoki"
        )
    }

    @Test func untouchedPrefillFollowsNewSelection() {
        // Regression: Dinoki clicked first, then Editorial Writer — the field
        // used to keep "Dinoki" and Editorial Writer's address was shared
        // under Dinoki's name.
        #expect(
            Sheet.nextDisplayName(
                current: "Dinoki", prefilled: "Dinoki", selectedAgentName: "Editorial Writer"
            ) == "Editorial Writer"
        )
    }

    @Test func userTypedNameIsPreserved() {
        #expect(
            Sheet.nextDisplayName(
                current: "Newsroom bot", prefilled: "Dinoki", selectedAgentName: "Editorial Writer"
            ) == "Newsroom bot"
        )
        // A name typed before any selection (no prefill yet) is kept too.
        #expect(
            Sheet.nextDisplayName(
                current: "Newsroom bot", prefilled: nil, selectedAgentName: "Editorial Writer"
            ) == "Newsroom bot"
        )
    }

    @Test func reselectingSameAgentIsStable() {
        #expect(
            Sheet.nextDisplayName(current: "Dinoki", prefilled: "Dinoki", selectedAgentName: "Dinoki")
                == "Dinoki"
        )
    }
}
