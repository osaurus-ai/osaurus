import Foundation

public struct ScaffoldGenerator {
    public let repoRoot: URL
    private let fileManager: FileManager

    public init(repoRoot: URL, fileManager: FileManager = .default) {
        self.repoRoot = repoRoot
        self.fileManager = fileManager
    }

    @discardableResult
    public func scaffold(
        slice: SliceDefinition,
        architecture: ArchitectureDecision
    ) throws -> HeliosSliceManifest {
        let manifest = HeliosSliceManifest(
            slice: slice,
            tabs: try extractTabs(relativePath: "Packages/OsaurusCore/Models/Configuration/ManagementTab.swift"),
            serviceInterfaces: slice.serviceInterfaces,
            bridgeCapabilities: architecture.bridgeCapabilities,
            primaryUIFramework: architecture.primaryUIFramework,
            windowsBridgePackage: architecture.windowsBridgePackage,
            sourcePaths: slice.sourcePaths,
            todoMarkers: HeliosPorterSupport.serverTodoMarkers
        )

        let sharedDir = HeliosPorterSupport.sharedDirectory(repoRoot: repoRoot)
        try HeliosPorterSupport.ensureDirectory(sharedDir, fileManager: fileManager)

        let manifestURL = sharedDir.appendingPathComponent("\(slice.slug).slice.json")
        let data = try HeliosPorterSupport.makeEncoder().encode(manifest)
        try HeliosPorterSupport.write(data, to: manifestURL, fileManager: fileManager)

        let legacyShaftRoot = repoRoot.appendingPathComponent("Helios/shaft", isDirectory: true)
        if fileManager.fileExists(atPath: legacyShaftRoot.path) {
            try fileManager.removeItem(at: legacyShaftRoot)
        }

        try scaffoldSwiftCrossUI(manifest: manifest, architecture: architecture)
        try scaffoldWindowsBridge(manifest: manifest, architecture: architecture)

        return manifest
    }

    private func extractTabs(relativePath: String) throws -> [String] {
        let source = try HeliosPorterSupport.readSource(at: relativePath, repoRoot: repoRoot)
        return HeliosPorterSupport.firstMatches(pattern: #"^\s*case\s+([a-zA-Z_][a-zA-Z0-9_]*)"#, in: source, limit: 64)
    }

    private func scaffoldSwiftCrossUI(
        manifest: HeliosSliceManifest,
        architecture: ArchitectureDecision
    ) throws {
        let root = repoRoot.appendingPathComponent("Helios/swiftcrossui", isDirectory: true)
        let packageName = "HeliosSwiftCrossUI"
        let executableName = "HeliosSwiftCrossUIApp"
        try HeliosPorterSupport.ensureDirectory(root, fileManager: fileManager)
        try HeliosPorterSupport.write(packageManifest(packageName: packageName, executableName: executableName), to: root.appendingPathComponent("Package.swift"), fileManager: fileManager)
        try HeliosPorterSupport.write(swiftCrossReadme(manifest: manifest, architecture: architecture), to: root.appendingPathComponent("README.md"), fileManager: fileManager)

        let sources = root.appendingPathComponent("Sources/\(executableName)", isDirectory: true)
        try HeliosPorterSupport.ensureDirectory(sources, fileManager: fileManager)
        try HeliosPorterSupport.write(mainFile(executableName: executableName), to: sources.appendingPathComponent("main.swift"), fileManager: fileManager)
        try HeliosPorterSupport.write(platformServicesFile(), to: sources.appendingPathComponent("PlatformServices.swift"), fileManager: fileManager)
        try HeliosPorterSupport.write(
            managementSettingsSliceFile(manifest: manifest),
            to: sources.appendingPathComponent("ManagementSettingsSlice.swift"),
            fileManager: fileManager
        )
    }

    private func scaffoldWindowsBridge(
        manifest: HeliosSliceManifest,
        architecture: ArchitectureDecision
    ) throws {
        let root = repoRoot.appendingPathComponent(architecture.windowsBridgePackage, isDirectory: true)
        try HeliosPorterSupport.ensureDirectory(root, fileManager: fileManager)
        try HeliosPorterSupport.write(windowsBridgePackageManifest(), to: root.appendingPathComponent("Package.swift"), fileManager: fileManager)
        try HeliosPorterSupport.write(windowsBridgeReadme(manifest: manifest, architecture: architecture), to: root.appendingPathComponent("README.md"), fileManager: fileManager)

        let sources = root.appendingPathComponent("Sources/HeliosWindowsBridge", isDirectory: true)
        try HeliosPorterSupport.ensureDirectory(sources, fileManager: fileManager)
        try HeliosPorterSupport.write(platformServicesFile(), to: sources.appendingPathComponent("PlatformServices.swift"), fileManager: fileManager)
        try HeliosPorterSupport.write(winRTBackedServicesFile(), to: sources.appendingPathComponent("WinRTBackedServices.swift"), fileManager: fileManager)

        let tests = root.appendingPathComponent("Tests/HeliosWindowsBridgeTests", isDirectory: true)
        try HeliosPorterSupport.ensureDirectory(tests, fileManager: fileManager)
        try HeliosPorterSupport.write(bridgeSmokeTestsFile(), to: tests.appendingPathComponent("HeliosWindowsBridgeTests.swift"), fileManager: fileManager)

        let projections = root.appendingPathComponent("projections", isDirectory: true)
        try HeliosPorterSupport.ensureDirectory(projections, fileManager: fileManager)
        try HeliosPorterSupport.write(swiftWinRTScopeFile(architecture: architecture), to: projections.appendingPathComponent("swift-winrt-scope.json"), fileManager: fileManager)
    }

    private func packageManifest(packageName: String, executableName: String) -> String {
        """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "\(packageName)",
            products: [
                .executable(name: "\(packageName.lowercased())", targets: ["\(executableName)"])
            ],
            targets: [
                .executableTarget(name: "\(executableName)")
            ]
        )
        """
    }

    private func swiftCrossReadme(
        manifest: HeliosSliceManifest,
        architecture: ArchitectureDecision
    ) -> String {
        """
        # SwiftCrossUI Helios Slice Scaffold

        Generated by `helios-porter scaffold --slice management_settings`.

        - Primary UI framework: `\(architecture.primaryUIFramework)`
        - Shared manifest: `../shared/management-settings.slice.json`
        - Windows bridge package: `../../\(architecture.windowsBridgePackage)`
        - Shared service surface: `\(manifest.serviceInterfaces.joined(separator: "`, `"))`

        This scaffold is intentionally lightweight. It preserves the first `Management/Settings` slice in a SwiftUI-shaped shell while keeping Windows-native behaviors behind `Packages/HeliosWindowsBridge`.
        """
    }

    private func mainFile(executableName: String) -> String {
        """
        import Foundation

        #if canImport(SwiftCrossUI)
        import SwiftCrossUI
        #endif

        @main
        struct \(executableName) {
            static func main() {
                #if canImport(SwiftCrossUI)
                print("Wire the SwiftCrossUI runtime here and hydrate ManagementSettingsRootView from ../../shared/management-settings.slice.json.")
                #else
                print("SwiftCrossUI is not installed yet. This scaffold stays compile-safe while the Windows UI runtime settles.")
                #endif
            }
        }
        """
    }

    private func platformServicesFile() -> String {
        """
        import Foundation

        struct FilePickerRequest: Equatable {
            let title: String
            let allowedExtensions: [String]
        }

        protocol ClipboardService {
            func copy(_ text: String)
        }

        protocol ExternalLinkService {
            func open(_ url: String)
        }

        protocol ServerControlService {
            func currentStatus() -> String
            func localServerURL() -> String
            func refreshStatus()
        }

        protocol SettingsNavigationService {
            func showServerOverview()
            func showAPIReference()
        }

        protocol FilePickerService {
            func pickFile(_ request: FilePickerRequest) -> String?
        }

        struct PlatformServices {
            let clipboard: ClipboardService
            let links: ExternalLinkService
            let server: ServerControlService
            let navigation: SettingsNavigationService
            let filePicker: FilePickerService
        }

        struct PlaceholderClipboardService: ClipboardService {
            func copy(_ text: String) {}
        }

        struct PlaceholderExternalLinkService: ExternalLinkService {
            func open(_ url: String) {}
        }

        struct PlaceholderServerControlService: ServerControlService {
            func currentStatus() -> String { "Unknown" }
            func localServerURL() -> String { "http://127.0.0.1:1337" }
            func refreshStatus() {}
        }

        struct PlaceholderSettingsNavigationService: SettingsNavigationService {
            func showServerOverview() {}
            func showAPIReference() {}
        }

        struct PlaceholderFilePickerService: FilePickerService {
            func pickFile(_ request: FilePickerRequest) -> String? { nil }
        }

        extension PlatformServices {
            static let placeholder = PlatformServices(
                clipboard: PlaceholderClipboardService(),
                links: PlaceholderExternalLinkService(),
                server: PlaceholderServerControlService(),
                navigation: PlaceholderSettingsNavigationService(),
                filePicker: PlaceholderFilePickerService()
            )
        }
        """
    }

    private func managementSettingsSliceFile(manifest: HeliosSliceManifest) -> String {
        let tabs = manifest.tabs.map { "    case \($0)" }.joined(separator: "\n")
        let todoMarkers = manifest.todoMarkers.map { "// \($0)" }.joined(separator: "\n")

        return """
        import Foundation

        let heliosSharedManifestPath = "../../shared/management-settings.slice.json"

        enum HeliosManagementTab: String, CaseIterable {
        \(tabs)
        }

        struct HeliosServerReadAction {
            let title: String
            let perform: () -> Void
        }

        struct HeliosServerOverviewModel {
            let status: String
            let localURL: String
            let readActions: [HeliosServerReadAction]
        }

        struct HeliosServerRewriteTodo {
            let title: String
            let detail: String
        }

        let heliosServerOverview = HeliosServerOverviewModel(
            status: PlatformServices.placeholder.server.currentStatus(),
            localURL: PlatformServices.placeholder.server.localServerURL(),
            readActions: [
                HeliosServerReadAction(title: "Copy Local URL") {
                    PlatformServices.placeholder.clipboard.copy(PlatformServices.placeholder.server.localServerURL())
                },
                HeliosServerReadAction(title: "Open Documentation") {
                    PlatformServices.placeholder.links.open("https://docs.osaurus.ai/")
                },
                HeliosServerReadAction(title: "Open Discord") {
                    PlatformServices.placeholder.links.open("https://discord.gg/dinoki")
                },
                HeliosServerReadAction(title: "Show API Reference") {
                    PlatformServices.placeholder.navigation.showAPIReference()
                },
                HeliosServerReadAction(title: "Inspect Exported Endpoint Spec") {
                    _ = PlatformServices.placeholder.filePicker.pickFile(
                        FilePickerRequest(
                            title: "Select an exported endpoint spec",
                            allowedExtensions: ["json", "yaml"]
                        )
                    )
                },
            ]
        )

        let heliosServerRewriteTodos = [
            HeliosServerRewriteTodo(
                title: "Clipboard migration",
                detail: "Move URL and key copy flows onto ClipboardService."
            ),
            HeliosServerRewriteTodo(
                title: "External launch migration",
                detail: "Move docs, Discord, and local file launches onto ExternalLinkService."
            ),
            HeliosServerRewriteTodo(
                title: "Picker migration",
                detail: "Rebuild NSOpenPanel flows behind FilePickerService and a Windows-native diagnostics surface."
            ),
        ]

        \(todoMarkers)

        #if canImport(SwiftCrossUI)
        import SwiftCrossUI

        struct ManagementSettingsRootView {
            let services: PlatformServices = .placeholder
            let tabs = HeliosManagementTab.allCases
            let serverOverview = heliosServerOverview
            let serverRewriteTodos = heliosServerRewriteTodos

            // This is a framework-shaped bootstrap rather than a finished implementation.
            // It preserves the Management/Settings information architecture while Helios decides
            // how much of the final Windows shell should stay in SwiftCrossUI versus move into the Windows bridge package.
        }
        #endif
        """
    }

    private func windowsBridgePackageManifest() -> String {
        """
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
        """
    }

    private func windowsBridgeReadme(
        manifest: HeliosSliceManifest,
        architecture: ArchitectureDecision
    ) -> String {
        """
        # HeliosWindowsBridge

        This package is the only Helios boundary that should touch `swift-winrt` scope files, generated projections, or Windows-native API adapters.

        ## Responsibilities
        - `\(architecture.bridgeCapabilities.first?.serviceInterface ?? "ClipboardService")` first
        - `\(architecture.bridgeCapabilities.dropFirst().first?.serviceInterface ?? "ExternalLinkService")` second
        - `\(architecture.bridgeCapabilities.dropFirst(2).first?.serviceInterface ?? "FilePickerService")` third

        ## Shared Service Surface
        - `\(manifest.serviceInterfaces.joined(separator: "`, `"))`

        ## Projection Policy
        - Keep projection scope limited to the namespaces listed in `projections/swift-winrt-scope.json`.
        - Do not leak WinRT types into `Helios/swiftcrossui`.
        - Add concrete adapters incrementally behind the shared service protocols.
        """
    }

    private func winRTBackedServicesFile() -> String {
        """
        import Foundation

        struct WinRTProjectionScope: Equatable {
            let serviceInterface: String
            let namespace: String
        }

        enum HeliosWindowsBridgePlan {
            static let projectionOrder = [
                WinRTProjectionScope(
                    serviceInterface: "ClipboardService",
                    namespace: "Windows.ApplicationModel.DataTransfer"
                ),
                WinRTProjectionScope(
                    serviceInterface: "ExternalLinkService",
                    namespace: "Windows.System"
                ),
                WinRTProjectionScope(
                    serviceInterface: "FilePickerService",
                    namespace: "Windows.Storage.Pickers"
                ),
            ]
        }

        struct WinRTClipboardService: ClipboardService {
            func copy(_ text: String) {
                // TODO(Helios): Implement with swift-winrt projections for Windows.ApplicationModel.DataTransfer.
            }
        }

        struct WinRTExternalLinkService: ExternalLinkService {
            func open(_ url: String) {
                // TODO(Helios): Implement with swift-winrt projections for Windows.System launcher APIs.
            }
        }

        struct WinRTFilePickerService: FilePickerService {
            func pickFile(_ request: FilePickerRequest) -> String? {
                // TODO(Helios): Implement with swift-winrt projections for Windows.Storage.Pickers.
                return nil
            }
        }

        extension PlatformServices {
            static func winRTBacked() -> PlatformServices {
                PlatformServices(
                    clipboard: WinRTClipboardService(),
                    links: WinRTExternalLinkService(),
                    server: PlaceholderServerControlService(),
                    navigation: PlaceholderSettingsNavigationService(),
                    filePicker: WinRTFilePickerService()
                )
            }
        }
        """
    }

    private func bridgeSmokeTestsFile() -> String {
        """
        import XCTest
        @testable import HeliosWindowsBridge

        final class HeliosWindowsBridgeTests: XCTestCase {
            func testPlaceholderFactoryProvidesStableBridgeSurface() {
                let services = PlatformServices.placeholder

                XCTAssertEqual(services.server.currentStatus(), "Unknown")
                XCTAssertEqual(services.server.localServerURL(), "http://127.0.0.1:1337")
                XCTAssertNil(
                    services.filePicker.pickFile(
                        FilePickerRequest(title: "Inspect endpoint spec", allowedExtensions: ["json"])
                    )
                )
            }

            func testWinRTProjectionOrderMatchesIncrementalServicePlan() {
                XCTAssertEqual(
                    HeliosWindowsBridgePlan.projectionOrder.map(\\.serviceInterface),
                    ["ClipboardService", "ExternalLinkService", "FilePickerService"]
                )
            }
        }
        """
    }

    private func swiftWinRTScopeFile(architecture: ArchitectureDecision) -> String {
        let namespaces = architecture.bridgeCapabilities.map { capability in
            """
                {
                  "capability" : "\(capability.rawValue)",
                  "namespace" : "\(capability.projectionNamespace)",
                  "serviceInterface" : "\(capability.serviceInterface)"
                }
            """
        }.joined(separator: ",\n")

        return """
        {
          "generator" : "swift-winrt",
          "notes" : [
            "Restrict projections to the minimum namespaces needed by HeliosWindowsBridge.",
            "Do not leak projected WinRT types into Helios/swiftcrossui."
          ],
          "package" : "HeliosWindowsBridge",
          "projectionScope" : [
        \(namespaces)
          ]
        }
        """
    }
}
