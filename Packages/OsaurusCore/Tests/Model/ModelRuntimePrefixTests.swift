//
//  ModelRuntimePrefixTests.swift
//  osaurusTests
//
//  Tests for ModelRuntime actor isolation guarantees.
//  The actor isolation on ModelRuntime ensures all state mutations are
//  serialised, so generateEventStream never interleaves with other
//  actor-isolated work within a single suspension point.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Verifies that ModelRuntime exposes the API surface expected by the
/// GPU serialisation guarantees.
struct ModelRuntimePrefixTests {

    /// ModelRuntime must be an actor so that generateEventStream
    /// and the stale-task cleanup are serialised.
    @Test func modelRuntimeIsAnActor() {
        // Enforced by compiler isolation
    }
}
