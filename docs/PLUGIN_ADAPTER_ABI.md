# Plugin Adapter ABI

Osaurus plugin format adapters are an in-process Swift v1 surface for file
formats that should live in plugin packs instead of core. The ABI is small by
design: an adapter declares a stable format identifier, optional leading-byte
detection patterns, a contained document open step, and a record streaming step.
XPC isolation, runtime dynamic loading, and sandbox policy negotiation are
deliberately outside v1.

## Registry Relationship

`FormatAdapterRegistry` and `DocumentFormatRegistry` are peer registries. The
existing `DocumentFormatRegistry` remains the route for core
`StructuredDocument` parsing, emitting, and chat attachment fallbacks, while
`FormatAdapterRegistry` is the route for plugin-pack record streaming and
byte-pattern detection. Neither registry calls the other in v1; callers choose
the registry that matches the data path they need, and code that supports both
structured documents and plugin records should query both explicitly at its
own boundary.

## Adapter Contract

Plugin packs register adapter factories at startup:

```swift
try FormatAdapterRegistry.shared.register(MyAdapter.self) {
    MyAdapter()
}
```

The registry is keyed by `FormatAdapter.formatIdentifier`, so duplicate
registration throws immediately. Identifiers should be stable lowercase names
such as `jsonl`, `sqlite`, or `csv-with-schema`.

Adapters are opened against a contained host-provided URL, not an arbitrary
source path. The returned `DocumentReference` contains user-safe identity and
metadata for the opened file; plugin code must not persist or expose physical
paths. After opening, callers ask the same adapter instance to stream `Record`
values into an `AsyncStream<Record>.Continuation`.

## Detection

`detectionBytePatterns` is for formats with reliable magic bytes. The registry
reads only the longest registered pattern length, capped by the caller's byte
limit, and matches patterns against the file prefix. Text formats such as CSV
may leave this list empty and rely on extension, MIME, or explicit user choice
at a higher layer.

## Out of Scope For v1

- XPC or out-of-process isolation.
- Runtime dynamic bundle loading.
- Plugin access to raw user-selected paths.
- Python, JVM, or new parser runtime dependencies.
