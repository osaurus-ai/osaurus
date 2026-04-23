// swift-tools-version: 6.2
//
// OsaurusEvals
//
// Standalone package for catalog-driven behaviour / integration tests
// that hit a real model (Foundation, MLX, remote provider). NOT part of
// CI — `swift test` from `Packages/OsaurusCore` does not touch this
// package, and the CLI is invoked manually for local tuning + new-model
// triage.
//
// See `README.md` for usage. The runner sets the core model via
// `ChatConfigurationStore` per-run, so `--model` only affects the eval
// process and never persists across runs (see `ModelOverride.swift`).
//
import PackageDescription

let package = Package(
    name: "OsaurusEvals",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusEvalsKit", targets: ["OsaurusEvalsKit"]),
        .executable(name: "osaurus-evals", targets: ["OsaurusEvalsCLI"]),
    ],
    dependencies: [
        .package(path: "../OsaurusCore")
    ],
    targets: [
        .target(
            name: "OsaurusEvalsKit",
            dependencies: [
                .product(name: "OsaurusCore", package: "OsaurusCore")
            ],
            path: "Sources/OsaurusEvalsKit"
        ),
        .executableTarget(
            name: "OsaurusEvalsCLI",
            dependencies: [
                "OsaurusEvalsKit"
            ],
            path: "Sources/OsaurusEvalsCLI"
        ),
    ]
)
