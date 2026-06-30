//
//  PrivacyFilterPipeline.swift
//  osaurus / PrivacyFilter
//
//  Glue between `RemoteProviderService` and the rest of the
//  PrivacyFilter module. The pipeline:
//
//    1. `applyOutbound`: read the config + per-provider toggle, decide
//       whether to filter; fetch the conversation's `RedactionMap` (or
//       mint one); run detection over every scrubbable string in the
//       message history; present the review sheet (when a UI presenter
//       is registered with `PrivacyReviewService`); return the scrubbed
//       messages + a non-nil map when filtering happened.
//
//       Cancel contract: if the user dismisses the review sheet, the
//       pipeline throws `PrivacyFilterPipelineError.reviewCanceled`.
//       Callers (`RemoteProviderService`) catch that error and abort
//       the request without firing HTTP. This replaces the older
//       `([], map)` sentinel which silently sent malformed empty
//       requests when ignored.
//
//    2. `wrapInboundStream`: pass-through if `map` is nil; otherwise
//       splice a `StreamingUnscrubber` between the upstream chunks and
//       the consumer.
//
//    3. `unscrubInbound`: one-shot version for non-streaming responses
//       (and tool-call argument JSON).
//
//  Fail-CLOSED end-to-end: every write path that could leak PII
//  must throw rather than silently degrade. Concretely:
//
//    * Engine missing / lazy-load failed →
//      `PrivacyFilterPipelineError.engineUnavailable`. We do NOT
//      pass the original messages through; the caller (and the
//      chat layer) must surface an actionable error pointing at
//      Settings → Privacy.
//    * Scrub returned no changes when the user approved entities →
//      `PrivacyFilterPipelineError.scrubNoOp(approvedCount:)`.
//      Catches a regression where `applyingScrub` is fed an empty
//      substitution map.
//    * Post-scrub leak scan re-detects regex categories AND
//      ML-only originals in the scrubbed payload → `scrubLeaked`.
//      The ML re-scan covers `Send anyway` semantics: skipping a
//      person/address/secret entity still blocks the send, since
//      the post-scrub invariant uses the model not just regex.
//    * Non-interactive caller (HTTP, plugin, agent) with no
//      review presenter and `requireReviewForNonInteractive`
//      enabled → `PrivacyReviewService.review` returns `.canceled`,
//      which the pipeline lifts into `reviewCanceled`.
//
//  Inbound paths (`wrapInboundStream` / `unscrubInbound`) are
//  separately documented but the same rule applies: never let a
//  placeholder ship to a local tool / consumer; if unscrubbing
//  fails for an unknown token we leave it literal (see
//  `StreamingUnscrubber`'s "Hallucinated placeholder policy").
//
//  Settings UI guards against ever flipping the master toggle on
//  while the engine is unloaded, so the `engineUnavailable` branch
//  is reserved for transient post-install errors (e.g. on-disk
//  bundle deleted out from under us by L2's "Remove" button).
//

import Foundation

/// Errors thrown by the privacy pipeline. Distinct error type so chat
/// layer can distinguish a privacy cancel from a network failure and
/// avoid surfacing the user-facing "Error: …" bubble.
enum PrivacyFilterPipelineError: Error, Equatable, LocalizedError {
    /// User dismissed the redaction review sheet (or the awaiting
    /// task was cancelled while suspended on it). The caller must
    /// abort the send without contacting the provider.
    case reviewCanceled

    /// Filter is enabled for this provider but we can't actually
    /// scrub — engine isn't loaded, lazy-load failed, or detection
    /// threw. Fail-CLOSED: a privacy feature must never silently send
    /// unscrubbed text just because the model couldn't run. The
    /// caller surfaces a clear error to the user instead.
    case engineUnavailable(String)

    /// Detection succeeded and the user approved entities, but
    /// `applyingScrub` produced zero substitutions. Almost certainly
    /// a wiring bug (entity.original doesn't match the wire text).
    /// We surface this rather than ship unscrubbed text on a privacy
    /// feature that the user explicitly enabled.
    case scrubNoOp(approvedCount: Int)

    /// Post-scrub invariant tripped: at least one PII pattern still
    /// matches in the outbound payload after substitution. The
    /// payload counts (NOT the raw matches) are surfaced to the user
    /// so they can see *what* leaked at a glance without the value
    /// ever leaving this process. Send is blocked.
    case scrubLeaked(categoryCounts: [EntityCategory: Int])

    var errorDescription: String? {
        switch self {
        case .reviewCanceled:
            return "Privacy Filter: review canceled."
        case .engineUnavailable(let detail):
            return
                "Privacy Filter is enabled but the on-device model isn't available: \(detail). Open Settings → Privacy to re-download, or disable the filter to send without redaction."
        case .scrubNoOp(let count):
            return
                "Privacy Filter: \(count) approved redaction(s) didn't apply (substitution mismatch). The message was not sent. This is a bug — please report."
        case .scrubLeaked(let counts):
            return Self.formatScrubLeaked(categoryCounts: counts)
        }
    }

    /// Stable machine-readable code surfaced through HTTP error
    /// envelopes. API clients can switch on this to render a
    /// privacy-specific UI instead of treating the block as a
    /// generic 500.
    var httpErrorCode: String {
        switch self {
        case .reviewCanceled: return "privacy_filter_review_canceled"
        case .engineUnavailable: return "privacy_filter_engine_unavailable"
        case .scrubNoOp: return "privacy_filter_scrub_no_op"
        case .scrubLeaked: return "privacy_filter_scrub_leaked"
        }
    }

    /// HTTP-status hint for callers that want to map the privacy
    /// pipeline error to a non-200 envelope. Most are 422 (the
    /// request was understood but couldn't be processed safely);
    /// `engineUnavailable` is 503 to signal "retry later when the
    /// model is loaded."
    var httpStatus: Int {
        switch self {
        case .reviewCanceled: return 499  // client-closed-request analog
        case .engineUnavailable: return 503
        case .scrubNoOp, .scrubLeaked: return 422
        }
    }

    /// Format the leak-report string from category counts. Splits out
    /// so tests can exercise the pluralization without manufacturing
    /// a thrown error. Categories render in a stable order so the
    /// message text is reproducible for screenshots / bug reports.
    static func formatScrubLeaked(
        categoryCounts: [EntityCategory: Int]
    ) -> String {
        let order: [EntityCategory] = [
            .phone, .email, .url, .accountNumber,
            .address, .person, .date, .secret,
        ]
        var parts: [String] = []
        for category in order {
            guard let count = categoryCounts[category], count > 0 else { continue }
            parts.append(localizedCount(count, for: category))
        }
        // Stragglers (shouldn't happen but defends against new
        // categories slotted in without updating `order`).
        for (category, count) in categoryCounts
        where !order.contains(category) && count > 0 {
            parts.append(localizedCount(count, for: category))
        }
        let joined = joinWithAnd(parts)
        let label = joined.isEmpty ? "redactable PII" : joined
        let prefix = String(
            localized: "privacy.error.scrubLeaked.prefix",
            bundle: .module
        )
        let suffix = String(
            localized: "privacy.error.scrubLeaked.suffix",
            bundle: .module
        )
        return "\(prefix) \(label) \(suffix)"
    }

    /// "1 phone number" / "2 phone numbers" — localized via a key
    /// shaped like `privacy.error.scrubLeaked.phone %lld`, picked up
    /// by xcstrings as a plural-bearing string through Swift's
    /// `String(localized:)` interpolation API (the same pattern used
    /// for `privacy.preview.header %lld`).
    private static func localizedCount(_ count: Int, for category: EntityCategory) -> String {
        let rendered: String
        let keyPrefix: String
        switch category {
        case .phone:
            rendered = String(
                localized: "privacy.error.scrubLeaked.phone \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.phone"
        case .email:
            rendered = String(
                localized: "privacy.error.scrubLeaked.email \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.email"
        case .url:
            rendered = String(
                localized: "privacy.error.scrubLeaked.url \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.url"
        case .accountNumber:
            rendered = String(
                localized: "privacy.error.scrubLeaked.accountNumber \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.accountNumber"
        case .address:
            rendered = String(
                localized: "privacy.error.scrubLeaked.address \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.address"
        case .person:
            rendered = String(
                localized: "privacy.error.scrubLeaked.person \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.person"
        case .date:
            rendered = String(
                localized: "privacy.error.scrubLeaked.date \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.date"
        case .secret:
            rendered = String(
                localized: "privacy.error.scrubLeaked.secret \(count)",
                bundle: .module
            )
            keyPrefix = "privacy.error.scrubLeaked.secret"
        }

        if renderedLooksUnresolved(rendered, keyPrefix: keyPrefix) {
            return "\(count) \(category.localizedName)"
        }
        return rendered
    }

    private static func renderedLooksUnresolved(_ rendered: String, keyPrefix: String) -> Bool {
        rendered == keyPrefix || rendered.hasPrefix("\(keyPrefix) ")
    }

    /// English-style join: "a, b and c". Localization of the
    /// conjunction is folded into the suffix string so we don't have
    /// to chase the Oxford-comma debate per language.
    private static func joinWithAnd(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2:
            return "\(parts[0]) "
                + String(
                    localized: "privacy.error.scrubLeaked.conjunction",
                    bundle: .module
                ) + " \(parts[1])"
        default:
            let head = parts.dropLast().joined(separator: ", ")
            let tail = parts.last!
            let conj = String(
                localized: "privacy.error.scrubLeaked.conjunction",
                bundle: .module
            )
            return "\(head) \(conj) \(tail)"
        }
    }
}

enum PrivacyFilterPipeline {
    /// Outbound scrub. Returns the original messages + `nil` map when
    /// the filter is disabled, when the model isn't loaded, or when a
    /// detection error fires; otherwise returns the substituted
    /// messages plus the map (so streaming + parse-response paths can
    /// unscrub the replies).
    ///
    /// Throws `PrivacyFilterPipelineError.reviewCanceled` when the
    /// user dismisses the redaction review sheet. Callers must catch
    /// this and abort the send.
    static func applyOutbound(
        messages: [ChatMessage],
        sessionId: String?,
        providerId: UUID
    ) async throws -> (messages: [ChatMessage], map: RedactionMap?) {
        let config = PrivacyFilterStore.snapshot()
        guard config.isEnabled(forProviderId: providerId) else {
            // Distinguish master-off vs per-provider-off so users can
            // tell which switch needs flipping from the log alone.
            // Use `print` (not debugLog) so the line surfaces in the
            // same stdout stream as the rest of the chat pipeline —
            // debugLog goes to /tmp/osaurus_debug.log which is easy to
            // miss when chasing a "filter isn't running" report.
            let providerOverride = config.providerOverrides[providerId.uuidString]
            print(
                "[PrivacyFilter] Bypass: filter disabled. master=\(config.enabled) provider=\(providerId.uuidString) providerOverride=\(providerOverride.map(String.init(describing:)) ?? "nil")"
            )
            return (messages, nil)
        }
        // Decouple the on-device AI model from the deterministic regex
        // layer. When the user has AI detection OFF we never load the
        // bundle and never fail-closed on a missing model — the regex
        // layer (built-ins / presets / custom rules) runs standalone,
        // so the filter is fully usable without the ~2.8 GB download.
        let useModel = config.aiDetectionEnabled
        let backend = config.aiDetectionBackend
        if useModel {
            // Warm the configured backend, bounded to a single lazy-load
            // attempt per call so a corrupt bundle can't trap every
            // outbound request in a load loop.
            var ready = false
            var loadError: String?
            switch backend {
            case .openai:
                // PrivacyFilterEngine is @MainActor; the await hops to main
                // for one property read + one detect() per outbound call.
                var isLoaded = await PrivacyFilterEngine.shared.isLoaded
                if !isLoaded {
                    let bundleDir = PrivacyFilterModelBundle.directoryURL()
                    if PrivacyFilterModelBundle.exists(at: bundleDir) {
                        do {
                            try await PrivacyFilterEngine.shared.loadIfNeeded(bundle: bundleDir)
                            isLoaded = await PrivacyFilterEngine.shared.isLoaded
                        } catch {
                            loadError = error.localizedDescription
                        }
                    } else {
                        loadError = "model bundle missing at \(bundleDir.path)"
                    }
                }
                ready = isLoaded
            case .rampart:
                if RampartModelManager.bundleExists() {
                    do {
                        try await RampartModelManager.shared.loadIfNeeded()
                        ready = true
                    } catch {
                        loadError = error.localizedDescription
                    }
                } else {
                    loadError = "rampart model bundle missing"
                }
            }
            // Fail-CLOSED: the user enabled AI detection expecting their
            // PII to be scrubbed before reaching cloud providers. If we
            // can't actually run the model, blocking the send (with an
            // explanation) is the safer default than silently sending
            // raw text.
            guard ready else {
                let detail = loadError ?? "engine not loaded"
                print("[PrivacyFilter] BLOCKING send: \(detail).")
                throw PrivacyFilterPipelineError.engineUnavailable(detail)
            }
            print(
                "[PrivacyFilter] Outbound: filter ENABLED (AI [\(backend.rawValue)] + regex) for provider \(providerId.uuidString); running detection."
            )
        } else {
            print(
                "[PrivacyFilter] Outbound: filter ENABLED (regex-only, AI detection off) for provider \(providerId.uuidString); running detection."
            )
        }

        // Build the effective regex rule set ONCE per pipeline call.
        // This snapshot drives both the detection pass below and the
        // post-scrub invariant — using the same ruleset on both ends
        // means a user toggling off, say, the phone built-in turns off
        // its detection AND its leak check symmetrically (consistent
        // with the documented behaviour in settings).
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)

        let sid = sessionId ?? Self.fallbackSessionId(for: messages)
        let map = await SessionRedactionStore.shared.getOrCreate(sid, conversationID: UUID())

        // Per-message detection scope: ONLY the latest user turn (plus
        // any messages following it) gets classified. Earlier turns
        // have already passed through detect → review on a prior call,
        // and their originals live in the per-session `RedactionMap`.
        // Re-classifying the entire history on every send was the
        // dominant latency cost — at 20 turns it ran the MoE 20× per
        // request for zero new information. The `applyingScrub` pass
        // below still substitutes across the whole message array using
        // the cumulative map, so prior turns continue to ship scrubbed.
        let segments = messages.latestUserTurnSegments()
        if segments.isEmpty {
            return (messages, map)
        }

        // Snapshot the map BEFORE detection. The originals set
        // partitions new (needs review) from previously-approved
        // (auto-approved against this turn's text). The counters
        // snapshot lets the cancel branch below rewind indices so a
        // retry on the same originals reuses the same placeholders
        // the user just saw — counters stay monotonic across
        // APPROVED sends, only canceled detections rewind.
        let preExistingSnapshot = await map.snapshot()
        let preExistingOriginals: Set<String> = Set(preExistingSnapshot.map(\.1))
        let preDetectionCounters = await map.counterSnapshot

        var detections: [DetectedEntity] = []
        for segment in segments {
            if segment.isEmpty { continue }
            do {
                let segmentDetections = try await PrivacyFilterEngine.shared.detect(
                    in: segment,
                    map: map,
                    skipCodeBlocks: config.skipCodeBlocks,
                    ruleset: ruleset,
                    useModel: useModel,
                    backend: backend
                )
                // Stamp the source segment onto every detection
                // before append so the review sheet can render the
                // surrounding text. Engine returns the entity with
                // `containingText == nil`; this rewrap is cheap
                // (struct copy with one string ref) and keeps the
                // engine API segment-agnostic.
                let stamped = segmentDetections.map { $0.withContainingText(segment) }
                detections.append(contentsOf: stamped)
            } catch {
                // Fail-CLOSED on detection failure too — the user
                // enabled the filter expecting protection; a model
                // crash mid-detection isn't a license to send raw PII.
                let detail = error.localizedDescription
                print("[PrivacyFilter] BLOCKING send: detection threw on segment (\(detail)).")
                throw PrivacyFilterPipelineError.engineUnavailable("detection failed: \(detail)")
            }
        }

        // Deduplicate by original string so the review sheet doesn't
        // show "Alice" twice when the user mentions it across two
        // messages — the placeholder is already idempotent in the map.
        var seen: Set<String> = []
        detections = detections.filter { entity in
            seen.insert(entity.original).inserted
        }

        // Partition: originals already minted on a prior turn (the
        // user reviewed them then) are silently re-approved this
        // turn. Only fresh originals reach the review sheet.
        var newDetections: [DetectedEntity] = []
        var carryOverCount = 0
        for entity in detections {
            if preExistingOriginals.contains(entity.original) {
                carryOverCount += 1
            } else {
                newDetections.append(entity)
            }
        }

        // Log per-category counts — never the original strings. The
        // whole point of the filter is to keep PII out of cloud logs,
        // and our own stdout is the easiest spot to forget about.
        let categoryCounts = Dictionary(grouping: newDetections, by: \.category)
            .mapValues(\.count)
            .map { "\($0.key.rawValue):\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        print(
            "[PrivacyFilter] Detection complete: \(newDetections.count) new entities (+\(carryOverCount) carried over) across \(segments.count) segments [\(categoryCounts)]"
        )

        // Materialise carry-over entries as auto-approved entities so
        // they get substituted by `applyingScrub` regardless of which
        // message in the history they appear in.
        let carryOverApproved: [DetectedEntity] = preExistingSnapshot.map { (placeholder, original) in
            DetectedEntity(
                category: placeholder.category,
                original: original,
                range: original.startIndex ..< original.startIndex,
                placeholder: placeholder,
                approved: true,
                containingText: nil
            )
        }

        guard !newDetections.isEmpty else {
            // No new originals this turn. Carry-over substitutions
            // still need to run so prior-turn PII gets scrubbed in
            // the message history we hand to the cloud.
            if carryOverApproved.isEmpty {
                return (messages, map)
            }
            let scrubbedHistory = messages.applyingScrub(approved: carryOverApproved)
            return (scrubbedHistory, map)
        }

        // Hand only the newly-detected entities to the review service.
        // When a UI presenter is registered + the session hasn't
        // opted into auto-approve, this suspends until the user
        // confirms. The background-caller path (HTTP API, plugin
        // agents) auto-approves so non-interactive callers don't
        // deadlock.
        let outcome = await PrivacyReviewService.shared.review(
            detections: newDetections,
            sessionId: sid
        )
        let approvedFromReview: [DetectedEntity]
        switch outcome {
        case .approved(let entities):
            approvedFromReview = entities
        case .canceled:
            // User cancelled the send (Cancel button, sheet
            // dismissed, or the awaiting Task was cancelled by the
            // Stop button). `RemoteProviderService` aborts without
            // firing HTTP; the chat layer maps this back to a UI
            // cancel (remove turns, restore draft) — see
            // `ChatView.send` cancel handling.
            //
            // Before throwing, undo the side effects of detection.
            // It already interned every `newDetections` original
            // into the per-session map; without rollback the next
            // send sees them in the carry-over set and skips the
            // dialog entirely. Counter rewind is safe — the
            // placeholders never left this map.
            let freshOriginals = Set(newDetections.map(\.original))
            await map.rollbackToSnapshot(
                removingOriginals: freshOriginals,
                counters: preDetectionCounters
            )
            throw PrivacyFilterPipelineError.reviewCanceled
        }

        // Final substitution list = this turn's approved entities
        // PLUS every previously-approved (carry-over) entity. Prior
        // approvals always count: the user already reviewed them once,
        // so we don't ask again on every send, and we DON'T let a
        // user un-tick this turn cause those values to ship raw.
        let approved = approvedFromReview + carryOverApproved
        let approvedCount = approved.filter { $0.approved }.count
        let skippedCount = approvedFromReview.count - approvedFromReview.filter { $0.approved }.count
        print("[PrivacyFilter] Review outcome: \(approvedCount) approved, \(skippedCount) skipped")

        let scrubbed = messages.applyingScrub(approved: approved)

        // Substitution sanity check. If the user approved entities but
        // not a single message field actually changed, something is
        // wrong with the scrub wiring (entity.original not matching
        // the wire text, codepoint normalization mismatch, etc.). Fail-
        // CLOSED rather than ship the original raw text and pretend
        // we redacted. The thrown error surfaces to the chat layer
        // as a non-generic message the user can act on.
        let diff = diffMessages(before: messages, after: scrubbed)
        if approvedCount > 0 {
            print(
                "[PrivacyFilter] Scrub applied: approved=\(approvedCount) changedFields=\(diff.changedCount)/\(messages.count)"
            )
            if diff.changedCount == 0 {
                let originals =
                    approved
                    .filter { $0.approved }
                    .map { "\($0.category.rawValue):\($0.placeholder.token)" }
                    .sorted()
                    .joined(separator: ", ")
                print(
                    "[PrivacyFilter] SCRUB NO-OP detected: \(approvedCount) approved entities ([\(originals)]) produced zero substitutions. Blocking send."
                )
                throw PrivacyFilterPipelineError.scrubNoOp(approvedCount: approvedCount)
            }
        }

        // Post-scrub invariant. The classifier + review path is
        // probabilistic — the model can miss PII, the user can
        // mistakenly untick a row, substitution can fail on weird
        // unicode. The regex layer is deterministic, so we use it as
        // a final gate: re-scan every scrubbable field on the
        // SCRUBBED messages with the SAME ruleset, and if any built-
        // in / preset / custom rule still matches, block the send.
        //
        // We intentionally re-run against `scrubbed`, not `messages`,
        // so we see what would actually go out on the wire (post
        // placeholder substitution). The matched values are NEVER
        // logged or echoed — only category counts surface to the
        // user, and even those go through localized plural strings.
        //
        // Originals the user EXPLICITLY skipped in the review sheet
        // are excluded from the leak count — they tripped the regex
        // by definition (they were in the detection list), and
        // counting them again would block the send right after the
        // user told us to let them through.
        let skippedOriginals: Set<String> = Set(
            approvedFromReview
                .filter { !$0.approved }
                .map(\.original)
        )
        let leaks = Self.scanForLeaks(
            in: scrubbed,
            ruleset: ruleset,
            ignoreOriginals: skippedOriginals,
            dirtyIndices: diff.dirtyIndices
        )

        // Per-original assertion: every APPROVED entity should be
        // absent from the scrubbed wire payload. Regex-backed
        // categories are covered by the `leaks` scan above, but
        // model-only categories (person, address, date, secret)
        // never reach the regex detector — a substitution mismatch
        // (case folding, unicode normalisation, partial overlap
        // with a longer match) would silently send the raw original.
        // We catch that here and report it as a leak in the entity's
        // category so the chat layer surfaces the same blocking
        // error users see for regex leaks.
        let approvedOriginals: [DetectedEntity] = approved.filter { $0.approved }
        if !approvedOriginals.isEmpty {
            var mlLeaks: [EntityCategory: Int] = [:]
            let scrubbedTexts = scrubbed.scrubbableTexts()
            for entity in approvedOriginals {
                let needle = entity.original
                if needle.isEmpty { continue }
                for text in scrubbedTexts where text.contains(needle) {
                    mlLeaks[entity.category, default: 0] += 1
                    break
                }
            }
            if !mlLeaks.isEmpty {
                let summary =
                    mlLeaks
                    .map { "\($0.key.rawValue):\($0.value)" }
                    .sorted()
                    .joined(separator: ", ")
                print(
                    "[PrivacyFilter] APPROVED ORIGINAL FOUND IN SCRUBBED PAYLOAD — substitution failed, blocking send. counts=[\(summary)]"
                )
                throw PrivacyFilterPipelineError.scrubLeaked(categoryCounts: mlLeaks)
            }
        }
        if !leaks.isEmpty {
            let summary =
                leaks
                .map { "\($0.key.rawValue):\($0.value)" }
                .sorted()
                .joined(separator: ", ")
            print("[PrivacyFilter] POST-SCRUB INVARIANT TRIPPED — blocking send. counts=[\(summary)]")
            throw PrivacyFilterPipelineError.scrubLeaked(categoryCounts: leaks)
        }

        // Tell the chat layer which (original, placeholder) pairs
        // shipped on this turn so it can fold them into its session-
        // scoped highlight dict. The chat UI then renders matching
        // spans with an inline accent underline + hover popover. We
        // only post when at least one entity made it past the user's
        // review — purely-skipped turns have nothing to highlight.
        // Posted AFTER the post-scrub invariant so a blocked send
        // never decorates a bubble whose text actually leaked.
        //
        // Payload is in-process only; we never serialize it to disk
        // or include it in remote requests. The originals are PII —
        // by the time they reach the chat-window observer they're
        // already living in the chat's `ChatTurn.content` anyway, so
        // there's no new exposure surface.
        if approvedCount > 0 {
            let pairs: [[String: String]] = approved.compactMap { entity in
                guard entity.approved, !entity.original.isEmpty else { return nil }
                return [
                    "original": entity.original,
                    "placeholder": entity.placeholder.token,
                ]
            }
            NotificationCenter.default.post(
                name: .privacyFilterRedactionsApproved,
                object: nil,
                userInfo: [
                    "sessionId": sid,
                    "approvedCount": approvedCount,
                    "redactions": pairs,
                ]
            )
        }

        return (scrubbed, map)
    }

    /// Run the active regex ruleset across every scrubbable field of
    /// `messages` and bucket any matches by category. Empty dict means
    /// "no leaks detected". Callers map this into
    /// `PrivacyFilterPipelineError.scrubLeaked` when non-empty.
    ///
    /// `ignoreOriginals` carries the verbatim strings the user
    /// explicitly skipped in the review sheet — counting them as
    /// leaks would block the send right after the user told us to let
    /// them through. This is the M5 fix; it preserves the safety of
    /// the invariant for *unintended* leaks (the regex caught
    /// something the user never saw) while honouring explicit skips.
    ///
    /// `dirtyIndices` is the H6 optimisation: when non-nil, only
    /// those message indices (i.e. messages whose scrubbable fields
    /// actually changed in this pipeline call) get re-scanned.
    /// Earlier turns either shipped on a prior call (vetted then) or
    /// were untouched by `applyingScrub` (no new text), so re-scanning
    /// them is pure cost. Pass `nil` to scan the whole history (used
    /// by tests and the lower-priority callers).
    static func scanForLeaks(
        in messages: [ChatMessage],
        ruleset: RegexEntityDetector.EffectiveRuleSet,
        ignoreOriginals: Set<String> = [],
        dirtyIndices: Set<Int>? = nil
    ) -> [EntityCategory: Int] {
        var counts: [EntityCategory: Int] = [:]
        let scoped: [ChatMessage]
        if let dirtyIndices, !dirtyIndices.isEmpty {
            scoped = messages.enumerated()
                .filter { dirtyIndices.contains($0.offset) }
                .map(\.element)
        } else if dirtyIndices != nil {
            // Explicit empty set: nothing changed → nothing to scan.
            return [:]
        } else {
            scoped = messages
        }
        for text in scoped.scrubbableTexts() {
            if text.isEmpty { continue }
            let matches = RegexEntityDetector.detect(in: text, ruleset: ruleset)
            for match in matches {
                if ignoreOriginals.contains(match.original) { continue }
                counts[match.category, default: 0] += 1
            }
        }
        return counts
    }

    /// Compare scrubbable fields across two parallel message arrays
    /// and return both the count of changed messages and the indices
    /// (relative to `after`) that changed. Mismatched lengths fall
    /// back to "every index dirty" with a count of `max(before, after)`
    /// so the caller's no-op detection still triggers on the
    /// suspicious case AND the leak scan won't accidentally treat the
    /// shorter array as fully clean.
    private static func diffMessages(
        before: [ChatMessage],
        after: [ChatMessage]
    ) -> (changedCount: Int, dirtyIndices: Set<Int>) {
        guard before.count == after.count else {
            let n = max(before.count, after.count)
            return (n, Set(0 ..< n))
        }
        var changedCount = 0
        var dirty: Set<Int> = []
        for (idx, pair) in zip(before, after).enumerated() {
            let (a, b) = pair
            if a.content != b.content {
                changedCount += 1
                dirty.insert(idx)
                continue
            }
            if a.reasoning_content != b.reasoning_content {
                changedCount += 1
                dirty.insert(idx)
                continue
            }
            let aArgs = (a.tool_calls ?? []).map(\.function.arguments).joined()
            let bArgs = (b.tool_calls ?? []).map(\.function.arguments).joined()
            if aArgs != bArgs {
                changedCount += 1
                dirty.insert(idx)
                continue
            }
        }
        return (changedCount, dirty)
    }

    /// Wrap a streaming AsyncThrowingStream so each yielded chunk is
    /// passed through a `StreamingUnscrubber` before reaching the
    /// caller. `map == nil` is a pass-through (zero allocation overhead).
    ///
    /// Provider responses interleave three kinds of deltas, all sharing
    /// the U+FFFE in-band sentinel framing defined in `ModelService`:
    ///   • plain content chunks (no sentinel prefix)
    ///   • reasoning deltas prefixed by `\u{FFFE}reasoning:<payload>`
    ///   • bookkeeping sentinels (`\u{FFFE}done:`, `\u{FFFE}stats:`, …)
    ///
    /// A single `StreamingUnscrubber` buffer can't handle all three: a
    /// placeholder split across deltas (`[PHO` then `NE_1]`) only matches
    /// correctly when both fragments belong to the same logical stream.
    /// If we let reasoning + content share a buffer we end up
    /// concatenating their sentinel-prefixed wire forms, which (a)
    /// breaks `[CATEGORY_N]` recognition because U+FFFE+ASCII text gets
    /// wedged between the brackets, and (b) corrupts the sentinel
    /// framing the chat view expects (so reasoning leaks into the
    /// visible message and the Thinking pill gets nothing). The fix is
    /// to maintain a per-rail unscrubber and to leave other sentinels
    /// (stats / done / tool) untouched.
    static func wrapInboundStream(
        _ upstream: AsyncThrowingStream<String, Error>,
        map: RedactionMap?
    ) -> AsyncThrowingStream<String, Error> {
        guard let map else { return upstream }
        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                let contentUnscrubber = await StreamingUnscrubber.make(for: map)
                let reasoningUnscrubber = await StreamingUnscrubber.make(for: map)
                let reasoningPrefix = "\u{FFFE}reasoning:"
                let sentinelMarker = "\u{FFFE}"

                do {
                    for try await chunk in upstream {
                        if chunk.hasPrefix(reasoningPrefix) {
                            // Reasoning delta: strip prefix, unscrub
                            // payload through the reasoning-rail
                            // buffer (which can carry tokens across
                            // multiple reasoning deltas), re-encode.
                            let payload = String(chunk.dropFirst(reasoningPrefix.count))
                            let emitted = await reasoningUnscrubber.push(payload)
                            if !emitted.isEmpty {
                                continuation.yield(reasoningPrefix + emitted)
                            }
                        } else if chunk.hasPrefix(sentinelMarker) {
                            // Stats / done / tool sentinel — opaque to
                            // the unscrubber. Pass through verbatim;
                            // it never carries placeholder text.
                            continuation.yield(chunk)
                        } else {
                            let emitted = await contentUnscrubber.push(chunk)
                            if !emitted.isEmpty {
                                continuation.yield(emitted)
                            }
                        }
                    }
                    // Flush both rails. Reasoning gets re-prefixed so
                    // the chat view still routes it to the Thinking
                    // pill.
                    let reasoningTail = await reasoningUnscrubber.flush()
                    if !reasoningTail.isEmpty {
                        continuation.yield(reasoningPrefix + reasoningTail)
                    }
                    let contentTail = await contentUnscrubber.flush()
                    if !contentTail.isEmpty {
                        continuation.yield(contentTail)
                    }
                    continuation.finish()
                } catch {
                    let reasoningTail = await reasoningUnscrubber.flush()
                    if !reasoningTail.isEmpty {
                        continuation.yield(reasoningPrefix + reasoningTail)
                    }
                    let contentTail = await contentUnscrubber.flush()
                    if !contentTail.isEmpty {
                        continuation.yield(contentTail)
                    }
                    // Tool-call errors thrown mid-stream by
                    // `RemoteProviderService._streamRemote` carry the
                    // raw JSON args with `[CATEGORY_N]` placeholders
                    // still embedded — without this pass the local
                    // tool executes with `{"phone":"[PHONE_1]"}`
                    // instead of the real value. Unscrub before the
                    // consumer (Work loop / plugin host) sees them.
                    let unscrubbed = await Self.unscrubToolInvocationError(error, map: map)
                    continuation.finish(throwing: unscrubbed)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Replace placeholder tokens inside a `ServiceToolInvocation` or
    /// `ServiceToolInvocations` thrown mid-stream by the provider.
    /// Other error types pass through unchanged so the unscrubber stays
    /// transparent to the rest of the error taxonomy.
    private static func unscrubToolInvocationError(
        _ error: Error,
        map: RedactionMap
    ) async -> Error {
        if let single = error as? ServiceToolInvocation {
            let scrubbed = await replacePlaceholdersInJSON(single.jsonArguments, map: map)
            return ServiceToolInvocation(
                toolName: single.toolName,
                jsonArguments: scrubbed,
                toolCallId: single.toolCallId,
                geminiThoughtSignature: single.geminiThoughtSignature
            )
        }
        if let batch = error as? ServiceToolInvocations {
            var out: [ServiceToolInvocation] = []
            out.reserveCapacity(batch.invocations.count)
            for inv in batch.invocations {
                let scrubbed = await replacePlaceholdersInJSON(inv.jsonArguments, map: map)
                out.append(
                    ServiceToolInvocation(
                        toolName: inv.toolName,
                        jsonArguments: scrubbed,
                        toolCallId: inv.toolCallId,
                        geminiThoughtSignature: inv.geminiThoughtSignature
                    )
                )
            }
            return ServiceToolInvocations(invocations: out)
        }
        return error
    }

    /// One-shot unscrub for non-streaming responses and tool-call
    /// argument JSON. Mirrors the streaming path's tokenizer.
    static func unscrubInbound(
        content: String?,
        toolCalls: [ToolCall]?,
        map: RedactionMap?
    ) async -> (content: String?, toolCalls: [ToolCall]?) {
        guard let map else { return (content, toolCalls) }
        var resolvedContent = content
        if let raw = content {
            resolvedContent = await replacePlaceholders(in: raw, map: map)
        }
        var resolvedCalls = toolCalls
        if let calls = toolCalls {
            var out: [ToolCall] = []
            out.reserveCapacity(calls.count)
            for call in calls {
                let scrubbed = await replacePlaceholdersInJSON(
                    call.function.arguments,
                    map: map
                )
                out.append(
                    ToolCall(
                        id: call.id,
                        type: call.type,
                        function: ToolCallFunction(name: call.function.name, arguments: scrubbed),
                        geminiThoughtSignature: call.geminiThoughtSignature
                    )
                )
            }
            resolvedCalls = out
        }
        return (resolvedContent, resolvedCalls)
    }

    // MARK: - One-shot placeholder replacement

    /// Sweep `text` for `[CATEGORY_N]` tokens and replace each known
    /// one with its mapped original. Unknown tokens are left in place
    /// + logged once.
    private static func replacePlaceholders(in text: String, map: RedactionMap) async -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let openIdx = text.range(of: "[", range: cursor ..< text.endIndex) else {
                out.append(contentsOf: text[cursor...])
                break
            }
            out.append(contentsOf: text[cursor ..< openIdx.lowerBound])
            guard let closeIdx = text.range(of: "]", range: openIdx.upperBound ..< text.endIndex) else {
                out.append(contentsOf: text[openIdx.lowerBound...])
                break
            }
            let tokenRange = openIdx.lowerBound ..< closeIdx.upperBound
            let token = String(text[tokenRange])
            if let original = await map.resolve(token: token) {
                out.append(original)
            } else {
                out.append(token)
                if looksLikePlaceholder(token) {
                    debugLog("[PrivacyFilter] Unknown placeholder in response: \(token)")
                }
            }
            cursor = tokenRange.upperBound
        }
        return out
    }

    private static func replacePlaceholdersInJSON(_ raw: String, map: RedactionMap) async -> String {
        guard let data = raw.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        else {
            return await replacePlaceholders(in: raw, map: map)
        }
        let scrubbed = await scrubJSON(value, map: map)
        guard
            let outData = try? JSONSerialization.data(
                withJSONObject: scrubbed,
                options: [.fragmentsAllowed, .sortedKeys]
            )
        else {
            return await replacePlaceholders(in: raw, map: map)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private static func scrubJSON(_ value: Any, map: RedactionMap) async -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = await scrubJSON(v, map: map)
            }
            return out
        case let arr as [Any]:
            var out: [Any] = []
            out.reserveCapacity(arr.count)
            for item in arr {
                out.append(await scrubJSON(item, map: map))
            }
            return out
        case let str as String:
            return await replacePlaceholders(in: str, map: map)
        default:
            return value
        }
    }

    // MARK: - Helpers

    /// Build a session id when the caller didn't pass one (the HTTP
    /// API and headless plugin paths don't always set `session_id`).
    ///
    /// The earlier implementation hashed the first system + user
    /// message so two requests in the same conversation could share a
    /// `RedactionMap`. That worked for the chat UI but collided
    /// catastrophically on the HTTP API: two unrelated clients
    /// happening to send the same system prompt + greeting would
    /// share one map and have each other's PII resolve into their
    /// own placeholders on inbound unscrub.
    ///
    /// We now mint a fresh UUID per call. The trade-off: a
    /// non-`session_id`-carrying client loses placeholder stability
    /// across turns (each request gets a fresh map, so prior-turn
    /// placeholders won't resolve on a follow-up). That's the
    /// correct safety posture — silently sharing maps was a real
    /// privacy bug. Clients that need multi-turn redaction should
    /// pass `session_id` (or `parameters.sessionId`) explicitly.
    ///
    /// Package-internal (not `private`) so the H3 regression test
    /// can lock the "fresh UUID per call" contract directly. The
    /// function is a pure factory — no state, no side effects.
    static func fallbackSessionId(for messages: [ChatMessage]) -> String {
        return "pf-anon-\(UUID().uuidString)"
    }

    private static func looksLikePlaceholder(_ token: String) -> Bool {
        guard token.count >= 5,
            token.first == "[",
            token.last == "]"
        else { return false }
        let inner = token.dropFirst().dropLast()
        guard let us = inner.firstIndex(of: "_") else { return false }
        let prefix = inner[..<us]
        let suffix = inner[inner.index(after: us)...]
        guard !prefix.isEmpty, !suffix.isEmpty else { return false }
        for ch in prefix where !(ch.isASCII && ch.isUppercase) { return false }
        for ch in suffix where !(ch.isASCII && ch.isNumber) { return false }
        return true
    }
}
