// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusRepository",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusRepository", targets: ["OsaurusRepository"])
    ],
    dependencies: [
        .package(path: "../OsaurusNetworking")
    ],
    targets: [
        .target(
            name: "OsaurusRepository",
            dependencies: [
                .product(name: "OsaurusNetworking", package: "OsaurusNetworking")
            ],
            path: ".",
            exclude: ["Tests"]
        ),
        .testTarget(
            name: "OsaurusRepositoryTests",
            dependencies: ["OsaurusRepository"],
            path: "Tests/OsaurusRepositoryTests"
        ),
    ]
)
