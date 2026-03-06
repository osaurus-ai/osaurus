// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsaurusHostShim",
    products: [
        .executable(name: "osaurus-host", targets: ["OsaurusHostShim"])
    ],
    targets: [
        .executableTarget(
            name: "OsaurusHostShim",
            path: "Sources/OsaurusHostShim"
        )
    ]
)
