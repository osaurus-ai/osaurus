//
//  AcknowledgementsView.swift
//  osaurus
//
//  Displays open source license acknowledgements for third-party libraries.
//

import AppKit
import SwiftUI

// MARK: - Models

struct AcknowledgementsData: Codable {
    let generated: Bool
    let description: String
    let acknowledgements: [Acknowledgement]
}

struct Acknowledgement: Codable, Identifiable {
    let name: String
    let identity: String
    let version: String
    let repository: String
    let license: String
    let licenseUrl: String

    var id: String { identity }
}

// MARK: - View

struct AcknowledgementsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var acknowledgements: [Acknowledgement] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedLicense: String?

    private var mitLicenses: [Acknowledgement] {
        acknowledgements.filter { $0.license == "MIT" }
    }

    private var apacheLicenses: [Acknowledgement] {
        acknowledgements.filter { $0.license == "Apache 2.0" }
    }

    private var otherLicenses: [Acknowledgement] {
        acknowledgements.filter { $0.license != "MIT" && $0.license != "Apache 2.0" }
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            SettingsPageHeader(
                title: "Acknowledgements",
                subtitle: "Open source libraries used by Osaurus",
                count: acknowledgements.isEmpty ? nil : acknowledgements.count
            )

            if isLoading {
                SettingsEmptyState(loading: "Loading acknowledgements...")
                    .frame(maxHeight: .infinity)
            } else if let error = error {
                SettingsEmptyState(inline: "exclamationmark.triangle", title: "Failed to load acknowledgements", hint: error)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    SettingsPageContent {
                        Text(
                            "Osaurus is built with the help of many excellent open source projects. We are grateful to the developers and maintainers of these libraries.",
                            bundle: .module
                        )
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if !mitLicenses.isEmpty {
                            licenseSection(title: "MIT License", packages: mitLicenses)
                        }
                        if !apacheLicenses.isEmpty {
                            licenseSection(title: "Apache License 2.0", packages: apacheLicenses)
                        }
                        if !otherLicenses.isEmpty {
                            licenseSection(title: "Other Licenses", packages: otherLicenses)
                        }

                        SettingsSection(footer: "Full license texts are available in the linked repositories.") {
                            SettingsLinkRow(title: "View on GitHub", actionTitle: "Open") {
                                if let url = URL(string: "https://github.com/osaurus-ai/osaurus") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadAcknowledgements()
        }
    }

    private func licenseSection(title: String, packages: [Acknowledgement]) -> some View {
        SettingsSection(title: title, caption: "\(packages.count)") {
            ForEach(packages) { package in
                PackageRow(package: package)
            }
        }
    }

    // MARK: - Data Loading

    private func loadAcknowledgements() {
        isLoading = true
        error = nil

        // Try to load from bundle
        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json") {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(AcknowledgementsData.self, from: data)
                acknowledgements = decoded.acknowledgements
                isLoading = false
                return
            } catch {
                print("[AcknowledgementsView] Failed to load from bundle: \(error)")
            }
        }

        // Fallback: use embedded data
        acknowledgements = Self.fallbackAcknowledgements
        isLoading = false
    }

    // MARK: - Fallback Data

    private static let fallbackAcknowledgements: [Acknowledgement] = [
        Acknowledgement(
            name: "SwiftNIO",
            identity: "swift-nio",
            version: "2.90",
            repository: "https://github.com/apple/swift-nio",
            license: "Apache 2.0",
            licenseUrl: "https://github.com/apple/swift-nio/blob/main/LICENSE.txt"
        ),
        Acknowledgement(
            name: "Sparkle",
            identity: "sparkle",
            version: "2.8",
            repository: "https://github.com/sparkle-project/Sparkle",
            license: "MIT",
            licenseUrl: "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE"
        ),
        Acknowledgement(
            name: "vMLX Swift",
            identity: "vmlx-swift",
            version: "0b85cad0",
            repository: "https://github.com/osaurus-ai/vmlx-swift",
            license: "MIT",
            licenseUrl: "https://github.com/osaurus-ai/vmlx-swift/blob/main/LICENSE"
        ),
        Acknowledgement(
            name: "FluidAudio",
            identity: "fluidaudio",
            version: "0.12",
            repository: "https://github.com/FluidInference/FluidAudio",
            license: "Apache 2.0",
            licenseUrl: "https://github.com/FluidInference/FluidAudio/blob/main/LICENSE"
        ),
        Acknowledgement(
            name: "MCP Swift SDK",
            identity: "swift-sdk",
            version: "0.10",
            repository: "https://github.com/modelcontextprotocol/swift-sdk",
            license: "MIT",
            licenseUrl: "https://github.com/modelcontextprotocol/swift-sdk/blob/main/LICENSE"
        ),
        Acknowledgement(
            name: "Swift Transformers",
            identity: "swift-transformers",
            version: "1.1",
            repository: "https://github.com/huggingface/swift-transformers",
            license: "Apache 2.0",
            licenseUrl: "https://github.com/huggingface/swift-transformers/blob/main/LICENSE"
        ),
        Acknowledgement(
            name: "Swift HuggingFace",
            identity: "swift-huggingface",
            version: "0.8",
            repository: "https://github.com/huggingface/swift-huggingface",
            license: "Apache 2.0",
            licenseUrl: "https://github.com/huggingface/swift-huggingface/blob/main/LICENSE"
        ),
        Acknowledgement(
            name: "IkigaJSON",
            identity: "ikigajson",
            version: "2.3",
            repository: "https://github.com/orlandos-nl/IkigaJSON",
            license: "MIT",
            licenseUrl: "https://github.com/orlandos-nl/IkigaJSON/blob/master/LICENSE"
        ),
        Acknowledgement(
            name: "potion-base-4M (embedding model)",
            identity: "potion-base-4m",
            version: "9b3cff41",
            repository: "https://huggingface.co/minishlab/potion-base-4M",
            license: "MIT",
            licenseUrl: "https://huggingface.co/minishlab/potion-base-4M"
        ),
    ]
}

// MARK: - Package Row

private struct PackageRow: View {
    @Environment(\.theme) private var theme
    let package: Acknowledgement

    var body: some View {
        SettingsRow(
            title: package.name,
            description: package.repository.replacingOccurrences(of: "https://github.com/", with: ""),
            badge: "v\(package.version)",
            verbatimTitle: true,
            verbatimDescription: true
        ) {
            HStack(spacing: theme.space.s8) {
                StatusChip(package.license, tone: .accent)
                SettingsIconButton("arrow.up.right.square", help: "Open repository", size: .compact) {
                    if let url = URL(string: package.repository) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        AcknowledgementsView()
    }
#endif
