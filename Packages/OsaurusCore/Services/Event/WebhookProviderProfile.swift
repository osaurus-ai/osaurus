//
//  WebhookProviderProfile.swift
//  osaurus
//
//  What a webhook sender needs beyond the generic URL: how it signs
//  requests, the handshake it does before sending events, where its
//  delivery id and event type live, and (for providers that support it)
//  how the webhook is registered on the provider. The generic profile is
//  today's webhook exactly; the others are data plus small verifiers, so a
//  provider is a new case here, not a new code path.
//

import CryptoKit
import Foundation

/// The service that calls the webhook. `generic` is any sender, checked by
/// the method the user picked (`WebhookSourceConfig.verification`).
public enum WebhookProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case generic
    case github
    case stripe
    case slack
    case shopify
    case twilio
    case microsoftGraph = "microsoft_graph"
    case facebook
    case sns

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .generic: L("Any sender")
        case .github: "GitHub"
        case .stripe: "Stripe"
        case .slack: "Slack Events API"
        case .shopify: "Shopify"
        case .twilio: "Twilio"
        case .microsoftGraph: "Microsoft Graph"
        case .facebook: L("Meta (Facebook, Instagram, WhatsApp Cloud)")
        case .sns: "Amazon SNS"
        }
    }
}

/// How a request proves it came from the sender.
enum WebhookVerifier: Equatable, Sendable {
    case none
    /// The secret verbatim in a header.
    case sharedSecretHeader(header: String)
    /// Hex HMAC-SHA256 of the raw body, optionally prefixed (`sha256=`).
    case hmacSHA256(header: String, prefix: String?)
    /// Stripe `Stripe-Signature: t=…,v1=…` / Slack `v0:ts:body`, with a
    /// replay window.
    case timestampedHMAC(TimestampedHMACStyle)
    /// Twilio: base64 HMAC-SHA1 over the public URL plus sorted form fields.
    case hmacSHA1OverURLAndForm(header: String)
    /// Shopify: base64 HMAC-SHA256 of the raw body.
    case hmacBase64(header: String)
    /// Microsoft Graph: every notification's `clientState` equals the secret.
    case graphClientState

    enum TimestampedHMACStyle: Equatable, Sendable {
        case stripe
        case slack
    }

    static let timestampTolerance: TimeInterval = 300

    var checksSecret: Bool { self != .none }
}

/// A pre-auth exchange a provider does when the webhook is set up.
enum WebhookHandshake: Equatable, Sendable {
    /// Slack: POST `{"type":"url_verification","challenge":…}` → echo the challenge.
    case slackURLVerification
    /// Graph: `?validationToken=…` → echo it as text/plain.
    case graphValidationToken
    /// Meta: GET `hub.mode=subscribe&hub.verify_token=<secret>&hub.challenge=…`.
    case facebookHubChallenge
    /// SNS: `SubscriptionConfirmation` → visit its `SubscribeURL`.
    case snsSubscriptionConfirmation
}

/// Where a value lives in a request.
enum WebhookField: Equatable, Sendable {
    case header(String)
    /// Dot path into the parsed body.
    case body(String)
}

/// Provider-side registration: create the webhook on enable, delete it on
/// disable. The returned state (provider webhook id, expiry) persists in
/// `event_source_state` and comes back to `uninstall` and `verify`.
protocol WebhookRegistration: Sendable {
    func install(event: OsaurusEvent, callbackURL: URL) async throws -> JSONValue
    func uninstall(event: OsaurusEvent, state: JSONValue) async
    /// Launch check that the registration still exists; false reinstalls.
    func verify(event: OsaurusEvent, state: JSONValue) async -> Bool
}

/// Resolves the content of a notify-only push (the body says "something
/// changed", not what).
protocol WebhookNotifyFetcher: Sendable {
    func fetch(event: OsaurusEvent, notification: JSONValue) async throws -> JSONValue
}

/// The request as the profile sees it.
struct WebhookRequestContext: Sendable {
    var method: String
    var headers: [String: String]
    var query: [String: String]
    var body: Data
    /// Path and query as received (`/events/<token>?a=b`).
    var uri: String?
    var receivedAt: Date
    /// How the body is read when the sender's header is wrong for it.
    var bodyContentType: String? = nil

    func header(_ name: String) -> String? {
        EventWebhookIngress.header(name, in: headers)
    }

    var contentType: String? { bodyContentType ?? header("Content-Type") }

    /// A query value decoded the form way (`+` is a space), from the raw URI
    /// when there is one.
    func formQueryValue(_ name: String) -> String? {
        if let uri, let raw = uri.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in raw.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.first == name else { continue }
                let value = parts.count > 1 ? parts[1] : ""
                return value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
            }
        }
        return query[name]
    }

    var parsedBody: JSONValue { EventPayload.parseBody(body, contentType: contentType) }

    func value(_ field: WebhookField) -> String? {
        switch field {
        case .header(let name):
            return header(name)
        case .body(let path):
            guard let value = parsedBody.value(atPath: path) else { return nil }
            let text = EventTemplate.text(of: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// The URL the sender called, as it saw it (behind the relay).
    var publicURL: String? {
        guard let uri else { return nil }
        guard let host = header("X-Forwarded-Host") ?? header("Host") else { return nil }
        let scheme = header("X-Forwarded-Proto") ?? "https"
        return "\(scheme)://\(host)\(uri)"
    }
}

struct WebhookProviderProfile: Sendable {
    let provider: WebhookProvider
    let verifier: WebhookVerifier
    let handshakes: [WebhookHandshake]
    /// First match is the delivery id (dedupe key).
    let deliveryId: [WebhookField]
    /// First match fills `webhook.event_type`.
    let eventType: [WebhookField]
    /// The provider issues the secret (paste it in); otherwise Osaurus
    /// creates one for the user to give the sender.
    let secretIssuedByProvider: Bool
    /// SNS posts JSON as `text/plain`.
    var bodyContentType: String? = nil
    let fetcher: (any WebhookNotifyFetcher)?
    let registration: (any WebhookRegistration)?

    var fetchOnNotify: Bool { fetcher != nil }

    /// Delivery-id headers of the generic profile, in preference order.
    static let genericDeliveryHeaders = ["Idempotency-Key", "X-Idempotency-Key", "X-GitHub-Delivery", "X-Request-Id"]

    static func profile(for config: WebhookSourceConfig) -> WebhookProviderProfile {
        func make(
            _ verifier: WebhookVerifier, handshakes: [WebhookHandshake] = [], deliveryId: [WebhookField],
            eventType: [WebhookField] = [], issued: Bool, bodyContentType: String? = nil
        ) -> WebhookProviderProfile {
            WebhookProviderProfile(
                provider: config.provider, verifier: verifier, handshakes: handshakes, deliveryId: deliveryId,
                eventType: eventType, secretIssuedByProvider: issued, bodyContentType: bodyContentType,
                fetcher: nil, registration: nil)
        }
        switch config.provider {
        case .generic:
            let verifier: WebhookVerifier
            switch config.verification {
            case .none: verifier = .none
            case .sharedSecretHeader:
                verifier = .sharedSecretHeader(header: config.effectiveHeader ?? WebhookSourceConfig.defaultSecretHeader)
            case .hmacSHA256:
                verifier = .hmacSHA256(
                    header: config.effectiveHeader ?? WebhookSourceConfig.defaultSignatureHeader,
                    prefix: config.signaturePrefix)
            }
            return make(verifier, deliveryId: genericDeliveryHeaders.map(WebhookField.header), issued: false)
        case .github:
            return make(
                .hmacSHA256(header: "X-Hub-Signature-256", prefix: "sha256="),
                deliveryId: [.header("X-GitHub-Delivery")], eventType: [.header("X-GitHub-Event")], issued: false)
        case .stripe:
            return make(
                .timestampedHMAC(.stripe), deliveryId: [.body("id")], eventType: [.body("type")], issued: true)
        case .slack:
            return make(
                .timestampedHMAC(.slack), handshakes: [.slackURLVerification],
                deliveryId: [.body("event_id")], eventType: [.body("event.type"), .body("type")], issued: true)
        case .shopify:
            return make(
                .hmacBase64(header: "X-Shopify-Hmac-Sha256"),
                deliveryId: [.header("X-Shopify-Webhook-Id"), .header("X-Shopify-Event-Id")],
                eventType: [.header("X-Shopify-Topic")], issued: true)
        case .twilio:
            return make(
                .hmacSHA1OverURLAndForm(header: "X-Twilio-Signature"),
                deliveryId: [.header("I-Twilio-Idempotency-Token"), .body("MessageSid"), .body("CallSid")],
                issued: true)
        case .microsoftGraph:
            return make(
                .graphClientState, handshakes: [.graphValidationToken],
                deliveryId: [.body("value.0.id")], eventType: [.body("value.0.changeType")], issued: false)
        case .facebook:
            return make(
                .hmacSHA256(header: "X-Hub-Signature-256", prefix: "sha256="), handshakes: [.facebookHubChallenge],
                deliveryId: [.body("entry.0.id")], eventType: [.body("object")], issued: true)
        case .sns:
            return make(
                .none, handshakes: [.snsSubscriptionConfirmation],
                deliveryId: [.header("x-amz-sns-message-id")], eventType: [.header("x-amz-sns-message-type")],
                issued: false, bodyContentType: "application/json")
        }
    }

    func deliveryId(in request: WebhookRequestContext) -> String? {
        deliveryId.lazy.compactMap { request.value($0) }.first
    }

    func eventType(in request: WebhookRequestContext) -> String? {
        eventType.lazy.compactMap { request.value($0) }.first
    }
}

// MARK: - Setup copy

extension WebhookProvider {
    /// The named senders "Add Automation" offers as their own templates.
    static var services: [WebhookProvider] { allCases.filter { $0 != .generic } }

    /// Fits a template card.
    var shortName: String {
        switch self {
        case .slack: "Slack"
        case .facebook: "Meta"
        default: displayName
        }
    }

    var icon: String {
        switch self {
        case .generic: "arrow.down.circle"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .stripe: "creditcard"
        case .slack: "number"
        case .shopify: "bag"
        case .twilio: "phone"
        case .microsoftGraph: "envelope.badge"
        case .facebook: "person.2"
        case .sns: "bell.badge"
        }
    }

    var templateSubtitle: String {
        switch self {
        case .generic: L("Run when another app calls a URL")
        case .github: L("Issues, pull requests, pushes, releases")
        case .stripe: L("Payments, invoices, subscriptions")
        case .slack: L("Messages and app events from the Events API")
        case .shopify: L("Orders, customers, products")
        case .twilio: L("Incoming texts and calls")
        case .microsoftGraph: L("Outlook mail, calendar, OneDrive changes")
        case .facebook: L("Page, Instagram and WhatsApp Cloud events")
        case .sns: L("Notifications from an SNS topic")
        }
    }

    /// Where the URL goes on the provider's side and what comes back.
    var setupHint: String {
        switch self {
        case .generic:
            L("After you save, open the automation to copy its URL and a ready-to-run test command.")
        case .github:
            L("In the repository's Settings → Webhooks, add the URL with content type application/json and paste the secret Osaurus shows on the automation. GitHub's \"ping\" delivery is a good first test.")
        case .stripe:
            L("In Stripe's Developers → Webhooks, add the URL as an endpoint, then paste the endpoint's signing secret (whsec_…) into the automation.")
        case .slack:
            L("In your Slack app's Event Subscriptions, paste the URL (Osaurus answers Slack's URL check), then paste the app's Signing Secret into the automation.")
        case .shopify:
            L("In Shopify's Settings → Notifications → Webhooks, add the URL, then paste the signing key shown under the webhook list into the automation.")
        case .twilio:
            L("Set the relay URL as the phone number's messaging or voice webhook (HTTP POST) and paste the account's Auth Token into the automation. Twilio signs the public address, so the relay URL is required.")
        case .microsoftGraph:
            L("Create a Graph subscription with the URL as notificationUrl and the secret Osaurus shows as clientState. Osaurus answers Graph's validation request.")
        case .facebook:
            L("In the Meta app's Webhooks settings, use the URL as the callback URL, paste the App Secret into the automation, and enter the same App Secret as the verify token.")
        case .sns:
            L("Subscribe the relay URL to the SNS topic over HTTPS. Osaurus confirms the subscription by itself.")
        }
    }

    /// How the request is checked, in a few words.
    var verificationSummary: String {
        switch self {
        case .generic: ""
        case .github: L("HMAC-SHA256 signature in X-Hub-Signature-256")
        case .stripe: L("Stripe-Signature with a 5-minute replay window")
        case .slack: L("X-Slack-Signature with a 5-minute replay window")
        case .shopify: L("Base64 HMAC-SHA256 in X-Shopify-Hmac-Sha256")
        case .twilio: L("X-Twilio-Signature over the public URL and form fields")
        case .microsoftGraph: L("Each notification's clientState must match the secret")
        case .facebook: L("HMAC-SHA256 signature in X-Hub-Signature-256")
        case .sns: L("No signature check; only the subscription handshake")
        }
    }

    /// An example of what the provider posts, for trigger values and Run Now.
    var sampleBody: String? {
        switch self {
        case .generic:
            nil
        case .github:
            #"{"action": "opened", "issue": {"number": 42, "title": "Login fails", "html_url": "https://github.com/acme/app/issues/42", "user": {"login": "octocat"}}, "repository": {"full_name": "acme/app"}, "sender": {"login": "octocat"}}"#
        case .stripe:
            #"{"id": "evt_1Example", "type": "invoice.paid", "data": {"object": {"id": "in_1Example", "customer": "cus_Example", "amount_paid": 2000, "currency": "usd"}}}"#
        case .slack:
            #"{"type": "event_callback", "event_id": "Ev0Example", "team_id": "T0Example", "event": {"type": "message", "channel": "C0Example", "user": "U0Example", "text": "Hello", "ts": "1700000000.000100"}}"#
        case .shopify:
            #"{"id": 820982911946154500, "email": "jon@example.com", "total_price": "199.00", "currency": "USD", "line_items": [{"title": "Shirt", "quantity": 1}]}"#
        case .twilio:
            #"{"From": "+15551234567", "To": "+15557654321", "Body": "Hello", "MessageSid": "SM0Example"}"#
        case .microsoftGraph:
            #"{"value": [{"subscriptionId": "sub-example", "changeType": "created", "resource": "me/messages/AAMkExample", "clientState": "<secret>"}]}"#
        case .facebook:
            #"{"object": "page", "entry": [{"id": "1234567890", "time": 1700000000, "messaging": [{"sender": {"id": "123"}, "message": {"text": "Hello"}}]}]}"#
        case .sns:
            #"{"Type": "Notification", "MessageId": "m-example", "TopicArn": "arn:aws:sns:us-east-1:123456789012:alerts", "Subject": "Alarm", "Message": "CPU above 90%"}"#
        }
    }

    /// The provider hands out the secret; the person pastes it in.
    var issuesSecret: Bool {
        WebhookProviderProfile.profile(for: WebhookSourceConfig(token: "", provider: self)).secretIssuedByProvider
    }

    /// Requests are checked against a secret.
    var checksSecret: Bool {
        WebhookProviderProfile.profile(for: WebhookSourceConfig(token: "", provider: self)).verifier.checksSecret
    }
}

// MARK: - Verification

enum WebhookVerification {
    static func verify(
        _ verifier: WebhookVerifier, request: WebhookRequestContext, secret: String?, sourceAddress: String?
    ) -> Bool {
        switch verifier {
        case .none:
            return true
        case .sharedSecretHeader(let header):
            return substrate(.sharedSecretHeader, header: header, prefix: nil, request, secret, sourceAddress)
        case .hmacSHA256(let header, let prefix):
            return substrate(.hmacSHA256, header: header, prefix: prefix, request, secret, sourceAddress)
        case .timestampedHMAC(let style):
            guard let secret, !secret.isEmpty else { return false }
            return timestamped(style, request: request, secret: secret)
        case .hmacSHA1OverURLAndForm(let header):
            guard let secret, !secret.isEmpty, let received = request.header(header),
                let url = request.publicURL
            else { return false }
            return constantTimeEquals(twilioSignature(url: url, request: request, secret: secret), received)
        case .hmacBase64(let header):
            guard let secret, !secret.isEmpty, let received = request.header(header) else { return false }
            let mac = HMAC<SHA256>.authenticationCode(for: request.body, using: SymmetricKey(data: Data(secret.utf8)))
            return constantTimeEquals(Data(mac).base64EncodedString(), received)
        case .graphClientState:
            guard let secret, !secret.isEmpty,
                let notifications = request.parsedBody.value(atPath: "value")?.arrayValue, !notifications.isEmpty
            else { return false }
            return notifications.allSatisfy {
                constantTimeEquals($0.value(atPath: "clientState")?.stringValue ?? "", secret)
            }
        }
    }

    /// The shared-secret and HMAC-SHA256 checks Agent Channels use.
    private static func substrate(
        _ method: AgentChannelSourceVerificationMethod, header: String, prefix: String?,
        _ request: WebhookRequestContext, _ secret: String?, _ sourceAddress: String?
    ) -> Bool {
        let verdict = AgentChannelAsyncSubstrate.shared.verifyWebhookSource(
            request: AgentChannelWebhookVerificationRequest(
                headers: request.headers, body: request.body, sourceAddress: sourceAddress,
                receivedAt: request.receivedAt),
            policy: AgentChannelSourceVerificationPolicy(
                method: method, headerName: header, secret: secret, signaturePrefix: prefix))
        return verdict.status == .verified
    }

    private static func timestamped(
        _ style: WebhookVerifier.TimestampedHMACStyle, request: WebhookRequestContext, secret: String
    ) -> Bool {
        let timestamp: String
        let candidates: [String]
        let prefix: String
        switch style {
        case .stripe:
            guard let header = request.header("Stripe-Signature") else { return false }
            var parts: [(String, String)] = []
            for item in header.split(separator: ",") {
                let pair = item.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if pair.count == 2 { parts.append((pair[0], pair[1])) }
            }
            guard let t = parts.first(where: { $0.0 == "t" })?.1 else { return false }
            timestamp = t
            candidates = parts.filter { $0.0 == "v1" }.map(\.1)
            prefix = "\(t)."
        case .slack:
            guard let t = request.header("X-Slack-Request-Timestamp"),
                let signature = request.header("X-Slack-Signature"), signature.hasPrefix("v0=")
            else { return false }
            timestamp = t
            candidates = [String(signature.dropFirst(3))]
            prefix = "v0:\(t):"
        }
        guard let seconds = TimeInterval(timestamp),
            abs(request.receivedAt.timeIntervalSince1970 - seconds) <= WebhookVerifier.timestampTolerance,
            !candidates.isEmpty
        else { return false }
        var signed = Data(prefix.utf8)
        signed.append(request.body)
        let expected = hex(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(secret.utf8))))
        return candidates.contains { constantTimeEquals(expected, $0.lowercased()) }
    }

    /// Twilio: URL, then every POST form field's name and value, sorted by name.
    static func twilioSignature(url: String, request: WebhookRequestContext, secret: String) -> String {
        var data = url
        if request.method.uppercased() == "POST",
            (request.contentType ?? "").lowercased().contains("x-www-form-urlencoded"),
            let fields = request.parsedBody.objectValue
        {
            for key in fields.keys.sorted() {
                data += key + EventTemplate.text(of: fields[key])
            }
        }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(data.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }

    static func hex<M: MessageAuthenticationCode>(_ mac: M) -> String {
        Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// MARK: - Handshakes

enum WebhookHandshakeResponder {
    /// Fetches an SNS `SubscribeURL`; tests substitute a recorder.
    nonisolated(unsafe) static var visitSubscribeURL: @Sendable (URL) async -> Bool = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The response a handshake request gets, or nil when the request is
    /// not one (it continues to verification).
    static func respond(
        _ handshakes: [WebhookHandshake], request: WebhookRequestContext, secret: String?
    ) async -> EventWebhookIngressResponse? {
        for handshake in handshakes {
            if let response = await respond(handshake, request: request, secret: secret) { return response }
        }
        return nil
    }

    private static func respond(
        _ handshake: WebhookHandshake, request: WebhookRequestContext, secret: String?
    ) async -> EventWebhookIngressResponse? {
        switch handshake {
        case .slackURLVerification:
            guard request.method.uppercased() == "POST",
                request.parsedBody.value(atPath: "type")?.stringValue == "url_verification",
                let challenge = request.parsedBody.value(atPath: "challenge")?.stringValue
            else { return nil }
            return EventWebhookIngressResponse(status: 200, body: EventWebhookIngress.json(["challenge": challenge]))
        case .graphValidationToken:
            guard let token = request.formQueryValue("validationToken") else { return nil }
            return EventWebhookIngressResponse(status: 200, body: token, contentType: "text/plain; charset=utf-8")
        case .facebookHubChallenge:
            guard request.method.uppercased() == "GET", request.query["hub.mode"] == "subscribe",
                let challenge = request.query["hub.challenge"]
            else { return nil }
            guard let secret, !secret.isEmpty,
                WebhookVerification.constantTimeEquals(request.query["hub.verify_token"] ?? "", secret)
            else {
                return EventWebhookIngressResponse(
                    status: 403, body: EventWebhookIngress.errorBody("unauthorized", "Verify token did not match."))
            }
            return EventWebhookIngressResponse(status: 200, body: challenge, contentType: "text/plain; charset=utf-8")
        case .snsSubscriptionConfirmation:
            guard request.header("x-amz-sns-message-type") == "SubscriptionConfirmation" else { return nil }
            guard let raw = request.parsedBody.value(atPath: "SubscribeURL")?.stringValue,
                let url = URL(string: raw), url.scheme == "https",
                let host = url.host?.lowercased(), host.hasPrefix("sns."), host.hasSuffix(".amazonaws.com")
            else {
                return EventWebhookIngressResponse(
                    status: 400,
                    body: EventWebhookIngress.errorBody("invalid_subscription", "SubscribeURL is not an SNS URL."))
            }
            let confirmed = await visitSubscribeURL(url)
            return EventWebhookIngressResponse(
                status: confirmed ? 200 : 502,
                body: EventWebhookIngress.json(["subscription": confirmed ? "confirmed" : "failed"]))
        }
    }
}
