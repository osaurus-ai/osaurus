//
//  WireTransportProbe.swift
//  osaurus
//
//  Lock-protected sink that captures (a) the scrubbed HTTP request
//  body actually written to the network and (b) the raw inbound
//  bytes BEFORE the Privacy Filter's unscrubber runs. The chat
//  layer consults this after a remote send so Insights can show
//  "this is verbatim what the cloud saw / sent back" — not the
//  pre-scrub local copy.
//
//  Why a class + lock instead of an actor:
//    • URLSession callbacks deliver bytes on background queues
//      that aren't isolated to RemoteProviderService's actor. Using
//      an actor would require an `await` per chunk write, which we
//      explicitly do NOT want on the streaming hot path.
//    • OSAllocatedUnfairLock is used elsewhere in the codebase for
//      the same reason (see `sessionInvalidatedFlag` in
//      RemoteProviderService). Lock-based reads/writes are O(1)
//      and contention is effectively zero (one writer thread at
//      a time on a stream).
//
//  Probe lifecycle:
//    1. ChatEngine (for chatUI sends) creates a probe and sets it
//       on the `WireTransportProbe.current` task-local before calling
//       into the remote service. We avoid threading it through every
//       method signature so future cloud paths (e.g. Anthropic-only
//       extensions) pick it up automatically.
//    2. RemoteProviderService reads `WireTransportProbe.current` at
//       the point where it has `urlRequest.httpBody` (post-scrub
//       canonical JSON) and writes that data into the probe.
//    3. The streaming consumer wraps the inner byte stream and
//       feeds every chunk into the probe BEFORE the unscrubber
//       wrapper runs. That guarantees the captured bytes are
//       exactly what the network delivered.
//    4. ChatEngine reads `wireRequestBody` / `wireResponseBody` off
//       the probe before constructing the `RequestLog`.
//
//  We never write any of the probe state to disk on our own — only
//  InsightsService persists it (and only when the user has opened
//  the chat insights surface, which is gated by app preferences).
//

import Foundation
import os

/// Probe instance shared across a single remote send. Pass through
/// `WireTransportProbe.current` (Task-local) so we don't have to
/// modify every signature in the remote-provider stack. Lock-backed
/// so URLSession callback threads can update it without an actor
/// hop.
public final class WireTransportProbe: @unchecked Sendable {

    @TaskLocal
    public static var current: WireTransportProbe?

    /// `bodies.req` is set once when the URLRequest body is built
    /// (post-Privacy-Filter); `bodies.resp` is appended chunk-by-
    /// chunk on the streaming path or set in one shot on the
    /// non-streaming path. We keep the writeable state inside a
    /// single value-type so the lock has one contention surface
    /// instead of two.
    private struct Bodies {
        var req: Data?
        var resp: Data
        var truncated: Bool
    }

    /// Hard cap on captured response bytes. Streamed assistant
    /// outputs can easily run into MBs; Insights only ever shows
    /// the head + tail. This keeps memory bounded for users who
    /// open Insights mid-stream and then forget to close it.
    public static let maxResponseBytes: Int = 1_048_576  // 1 MiB

    private let bodies = OSAllocatedUnfairLock<Bodies>(
        initialState: Bodies(req: nil, resp: Data(), truncated: false)
    )

    public init() {}

    /// Record the post-scrub HTTP request body. Idempotent: only
    /// the first write wins (a request retry would otherwise stomp
    /// the original; we want the *first* attempt's body so the
    /// captured pair stays self-consistent).
    ///
    /// Capped at `maxResponseBytes` (1 MiB) so a paste-the-whole-
    /// novel request can't balloon process memory; the Insights UI
    /// only renders head/tail anyway, so the trimmed bytes carry
    /// the same diagnostic value.
    public func recordRequestBody(_ data: Data) {
        bodies.withLock { state in
            if state.req == nil {
                if data.count <= Self.maxResponseBytes {
                    state.req = data
                } else {
                    state.req = data.prefix(Self.maxResponseBytes)
                    state.truncated = true
                }
            }
        }
    }

    /// Append a chunk of raw inbound bytes. Called from inside the
    /// streaming tap BEFORE the unscrubber rewrites placeholders.
    /// Capped at `maxResponseBytes`; subsequent appends past the
    /// cap flip a `truncated` flag so the Insights UI can show "…
    /// truncated at 1 MiB".
    public func appendResponseChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        bodies.withLock { state in
            let remaining = Self.maxResponseBytes - state.resp.count
            if remaining <= 0 {
                state.truncated = true
                return
            }
            if data.count <= remaining {
                state.resp.append(data)
            } else {
                state.resp.append(data.prefix(remaining))
                state.truncated = true
            }
        }
    }

    /// Replace the entire response body. Used by the non-streaming
    /// path (`data(for:)`), which delivers one buffer instead of
    /// chunks. Trims to `maxResponseBytes` with the same truncation
    /// flag the streaming path sets.
    public func replaceResponseBody(_ data: Data) {
        bodies.withLock { state in
            if data.count <= Self.maxResponseBytes {
                state.resp = data
                state.truncated = false
            } else {
                state.resp = data.prefix(Self.maxResponseBytes)
                state.truncated = true
            }
        }
    }

    /// Snapshot the captured bodies. Returns the post-scrub
    /// request body (or nil if the probe was created but the
    /// request was never sent — e.g. a privacy-cancel before
    /// URLSession.dataTask started) and the response bytes (may be
    /// empty for a non-stream that failed).
    public func snapshot() -> (request: Data?, response: Data, truncated: Bool) {
        bodies.withLock { state in
            (state.req, state.resp, state.truncated)
        }
    }
}
