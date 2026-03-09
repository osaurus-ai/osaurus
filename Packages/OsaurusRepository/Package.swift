// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusRepository",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusRepository", targets: ["OsaurusRepository"])
    ],
    targets: [
        .target(
            name: "OsaurusRepository",
            path: "."
        )
    ]
)
