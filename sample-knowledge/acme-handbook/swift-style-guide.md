---
type: standard
title: Swift Style Guide
description: Acme engineering conventions for writing Swift code.
tags: [engineering, swift, standards]
---

# Swift Style Guide

These conventions keep Acme's Swift codebase consistent. Use this document to
test section-scoped reads — an agent should be able to pull just one heading.

## Naming

- Types are `UpperCamelCase`; properties and functions are `lowerCamelCase`.
- Booleans read as assertions: `isEnabled`, `hasChanges`, `shouldRetry`.
- Avoid abbreviations except well-known ones (`url`, `id`, `json`).

## Formatting

- Indent with 4 spaces, never tabs.
- Keep lines under 100 characters.
- One statement per line; no semicolons.

## Error handling

- Prefer `throws` over returning optional error flags.
- Never use `try!` in production code paths; handle or propagate the error.
- Log at the boundary where the error is handled, not where it is thrown.

## Concurrency

- Never block the main thread; move heavy work to a background task.
- Prefer `async`/`await` over completion handlers for new code.
- Guard shared mutable state with an actor.

## Testing

- Every bug fix ships with a regression test.
- Name tests by behavior, not by method: `refund_isDeniedAfterWindow`.
