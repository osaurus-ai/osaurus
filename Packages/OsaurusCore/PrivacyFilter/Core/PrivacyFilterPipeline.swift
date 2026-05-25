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
//  Fail-open on read paths and fail-closed on write paths: if the
//  engine can't load, `applyOutbound` returns the original messages
//  and a nil map (no scrubbing today, but we also won't try to apply a
//  partial scrub). The settings UI guards against ever flipping the
//  master toggle on while the engine is unloaded, so this branch
//  should only fire on transient errors.
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
        switch category {
        case .phone:
            return String(localized: "privacy.error.scrubLeaked.phone \(count)", bundle: .module)
        case .email:
            return String(localized: "privacy.error.scrubLeaked.email \(count)", bundle: .module)
        case .url:
            return String(localized: "privacy.error.scrubLeaked.url \(count)", bundle: .module)
        case .accountNumber:
            return String(localized: "privacy.error.scrubLeaked.accountNumber \(count)", bundle: .module)
        case .address:
            return String(localized: "privacy.error.scrubLeaked.address \(count)", bundle: .module)
        case .person:
            return String(localized: "privacy.error.scrubLeaked.person \(count)", bundle: .module)
        case .date:
            return String(localized: "privacy.error.scrubLeaked.date \(count)", bundle: .module)
        case .secret:
            return String(localized: "privacy.error.scrubLeaked.secret \(count)", bundle: .module)
        }
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
        // PrivacyFilterEngine is @MainActor; the await hops to main
        // for one property read + one detect() per outbound call.
        var isLoaded = await PrivacyFilterEngine.shared.isLoaded
        var loadError: String?
        if !isLoaded {
            // Engine not warm yet. If the bundle is on disk we try one
            // synchronous lazy load here so the user doesn't see a
            // bypass on the first chat after launch. We bound this to
            // a single attempt per call so a corrupt bundle can't trap
            // every outbound request in a load loop.
            let bundleDir = PrivacyFilterModelBundle.directoryURL()
            if PrivacyFilterModelBundle.exists(at: bundleDir) {
                do {
                    try await PrivacyFilterEngine.shared.loadIfNeeded(bundle: bundleDir)
                    isLoaded = await PrivacyFilterEngine.shared.isLoaded
                    if isLoaded {
                        print("[PrivacyFilter] Engine lazy-loaded for first outbound call.")
                    }
                } catch {
                    loadError = error.localizedDescription
                    print("[PrivacyFilter] Lazy load failed: \(error.localizedDescription).")
                }
            } else {
                loadError = "model bundle missing at \(bundleDir.path)"
            }
        }
        // Fail-CLOSED: the user enabled this feature expecting their
        // PII to be scrubbed before reaching cloud providers. If we
        // can't actually run detection, blocking the send (with an
        // explanation) is the safer default than silently sending
        // raw text. Previously this branch returned `(messages, nil)`
        // which the chat layer rendered as a successful send.
        guard isLoaded else {
            let detail = loadError ?? "engine not loaded"
            print("[PrivacyFilter] BLOCKING send: \(detail).")
            throw PrivacyFilterPipelineError.engineUnavailable(detail)
        }
        print("[PrivacyFilter] Outbound: filter ENABLED for provider \(providerId.uuidString); running detection.")

        // Build the effective regex rule set ONCE per pipeline call.
        // This snapshot drives both the detection pass below and the
        // post-scrub invariant — using the same ruleset on both ends
        // means a user toggling off, say, the phone built-in turns off
        // its detection AND its leak check symmetrically (consistent
        // with the documented behaviour in settings).
        let ruleset = RegexEntityDetector.EffectiveRuleSet.build(from: config)

        let sid = sessionId ?? Self.fallbackSessionId(for: messages)
        let map = await SessionRedactionStore.shared.getOrCreate(sid, conversationID: UUID())

        // Per-message detection: feeding the classifier one user
        // utterance at a time matches its training distribution and
        // avoids the system-prompt + user-message concat that
        // historically produced all-`O` argmax. The downstream
        // `applyingScrub` step does string-match substitution, so it
        // doesn't care that the detected ranges are local to each
        // segment.
        let segments = messages.scrubbableTexts()
        if segments.isEmpty {
            return (messages, map)
        }

        var detections: [DetectedEntity] = []
        for segment in segments {
            if segment.isEmpty { continue }
            do {
                let segmentDetections = try await PrivacyFilterEngine.shared.detect(
                    in: segment,
                    map: map,
                    skipCodeBlocks: config.skipCodeBlocks,
                    ruleset: ruleset
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

        // Log per-category counts — never the original strings. The
        // whole point of the filter is to keep PII out of cloud logs,
        // and our own stdout is the easiest spot to forget about.
        let categoryCounts = Dictionary(grouping: detections, by: \.category)
            .mapValues(\.count)
            .map { "\($0.key.rawValue):\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        print(
            "[PrivacyFilter] Detection complete: \(detections.count) entities across \(segments.count) segments [\(categoryCounts)]"
        )

        guard !detections.isEmpty else {
            // Nothing detected — return originals with the map so the
            // streaming unscrubber still wraps the response (cheap, and
            // means a later turn that DOES detect entities can still
            // unscrub stray placeholders from this turn).
            return (messages, map)
        }

        // Hand the detections to the review service. When a UI
        // presenter is registered + the session hasn't opted into
        // auto-approve, this suspends until the user confirms. The
        // background-caller path (HTTP API, plugin agents) auto-
        // approves so non-interactive callers don't deadlock.
        let outcome = await PrivacyReviewService.shared.review(
            detections: detections,
            sessionId: sid
        )
        let approved: [DetectedEntity]
        switch outcome {
        case .approved(let entities):
            approved = entities
        case .canceled:
            // User decided not to send (explicit Cancel button, sheet
            // dismissed without action, or the awaiting Task was
            // cancelled e.g. by the Stop button). Throw so the
            // RemoteProviderService can abort cleanly without firing
            // HTTP. The chat layer maps this back to a UI cancel
            // (remove turns, restore draft) instead of an error
            // bubble — see `ChatView.send` cancel handling.
            throw PrivacyFilterPipelineError.reviewCanceled
        }

        let approvedCount = approved.filter { $0.approved }.count
        let skippedCount = approved.count - approvedCount
        print("[PrivacyFilter] Review outcome: \(approvedCount) approved, \(skippedCount) skipped")

        let scrubbed = messages.applyingScrub(approved: approved)

        // Substitution sanity check. If the user approved entities but
        // not a single message field actually changed, something is
        // wrong with the scrub wiring (entity.original not matching
        // the wire text, codepoint normalization mismatch, etc.). Fail-
        // CLOSED rather than ship the original raw text and pretend
        // we redacted. The thrown error surfaces to the chat layer
        // as a non-generic message the user can act on.
        if approvedCount > 0 {
            let changedFields = countChangedFields(before: messages, after: scrubbed)
            print(
                "[PrivacyFilter] Scrub applied: approved=\(approvedCount) changedFields=\(changedFields)/\(messages.count)"
            )
            if changedFields == 0 {
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
        let leaks = Self.scanForLeaks(in: scrubbed, ruleset: ruleset)
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
    static func scanForLeaks(
        in messages: [ChatMessage],
        ruleset: RegexEntityDetector.EffectiveRuleSet
    ) -> [EntityCategory: Int] {
        var counts: [EntityCategory: Int] = [:]
        for text in messages.scrubbableTexts() {
            if text.isEmpty { continue }
            let matches = RegexEntityDetector.detect(in: text, ruleset: ruleset)
            for match in matches {
                counts[match.category, default: 0] += 1
            }
        }
        return counts
    }

    /// Compare scrubbable fields across two parallel message arrays.
    /// Mismatched lengths return the larger count (best-effort) so the
    /// caller's no-op detection still triggers on the suspicious case.
    private static func countChangedFields(
        before: [ChatMessage],
        after: [ChatMessage]
    ) -> Int {
        guard before.count == after.count else {
            return max(before.count, after.count)
        }
        var changed = 0
        for (a, b) in zip(before, after) {
            if a.content != b.content { changed += 1; continue }
            if a.reasoning_content != b.reasoning_content { changed += 1; continue }
            // Tool-call arguments are a JSON blob; cheapest correct
            // check is the joined string of all arguments per call.
            let aArgs = (a.tool_calls ?? []).map(\.function.arguments).joined()
            let bArgs = (b.tool_calls ?? []).map(\.function.arguments).joined()
            if aArgs != bArgs { changed += 1; continue }
        }
        return changed
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
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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

    /// Build a stable session id when the caller didn't pass one (the
    /// HTTP API doesn't always set `session_id`). We hash the first
    /// system message + first user message so two requests in the same
    /// conversation map to the same key without bleeding maps across
    /// unrelated calls.
    private static func fallbackSessionId(for messages: [ChatMessage]) -> String {
        let first = messages.prefix(2).compactMap { $0.content }.joined(separator: "\u{001E}")
        if first.isEmpty {
            return "pf-anon-\(UUID().uuidString)"
        }
        var hasher = Hasher()
        hasher.combine(first)
        return "pf-anon-\(hasher.finalize())"
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
