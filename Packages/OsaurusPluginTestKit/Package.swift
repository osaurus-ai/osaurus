// swift-tools-version: 6.2
import PackageDescription

// OsaurusPluginTestKit
//
// External-facing test kit for Osaurus plugin authors. Provides a Swift
// mirror of the v4 `osr_host_api` C struct and helper recorders so a
// plugin's `Tests/` target can drive `osaurus_plugin_entry_v2(host)`
// against a controllable mock host without depending on OsaurusCore (or
// the Osaurus app itself).
//
// Authors add this as a test-target dependency in their plugin's own
// `Package.swift`:
//
//     .package(url: "https://github.com/osaurus-ai/osaurus", from: "0.18.0"),
//
//     .testTarget(
//         name: "MyPluginTests",
//         dependencies: [
//             .product(name: "OsaurusPluginTestKit", package: "osaurus")
//         ]
//     )
//
// See the package README for the recipe.

let package = Package(
    name: "OsaurusPluginTestKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OsaurusPluginTestKit", targets: ["OsaurusPluginTestKit"])
    ],
    targets: [
        .target(
            name: "OsaurusPluginTestKit",
            path: "Sources/OsaurusPluginTestKit"
        ),
        .testTarget(
            name: "OsaurusPluginTestKitTests",
            dependencies: ["OsaurusPluginTestKit"],
            path: "Tests/OsaurusPluginTestKitTests"
        ),
    ]
)
