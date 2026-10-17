// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HeliosSwiftCrossUI",
    products: [
        .executable(name: "heliosswiftcrossui", targets: ["HeliosSwiftCrossUIApp"])
    ],
    targets: [
        .executableTarget(name: "HeliosSwiftCrossUIApp")
    ]
)
