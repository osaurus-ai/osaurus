// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HeliosPorter",
    products: [
        .library(name: "HeliosPorterCore", targets: ["HeliosPorterCore"]),
        .executable(name: "helios-porter", targets: ["HeliosPorterCLI"]),
    ],
    targets: [
        .target(
            name: "HeliosPorterCore"
        ),
        .executableTarget(
            name: "HeliosPorterCLI",
            dependencies: ["HeliosPorterCore"]
        ),
        .testTarget(
            name: "HeliosPorterCoreTests",
            dependencies: ["HeliosPorterCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
