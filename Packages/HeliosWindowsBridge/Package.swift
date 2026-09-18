// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HeliosWindowsBridge",
    products: [
        .library(name: "HeliosWindowsBridge", targets: ["HeliosWindowsBridge"])
    ],
    targets: [
        .target(name: "HeliosWindowsBridge"),
        .testTarget(
            name: "HeliosWindowsBridgeTests",
            dependencies: ["HeliosWindowsBridge"]
        ),
    ]
)
