// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OsaurusCLI",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "osaurus", targets: ["OsaurusCLI"])
  ],
  targets: [
    .executableTarget(name: "OsaurusCLI", path: ".")
  ]
)
