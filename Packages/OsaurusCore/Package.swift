// swift-tools-version: 6.2
import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
    .package(url: "https://github.com/apple/containerization.git", from: "0.26.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    .package(url: "https://github.com/orlandos-nl/IkigaJSON", from: "2.3.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    .package(
        url: "https://github.com/osaurus-ai/mlx-swift",
        revision: "02b01f07e8c5cae22cd7fd1187e673d8d5de0db6"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.4"),
    .package(
        url: "https://github.com/rryam/VecturaKit",
        revision: "5fed66f3700bee561326e719250aa01c49fc53d5"),
    .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
    .package(path: "../OsaurusRepository"),
    .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
]

if let localMLXSwiftLMPath = Context.environment["LOCAL_MLX_SWIFT_LM_PATH"],
   !localMLXSwiftLMPath.isEmpty
{
    dependencies.append(.package(path: localMLXSwiftLMPath))
} else {
    dependencies.append(
        .package(
            url: "https://github.com/osaurus-ai/mlx-swift-lm",
            revision: "10d547ee65e16e9e9c20197623b29ab7c4952100"))
}

let package = Package(
    name: "OsaurusCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusCore", targets: ["OsaurusCore"])
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "OsaurusCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "IkigaJSON", package: "IkigaJSON"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
                .product(name: "OsaurusRepository", package: "OsaurusRepository"),
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ],
            path: ".",
            exclude: ["Tests"]
        ),
        .testTarget(
            name: "OsaurusCoreTests",
            dependencies: [
                "OsaurusCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "VecturaKit", package: "VecturaKit"),
            ],
            path: "Tests"
        ),
    ]
)
