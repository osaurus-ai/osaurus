//
//  WebhookProviderProfileTests.swift
//  osaurusTests
//
//  Provider profiles for the webhook source: each verifier against a
//  signature built the provider's documented way, replay windows, the
//  pre-auth handshakes, delivery-id / event-type extraction, and that the
//  generic profile is the webhook as it was.
//

import CryptoKit
import Foundation
import Testing

@testable import OsaurusCore

struct WebhookProviderProfileTests {
    static let secret = "whsec_provider_test"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(
        method: String = "POST", headers: [String: String] = [:], query: [String: String] = [:],
        body: String = #"{"id":"evt_1","type":"invoice.paid"}"#, uri: String? = "/events/tok",
        at receivedAt: Date = Self.now
    ) -> WebhookRequestContext {
        WebhookRequestContext(
            method: method, headers: headers, query: query, body: Data(body.utf8), uri: uri, receivedAt: receivedAt)
    }

    private func hexHMAC(_ message: String, _ secret: String = Self.secret) -> String {
        WebhookVerification.hex(
            HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }

    private func profile(_ provider: WebhookProvider, verification: WebhookVerificationMethod = .hmacSHA256)
        -> WebhookProviderProfile
    {
        WebhookProviderProfile.profile(for: WebhookSourceConfig(provider: provider, verification: verification))
    }

    private func verify(_ profile: WebhookProviderProfile, _ request: WebhookRequestContext, secret: String? = secret)
        -> Bool
    {
        WebhookVerification.verify(profile.verifier, request: request, secret: secret, sourceAddress: nil)
    }

    // MARK: Generic

    @Test func genericProfileIsTheWebhookAsItWas() {
        let hmac = profile(.generic)
        #expect(hmac.verifier == .hmacSHA256(header: WebhookSourceConfig.defaultSignatureHeader, prefix: nil))
        #expect(hmac.handshakes.isEmpty)
        #expect(hmac.fetcher == nil)
        #expect(hmac.registration == nil)
        #expect(!hmac.secretIssuedByProvider)
        #expect(EventWebhookIngress.dedupeHeaders == ["Idempotency-Key", "X-Idempotency-Key", "X-GitHub-Delivery", "X-Request-Id"])
        #expect(profile(.generic, verification: .none).verifier == .none)
        #expect(
            profile(.generic, verification: .sharedSecretHeader).verifier
                == .sharedSecretHeader(header: WebhookSourceConfig.defaultSecretHeader))

        let request = context(headers: ["X-Request-Id": "r-1", "X-GitHub-Delivery": "g-1"])
        #expect(hmac.deliveryId(in: request) == "g-1")
        #expect(hmac.eventType(in: request) == nil)
    }

    @Test func checksSecretFollowsTheVerifier() {
        #expect(WebhookSourceConfig(verification: .none).checksSecret == false)
        #expect(WebhookSourceConfig(verification: .hmacSHA256).checksSecret)
        #expect(WebhookSourceConfig(provider: .sns, verification: .hmacSHA256).checksSecret == false)
        #expect(WebhookSourceConfig(provider: .stripe, verification: .none).checksSecret)
    }

    @Test func providerDecodesAsGenericForOlderFiles() throws {
        let json = #"{"token":"abc","verification":"none","maxBodyBytes":1024,"rateLimitPerMinute":10}"#
        let config = try JSONDecoder().decode(WebhookSourceConfig.self, from: Data(json.utf8))
        #expect(config.provider == .generic)
    }

    // MARK: Verifiers

    @Test func githubSignsTheBodyWithSHA256() {
        let body = #"{"action":"opened"}"#
        let github = profile(.github)
        let good = context(
            headers: [
                "X-Hub-Signature-256": "sha256=" + hexHMAC(body), "X-GitHub-Delivery": "d-42",
                "X-GitHub-Event": "issues",
            ], body: body)
        #expect(verify(github, good))
        #expect(github.deliveryId(in: good) == "d-42")
        #expect(github.eventType(in: good) == "issues")
        #expect(!verify(github, context(headers: ["X-Hub-Signature-256": "sha256=" + hexHMAC("other")], body: body)))
        #expect(!verify(github, good, secret: nil))
    }

    @Test func stripeChecksTheTimestampedSignatureAndItsWindow() {
        let body = #"{"id":"evt_1","type":"invoice.paid"}"#
        let t = Int(Self.now.timeIntervalSince1970)
        let header = "t=\(t),v1=\(hexHMAC("\(t).\(body)")),v0=ignored"
        let stripe = profile(.stripe)
        #expect(verify(stripe, context(headers: ["Stripe-Signature": header], body: body)))
        #expect(stripe.deliveryId(in: context(body: body)) == "evt_1")
        #expect(stripe.eventType(in: context(body: body)) == "invoice.paid")
        #expect(stripe.secretIssuedByProvider)
        // Replayed past the tolerance.
        #expect(
            !verify(
                stripe,
                context(
                    headers: ["Stripe-Signature": header], body: body,
                    at: Self.now.addingTimeInterval(WebhookVerifier.timestampTolerance + 1))))
        // Body changed after signing.
        #expect(!verify(stripe, context(headers: ["Stripe-Signature": header], body: body + " ")))
    }

    @Test func slackChecksV0SignatureAndAnswersURLVerification() async {
        let body = #"{"type":"event_callback","event_id":"Ev1","event":{"type":"app_mention"}}"#
        let t = String(Int(Self.now.timeIntervalSince1970))
        let slack = profile(.slack)
        let signed = context(
            headers: ["X-Slack-Request-Timestamp": t, "X-Slack-Signature": "v0=" + hexHMAC("v0:\(t):\(body)")],
            body: body)
        #expect(verify(slack, signed))
        #expect(slack.deliveryId(in: signed) == "Ev1")
        #expect(slack.eventType(in: signed) == "app_mention")
        #expect(!verify(slack, context(headers: ["X-Slack-Request-Timestamp": t, "X-Slack-Signature": "v0=00"], body: body)))

        let challenge = context(body: #"{"type":"url_verification","challenge":"abc123"}"#)
        let response = await WebhookHandshakeResponder.respond(slack.handshakes, request: challenge, secret: nil)
        #expect(response?.status == 200)
        #expect(response?.body == #"{"challenge":"abc123"}"#)
        #expect(await WebhookHandshakeResponder.respond(slack.handshakes, request: signed, secret: nil) == nil)
    }

    @Test func shopifySignsTheBodyAsBase64() {
        let body = #"{"id":1}"#
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: Data(Self.secret.utf8)))
        let shopify = profile(.shopify)
        let request = context(
            headers: [
                "X-Shopify-Hmac-Sha256": Data(mac).base64EncodedString(), "X-Shopify-Webhook-Id": "w-1",
                "X-Shopify-Topic": "orders/create",
            ], body: body)
        #expect(verify(shopify, request))
        #expect(shopify.deliveryId(in: request) == "w-1")
        #expect(shopify.eventType(in: request) == "orders/create")
        #expect(!verify(shopify, context(headers: ["X-Shopify-Hmac-Sha256": "bm9wZQ=="], body: body)))
    }

    @Test func twilioSignsThePublicURLPlusSortedFormFields() {
        let body = "To=%2B18005551212&From=%2B12349013030&MessageSid=SM1&Body=Hello+there"
        let url = "https://abc.agent.osaurus.ai/events/tok?x=1"
        var data = url
        for (key, value) in [
            ("Body", "Hello there"), ("From", "+12349013030"), ("MessageSid", "SM1"), ("To", "+18005551212"),
        ] {
            data += key + value
        }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(data.utf8), using: SymmetricKey(data: Data(Self.secret.utf8)))
        let twilio = profile(.twilio)
        let request = context(
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "X-Forwarded-Host": "abc.agent.osaurus.ai",
                "X-Twilio-Signature": Data(mac).base64EncodedString(),
            ], body: body, uri: "/events/tok?x=1")
        #expect(verify(twilio, request))
        #expect(twilio.deliveryId(in: request) == "SM1")
        var wrongHost = request
        wrongHost.headers["X-Forwarded-Host"] = "evil.example.com"
        #expect(!verify(twilio, wrongHost))
        var noURI = request
        noURI.uri = nil
        #expect(!verify(twilio, noURI))
    }

    @Test func graphChecksClientStateAndEchoesValidationTokens() async {
        let graph = profile(.microsoftGraph)
        let body = #"{"value":[{"id":"n1","changeType":"created","clientState":"\#(Self.secret)"}]}"#
        let request = context(body: body)
        #expect(verify(graph, request))
        #expect(graph.deliveryId(in: request) == "n1")
        #expect(graph.eventType(in: request) == "created")
        #expect(!verify(graph, context(body: #"{"value":[{"id":"n1","clientState":"other"}]}"#)))
        #expect(!verify(graph, context(body: #"{"value":[]}"#)))

        // The ingress query is already percent-decoded once; the raw URI wins.
        let validation = context(
            query: ["validationToken": "Validation:+token+100%"], body: "",
            uri: "/events/tok?validationToken=Validation%3A+token+100%25")
        let response = await WebhookHandshakeResponder.respond(graph.handshakes, request: validation, secret: nil)
        #expect(response?.status == 200)
        #expect(response?.contentType.hasPrefix("text/plain") == true)
        #expect(response?.body == "Validation: token 100%")
    }

    @Test func formQueryValueFallsBackToTheParsedQuery() {
        let request = context(query: ["a": "b c"], uri: nil)
        #expect(request.formQueryValue("a") == "b c")
        #expect(request.formQueryValue("missing") == nil)
    }

    @Test func metaAnswersTheHubChallengeOnlyWithTheVerifyToken() async {
        let facebook = profile(.facebook)
        let good = context(
            method: "GET",
            query: ["hub.mode": "subscribe", "hub.verify_token": Self.secret, "hub.challenge": "1158201444"], body: "")
        let ok = await WebhookHandshakeResponder.respond(facebook.handshakes, request: good, secret: Self.secret)
        #expect(ok?.status == 200)
        #expect(ok?.body == "1158201444")
        var bad = good
        bad.query["hub.verify_token"] = "nope"
        let refused = await WebhookHandshakeResponder.respond(facebook.handshakes, request: bad, secret: Self.secret)
        #expect(refused?.status == 403)
    }

    @Test func snsConfirmsOnlyAmazonSubscribeURLs() async {
        let sns = profile(.sns)
        let visits = VisitLog()
        let original = WebhookHandshakeResponder.visitSubscribeURL
        WebhookHandshakeResponder.visitSubscribeURL = { url in
            await visits.add(url)
            return true
        }
        defer { WebhookHandshakeResponder.visitSubscribeURL = original }

        // SNS sends its JSON as text/plain.
        let headers = ["x-amz-sns-message-type": "SubscriptionConfirmation", "Content-Type": "text/plain; charset=UTF-8"]
        var good = context(
            headers: headers,
            body: #"{"Type":"SubscriptionConfirmation","SubscribeURL":"https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=t"}"#
        )
        good.bodyContentType = sns.bodyContentType
        let confirmed = await WebhookHandshakeResponder.respond(sns.handshakes, request: good, secret: nil)
        #expect(confirmed?.status == 200)
        #expect(await visits.count == 1)

        var evil = context(
            headers: headers, body: #"{"Type":"SubscriptionConfirmation","SubscribeURL":"https://evil.example.com/x"}"#)
        evil.bodyContentType = sns.bodyContentType
        let refused = await WebhookHandshakeResponder.respond(sns.handshakes, request: evil, secret: nil)
        #expect(refused?.status == 400)
        #expect(await visits.count == 1)

        let notification = context(headers: ["x-amz-sns-message-type": "Notification", "x-amz-sns-message-id": "m-1"])
        #expect(await WebhookHandshakeResponder.respond(sns.handshakes, request: notification, secret: nil) == nil)
        #expect(sns.deliveryId(in: notification) == "m-1")
    }

    private actor VisitLog {
        private(set) var urls: [URL] = []
        var count: Int { urls.count }
        func add(_ url: URL) { urls.append(url) }
    }
}

// MARK: - Through the ingress

@MainActor
struct WebhookProviderIngressTests {
    @MainActor
    final class Fired {
        var occurrences: [EventOccurrence] = []

        func first() async -> EventOccurrence? {
            for _ in 0 ..< 200 where occurrences.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            return occurrences.first
        }
    }

    private func harness() throws -> (EventManager, EventWebhookIngress, Fired) {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        manager.targetLookup = EventTargetLookup(agentExists: { _ in true })
        let fired = Fired()
        manager.runAction = { _, _, occurrence, _ in
            fired.occurrences.append(occurrence)
            return TaskOutcome(status: .succeeded)
        }
        let secret = WebhookProviderProfileTests.secret
        return (manager, EventWebhookIngress(manager: manager, secretLookup: { _ in secret }), fired)
    }

    @Test func snsNotificationBodyIsReadAsJSON() async throws {
        let (manager, ingress, fired) = try harness()
        let event = manager.create(
            OsaurusEvent(
                name: "Alarms", source: .webhook(WebhookSourceConfig(provider: .sns)),
                action: .agent(AgentEventAction(target: .local(UUID()), instructions: "Page"))))
        let response = await ingress.handleFire(
            token: event.source.webhook!.token,
            request: EventWebhookIngressRequest(
                method: "POST",
                headers: [
                    "Content-Type": "text/plain; charset=UTF-8", "x-amz-sns-message-type": "Notification",
                    "x-amz-sns-message-id": "m-9",
                ],
                query: [:], body: Data(#"{"Type":"Notification","Message":"CPU high"}"#.utf8),
                sourceAddress: "127.0.0.1"))
        #expect(response.status == 202)
        let occurrence = try #require(await fired.first())
        #expect(occurrence.payload.value(atPath: "webhook.body.Message") == .string("CPU high"))
        #expect(occurrence.dedupeKey == "webhook:m-9")
    }

    @Test func aProviderEventTypeReachesThePayloadAndTheSummary() async throws {
        let (manager, ingress, fired) = try harness()
        let secret = WebhookProviderProfileTests.secret
        let event = manager.create(
            OsaurusEvent(
                name: "Issues", source: .webhook(WebhookSourceConfig(provider: .github)),
                action: .agent(AgentEventAction(target: .local(UUID()), instructions: "Triage"))))
        let body = Data(#"{"action":"opened"}"#.utf8)
        let signature =
            "sha256=" + WebhookVerification.hex(
                HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8))))
        let response = await ingress.handleFire(
            token: event.source.webhook!.token,
            request: EventWebhookIngressRequest(
                method: "POST",
                headers: [
                    "Content-Type": "application/json", "X-Hub-Signature-256": signature,
                    "X-GitHub-Delivery": "d-1", "X-GitHub-Event": "issues",
                ],
                query: [:], body: body, sourceAddress: "127.0.0.1"))
        #expect(response.status == 202)
        let occurrence = try #require(await fired.first())
        #expect(occurrence.payload.value(atPath: "webhook.event_type") == .string("issues"))
        #expect(occurrence.dedupeKey == "webhook:d-1")
        #expect(occurrence.summary["event_type"] == "issues")

        // A provider that issues its own secret is never given a generated one.
        let stripe = manager.create(
            OsaurusEvent(
                name: "Payments", source: .webhook(WebhookSourceConfig(provider: .stripe)),
                action: .agent(AgentEventAction(target: .local(UUID()), instructions: "Log"))))
        #expect(!EventSecretsKeychain.hasSecret(eventID: stripe.id))
    }

    @Test func changingTheProviderReplacesTheSecret() throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        var event = manager.create(
            OsaurusEvent(
                name: "Hooks", source: .webhook(WebhookSourceConfig(provider: .github)),
                action: EventPipelineFixtures.agentAction()))
        let generated = try #require(EventSecretsKeychain.secret(eventID: event.id))

        event.source = .webhook(WebhookSourceConfig(token: event.source.webhook!.token, provider: .stripe))
        manager.update(event)
        #expect(!EventSecretsKeychain.hasSecret(eventID: event.id), "Stripe issues its own secret")

        EventSecretsKeychain.saveSecret("whsec_pasted", eventID: event.id)
        event.name = "Renamed"
        manager.update(event)
        #expect(EventSecretsKeychain.secret(eventID: event.id) == "whsec_pasted", "same provider keeps the secret")

        event.source = .webhook(WebhookSourceConfig(token: event.source.webhook!.token, provider: .github))
        manager.update(event)
        let regenerated = try #require(EventSecretsKeychain.secret(eventID: event.id))
        #expect(regenerated != "whsec_pasted")
        #expect(regenerated != generated)
        EventSecretsKeychain.deleteSecret(eventID: event.id)
    }

    @Test func everyServiceHasSetupCopyAndAJSONSample() throws {
        #expect(WebhookProvider.services == WebhookProvider.allCases.filter { $0 != .generic })
        #expect(WebhookProvider.generic.sampleBody == nil)
        for provider in WebhookProvider.services {
            #expect(!provider.setupHint.isEmpty, "\(provider.rawValue) setup hint")
            #expect(!provider.verificationSummary.isEmpty, "\(provider.rawValue) verification summary")
            let body = try #require(provider.sampleBody, "\(provider.rawValue) sample body")
            let parsed = try JSONSerialization.jsonObject(with: Data(body.utf8))
            #expect(parsed is [String: Any], "\(provider.rawValue) sample is a JSON object")
        }
        #expect(WebhookProvider.github.checksSecret && !WebhookProvider.github.issuesSecret)
        #expect(WebhookProvider.stripe.issuesSecret)
        #expect(WebhookProvider.slack.shortName == "Slack")
        #expect(WebhookProvider.facebook.shortName == "Meta")
    }

    @Test func choosingAProviderSwapsOnlyAnUntouchedSample() {
        var draft = WebhookSourceDraft()
        draft.choose(.github)
        #expect(draft.provider == .github)
        #expect(draft.sampleBody == WebhookProvider.github.sampleBody)
        draft.choose(.stripe)
        #expect(draft.sampleBody == WebhookProvider.stripe.sampleBody)
        draft.sampleBody = #"{"mine": true}"#
        draft.choose(.shopify)
        #expect(draft.sampleBody == #"{"mine": true}"#)
        guard case .success(let source) = draft.build(existing: nil), let built = source.webhook else {
            Issue.record("a provider draft must build")
            return
        }
        #expect(built.provider == .shopify)
        #expect(built.verification == WebhookSourceConfig(provider: .shopify).verification)
    }
}
