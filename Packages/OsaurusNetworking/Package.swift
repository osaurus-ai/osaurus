// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusNetworking",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusNetworking", targets: ["OsaurusNetworking"])
    ],
    targets: [
        .target(
            name: "OsaurusNetworking",
            path: "Sources"
        ),
        .testTarget(
            name: "OsaurusNetworkingTests",
            dependencies: ["OsaurusNetworking"]
        ),
    ]
)
