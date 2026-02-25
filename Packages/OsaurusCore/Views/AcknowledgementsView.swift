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
        VStack(spacing: 0) {
            // Header
            headerView

            // Content
            if isLoading {
                loadingView
            } else if let error = error {
                errorView(error)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        introSection

                        if !mitLicenses.isEmpty {
                            licenseSection(title: "MIT License", packages: mitLicenses)
                        }

                        if !apacheLicenses.isEmpty {
                            licenseSection(title: "Apache License 2.0", packages: apacheLicenses)
                        }

                        if !otherLicenses.isEmpty {
                            licenseSection(title: "Other Licenses", packages: otherLicenses)
                        }

                        footerSection
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            loadAcknowledgements()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("Acknowledgements")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(theme.primaryText)

                        Text("\(acknowledgements.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                    }

                    Text("Open source libraries used by Osaurus")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .background(theme.secondaryBackground)
    }

    // MARK: - Loading & Error States

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.8)
            Text("Loading acknowledgements...")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(theme.warningColor)
            Text("Failed to load acknowledgements")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.primaryText)
                .padding(.top, 8)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content Sections

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Osaurus is built with the help of many excellent open source projects. We are grateful to the developers and maintainers of these libraries."
            )
            .font(.system(size: 14))
            .foregroundColor(theme.secondaryText)
            .lineSpacing(4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
    }

    private func licenseSection(title: String, packages: [Acknowledgement]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text("\(packages.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.tertiaryBackground)
                    )
            }

            LazyVStack(spacing: 8) {
                ForEach(packages) { package in
                    PackageRow(package: package)
                }
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .background(theme.secondaryBorder)

            Text("Full license texts are available in the linked repositories.")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)

            HStack(spacing: 16) {
                Button("View on GitHub") {
                    if let url = URL(string: "https://github.com/osaurus-ai/osaurus") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .padding(.top, 16)
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
            name: "MLX Swift",
            identity: "mlx-swift",
            version: "0.29",
            repository: "https://github.com/ml-explore/mlx-swift",
            license: "MIT",
            licenseUrl: "https://github.com/ml-explore/mlx-swift/blob/main/LICENSE"
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
            name: "IkigaJSON",
            identity: "ikigajson",
            version: "2.3",
            repository: "https://github.com/orlandos-nl/IkigaJSON",
            license: "MIT",
            licenseUrl: "https://github.com/orlandos-nl/IkigaJSON/blob/master/LICENSE"
        ),
    ]
}

// MARK: - Package Row

private struct PackageRow: View {
    @Environment(\.theme) private var theme
    let package: Acknowledgement

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(package.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Text("v\(package.version)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }

                Text(package.repository.replacingOccurrences(of: "https://github.com/", with: ""))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            // License badge
            Text(package.license)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor.opacity(0.1))
                )

            // Open link button
            Button {
                if let url = URL(string: package.repository) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundColor(isHovering ? theme.accentColor : theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Open repository")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering ? theme.secondaryBackground : theme.tertiaryBackground.opacity(0.5))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AcknowledgementsView()
}
