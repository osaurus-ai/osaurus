// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OsaurusCore",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "OsaurusCore", targets: ["OsaurusCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
    .package(url: "https://github.com/orlandos-nl/IkigaJSON", from: "2.3.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "OsaurusCore",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "IkigaJSON", package: "IkigaJSON"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "MLXLLM", package: "mlx-swift-examples"),
        .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
        .product(name: "Hub", package: "swift-transformers"),
      ],
      path: ".",
      exclude: ["Tests"]
    ),
    .testTarget(
      name: "OsaurusCoreTests",
      dependencies: [
        "OsaurusCore",
        .product(name: "NIOEmbedded", package: "swift-nio"),
      ],
      path: "Tests"
    ),
  ]
)
