// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsaurusCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "osaurus", targets: ["OsaurusCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(path: "../OsaurusRepository"),
    ],
    targets: [
        .executableTarget(
            name: "OsaurusCLI",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OsaurusRepository", package: "OsaurusRepository"),
            ],
            path: "."
        )
    ]
)
