// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusStatsPack",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusStatsPack", targets: ["OsaurusStatsPack"])
    ],
    dependencies: [
        .package(path: "../../OsaurusCore")
    ],
    targets: [
        .target(
            name: "OsaurusStatsPack",
            dependencies: [
                .product(name: "OsaurusCore", package: "OsaurusCore")
            ],
            path: "Sources/OsaurusStatsPack"
        ),
        .testTarget(
            name: "OsaurusStatsPackTests",
            dependencies: ["OsaurusStatsPack"],
            path: "Tests/OsaurusStatsPackTests"
        ),
    ]
)
