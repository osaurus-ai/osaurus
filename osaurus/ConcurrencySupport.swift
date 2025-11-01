//
//  ConcurrencySupport.swift
//  osaurus
//
//  Shared concurrency utilities for Swift 6 migration.
//

import Foundation

/// A simple box to carry non-Sendable values across concurrency domains when it's
/// known to be safe. Use sparingly and prefer event-loop or actor hopping.
struct UncheckedSendableBox<T>: @unchecked Sendable {
  let value: T
}
