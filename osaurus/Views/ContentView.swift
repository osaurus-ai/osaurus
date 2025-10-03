//
//  ContentView.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject var server: ServerController
  @EnvironmentObject private var updater: UpdaterViewModel
  @StateObject private var themeManager = ThemeManager.shared
  @Environment(\.theme) private var theme

  @State private var portString: String = "1337"
  @State private var showError: Bool = false
  @State private var isHealthy: Bool = false
  @State private var lastHealthCheck: Date?
  @State private var selectedModelId: String?
  @State private var showConfiguration = false

  var body: some View {
    ZStack {
      // Themed background
      theme.primaryBackground
        .ignoresSafeArea()

      VStack(spacing: 12) {
        // Top row: Logo and status
        HStack(spacing: 8) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))

          VStack(alignment: .leading, spacing: 4) {
            Text("Osaurus")
              .font(.system(size: 18, weight: .bold, design: .rounded))
              .foregroundColor(theme.primaryText)

            if server.isRunning {
              HStack(spacing: 4) {
                Text("http://\(server.localNetworkAddress):\(String(server.port))")
                  .font(.system(size: 11, weight: .regular, design: .monospaced))
                  .minimumScaleFactor(0.8)
                  .foregroundColor(theme.secondaryText)

                Button(action: {
                  let url = "http://\(server.localNetworkAddress):\(String(server.port))"
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(url, forType: .string)
                }) {
                  Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy URL")
              }
              .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
              Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
            }
          }

          Spacer()

          // Primary control button in top-right
          SimpleToggleButton(
            isOn: server.serverHealth == .running,
            title: primaryButtonTitle,
            icon: primaryButtonIcon,
            action: toggleServer
          )
          .disabled(isBusy)
        }

        // Bottom row: Actions
        HStack(spacing: 4) {
          // System resource monitor
          SystemResourceMonitor()

          Spacer()

          // Action buttons
          HStack(spacing: 6) {
            if !server.isRunning {
              Button(action: { showConfiguration = true }) {
                Image(systemName: "gearshape")
                  .font(.system(size: 14))
                  .foregroundColor(theme.primaryText)
                  .frame(width: 28, height: 28)
                  .background(
                    Circle()
                      .fill(theme.buttonBackground)
                      .overlay(
                        Circle()
                          .stroke(theme.buttonBorder, lineWidth: 1)
                      )
                  )
              }
              .buttonStyle(PlainButtonStyle())
              .help("Configure server")
              .popover(
                isPresented: $showConfiguration, attachmentAnchor: .point(.bottom), arrowEdge: .top
              ) {
                ConfigurationView(portString: $portString, configuration: $server.configuration)
              }
            }

            Button(action: {
              AppDelegate.shared?.showModelManagerWindow()
            }) {
              Image(systemName: "cube.box")
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)
                .frame(width: 28, height: 28)
                .background(
                  Circle()
                    .fill(theme.buttonBackground)
                    .overlay(
                      Circle()
                        .stroke(theme.buttonBorder, lineWidth: 1)
                    )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .help("Manage models")

            Button(action: { updater.checkForUpdates() }) {
              Image(systemName: "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)
                .frame(width: 28, height: 28)
                .background(
                  Circle()
                    .fill(theme.buttonBackground)
                    .overlay(
                      Circle()
                        .stroke(theme.buttonBorder, lineWidth: 1)
                    )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .help("Check for Updates…")

            Button(action: { NSApp.terminate(nil) }) {
              Image(systemName: "power")
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)
                .frame(width: 28, height: 28)
                .background(
                  Circle()
                    .fill(theme.buttonBackground)
                    .overlay(
                      Circle()
                        .stroke(theme.buttonBorder, lineWidth: 1)
                    )
                )
            }
            .buttonStyle(PlainButtonStyle())
            .help("Quit")
          }
        }
      }
      .padding(16)
    }
    .frame(
      width: 380,
      height: 150
    )
    .environment(\.theme, themeManager.currentTheme)
    .onAppear {
      portString = String(server.port)
      startHealthCheck()
    }
    .alert("Server Error", isPresented: $showError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(server.lastErrorMessage ?? "An error occurred while managing the server.")
    }

  }

  private var statusText: String {
    switch server.serverHealth {
    case .stopped:
      return "Run LLMs locally"
    case .starting:
      return "Starting..."
    case .running:
      return "Running on port \(String(server.port))"
    case .stopping:
      return "Stopping..."
    case .error(let message):
      return "Error: \(message)"
    }
  }

  private var statusDescription: String {
    switch server.serverHealth {
    case .stopped: return "Stopped"
    case .starting: return "Starting..."
    case .running: return "Running"
    case .stopping: return "Stopping..."
    case .error: return "Error"
    }
  }

  private var statusColor: Color {
    switch server.serverHealth {
    case .stopped: return .gray
    case .starting, .stopping: return .orange
    case .running: return .green
    case .error: return .red
    }
  }

  private var isBusy: Bool {
    switch server.serverHealth {
    case .starting, .stopping: return true
    default: return false
    }
  }

  private func toggleServer() {
    if server.isRunning {
      Task { @MainActor in
        await server.stopServer()
      }
    } else {
      guard let port = Int(portString), (1..<65536).contains(port) else {
        server.lastErrorMessage = "Please enter a valid port between 1 and 65535"
        showError = true
        return
      }

      server.port = port
      Task { @MainActor in
        await server.startServer()
        if server.lastErrorMessage != nil {
          showError = true
        }
      }
    }
  }

  private func startHealthCheck() {
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
      Task { @MainActor in
        if server.isRunning {
          isHealthy = await server.checkServerHealth()
          lastHealthCheck = Date()
        }
      }
    }
  }
}

extension ContentView {
  fileprivate var primaryButtonTitle: String {
    switch server.serverHealth {
    case .stopped: return "Start"
    case .starting: return "Starting…"
    case .running: return "Stop"
    case .stopping: return "Stopping…"
    case .error: return "Retry"
    }
  }

  fileprivate var primaryButtonIcon: String {
    switch server.serverHealth {
    case .stopped: return "play.circle.fill"
    case .starting: return "hourglass"
    case .running: return "stop.circle.fill"
    case .stopping: return "hourglass"
    case .error: return "exclamationmark.triangle.fill"
    }
  }
}

// MARK: - Configuration View
struct ConfigurationView: View {
  @Environment(\.theme) private var theme
  @Binding var portString: String
  @Binding var configuration: ServerConfiguration
  @Environment(\.dismiss) private var dismiss
  @State private var tempPortString: String = ""
  @State private var tempExposeToNetwork: Bool = false
  @State private var tempStartAtLogin: Bool = false
  @State private var showAdvancedSettings: Bool = false
  @State private var cliInstallMessage: String? = nil
  @State private var cliInstallSuccess: Bool = false

  // Advanced settings state
  @State private var tempTopP: String = "1.0"
  @State private var tempKVBits: String = "4"
  @State private var tempKVGroup: String = "64"
  @State private var tempQuantStart: String = "0"
  @State private var tempMaxKV: String = ""
  @State private var tempPrefillStep: String = "1024"
  @State private var tempAllowedOrigins: String = ""

  var body: some View {
    VStack(spacing: 0) {
      // Fixed header
      VStack(spacing: 2) {
        Text("Server Configuration")
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .foregroundColor(theme.primaryText)

        Text("Configure your local server settings")
          .font(.system(size: 11))
          .foregroundColor(theme.secondaryText)
      }
      .padding(.vertical, 12)

      Divider()
        .background(theme.primaryBorder)

      // Scrollable content area
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          // Port configuration section
          VStack(alignment: .leading, spacing: 12) {
            Label("Network Settings", systemImage: "network")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
              Text("Port")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

              TextField("1337", text: $tempPortString)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                  RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(
                      RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.inputBorder, lineWidth: 1)
                    )
                )
                .foregroundColor(theme.primaryText)

              Text("Enter a port number between 1 and 65535")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }

            // Network exposure toggle
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Expose to network")
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(theme.primaryText)
                Text("Allow devices on your network to connect")
                  .font(.system(size: 10))
                  .foregroundStyle(theme.tertiaryText)
              }

              Spacer()

              Toggle("", isOn: $tempExposeToNetwork)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
            }
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(theme.secondaryBackground)
          )

          // System settings section
          VStack(alignment: .leading, spacing: 12) {
            Label("System", systemImage: "gear")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(theme.primaryText)

            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Start at Login")
                  .font(.system(size: 12, weight: .medium))
                  .foregroundStyle(theme.primaryText)
                Text("Launch Osaurus when you sign in")
                  .font(.system(size: 10))
                  .foregroundStyle(theme.tertiaryText)
              }

              Spacer()

              Toggle("", isOn: $tempStartAtLogin)
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .labelsHidden()
            }
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(theme.secondaryBackground)
          )

          // Command Line Tool section
          VStack(alignment: .leading, spacing: 12) {
            Label("Command Line Tool", systemImage: "terminal")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
              Text("Install the `osaurus` CLI into your PATH.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

              HStack(spacing: 8) {
                Button(action: { installCLI() }) {
                  Text("Install CLI")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                      RoundedRectangle(cornerRadius: 6)
                        .fill(theme.buttonBackground)
                        .overlay(
                          RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.buttonBorder, lineWidth: 1)
                        )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .help("Create a symlink to the embedded CLI")

                if let message = cliInstallMessage {
                  Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(cliInstallSuccess ? .green : .red)
                    .lineLimit(2)
                }
              }

              Text("If installed to ~/.local/bin, ensure it's in your PATH.")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(theme.secondaryBackground)
          )

          // Models directory section
          VStack(alignment: .leading, spacing: 12) {
            Label("Storage", systemImage: "folder")
              .font(.system(size: 13, weight: .semibold))
              .foregroundColor(theme.primaryText)

            DirectoryPickerView()
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(theme.secondaryBackground)
          )

          // Advanced settings toggle
          Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
              showAdvancedSettings.toggle()
            }
          }) {
            HStack(spacing: 8) {
              Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .medium))
                .rotationEffect(.degrees(showAdvancedSettings ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: showAdvancedSettings)

              Text("Advanced Settings")
                .font(.system(size: 12, weight: .medium))

              Spacer()

              if !showAdvancedSettings {
                Text("Show more options")
                  .font(.system(size: 10))
                  .foregroundColor(theme.tertiaryText)
              }
            }
            .foregroundColor(theme.primaryText)
            .padding(12)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(theme.secondaryBackground)
                .overlay(
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.primaryBorder, lineWidth: 0.5)
                )
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(PlainButtonStyle())

          if showAdvancedSettings {
            VStack(alignment: .leading, spacing: 16) {
              // Networking Section
              VStack(alignment: .leading, spacing: 12) {
                Label("CORS Settings", systemImage: "lock.shield")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundColor(theme.primaryText)

                VStack(alignment: .leading, spacing: 6) {
                  Text("Allowed Origins")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                  TextField("https://example.com, https://app.localhost", text: $tempAllowedOrigins)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                      RoundedRectangle(cornerRadius: 6)
                        .fill(theme.inputBackground)
                        .overlay(
                          RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.inputBorder, lineWidth: 1)
                        )
                    )
                    .foregroundColor(theme.primaryText)

                  Text("Comma-separated list. Use * for any origin, or leave empty to disable CORS")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                }
              }
              .padding(12)
              .background(
                RoundedRectangle(cornerRadius: 8)
                  .fill(theme.secondaryBackground)
              )

              // AI Parameters Section
              VStack(alignment: .leading, spacing: 12) {
                Label("AI Parameters", systemImage: "cpu")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundColor(theme.primaryText)

                VStack(spacing: 10) {
                  advancedField(
                    "Top P", text: $tempTopP, placeholder: "1.0",
                    help: "Controls diversity of generated text")
                  advancedField(
                    "KV Cache Bits", text: $tempKVBits, placeholder: "4",
                    help: "Quantization bits for KV cache (empty = off)")
                  advancedField(
                    "KV Group Size", text: $tempKVGroup, placeholder: "64",
                    help: "Group size for KV quantization")
                  advancedField(
                    "Quantized KV Start", text: $tempQuantStart, placeholder: "0",
                    help: "Starting layer for KV quantization")
                  advancedField(
                    "Max KV Size", text: $tempMaxKV, placeholder: "",
                    help: "Maximum KV cache size (empty = unlimited)")
                  advancedField(
                    "Prefill Step Size", text: $tempPrefillStep, placeholder: "1024",
                    help: "Step size for prefill operations")
                }
              }
              .padding(12)
              .background(
                RoundedRectangle(cornerRadius: 8)
                  .fill(theme.secondaryBackground)
              )
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
        .padding(16)
      }
      .frame(maxHeight: 310)

      // Fixed bottom action bar
      VStack(spacing: 0) {
        Divider()
          .background(theme.primaryBorder)

        HStack(spacing: 12) {
          Button("Cancel") {
            dismiss()
          }
          .buttonStyle(PlainButtonStyle())
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(theme.secondaryBackground)
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(theme.secondaryBorder, lineWidth: 1)
              )
          )
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(theme.primaryText)

          Spacer()

          Button(action: {
            if let port = Int(tempPortString), (1..<65536).contains(port) {
              portString = tempPortString
              configuration.port = port
              configuration.exposeToNetwork = tempExposeToNetwork
              configuration.startAtLogin = tempStartAtLogin

              // Save advanced settings if they were modified
              configuration.genTopP = Float(tempTopP) ?? configuration.genTopP
              configuration.genKVBits = Int(tempKVBits)
              configuration.genKVGroupSize = Int(tempKVGroup) ?? configuration.genKVGroupSize
              configuration.genQuantizedKVStart =
                Int(tempQuantStart) ?? configuration.genQuantizedKVStart
              configuration.genMaxKVSize = Int(tempMaxKV)
              configuration.genPrefillStepSize =
                Int(tempPrefillStep) ?? configuration.genPrefillStepSize

              // Save CORS allowed origins
              let parsedOrigins: [String] =
                tempAllowedOrigins
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
              configuration.allowedOrigins = parsedOrigins

              // Persist to disk
              ServerConfigurationStore.save(configuration)
              // Apply login item state
              LoginItemService.shared.applyStartAtLogin(configuration.startAtLogin)

              dismiss()
            }
          }) {
            Text("Save")
              .font(.system(size: 13, weight: .medium))
              .foregroundColor(.white)
              .padding(.horizontal, 20)
              .padding(.vertical, 8)
              .background(
                RoundedRectangle(cornerRadius: 6)
                  .fill(theme.accentColor)
              )
          }
          .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
      .background(theme.primaryBackground)
    }
    .frame(width: 380, height: 460)
    .background(theme.primaryBackground)
    .onAppear {
      tempPortString = portString
      tempExposeToNetwork = configuration.exposeToNetwork
      tempStartAtLogin = configuration.startAtLogin
      tempTopP = String(configuration.genTopP)
      tempKVBits = configuration.genKVBits.map(String.init) ?? ""
      tempKVGroup = String(configuration.genKVGroupSize)
      tempQuantStart = String(configuration.genQuantizedKVStart)
      tempMaxKV = configuration.genMaxKVSize.map(String.init) ?? ""
      tempPrefillStep = String(configuration.genPrefillStepSize)
      tempAllowedOrigins = configuration.allowedOrigins.joined(separator: ", ")
    }
  }

  @ViewBuilder
  private func advancedField(
    _ label: String, text: Binding<String>, placeholder: String, help: String
  )
    -> some View
  {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(theme.primaryText)

        Spacer()

        Text(help)
          .font(.system(size: 9))
          .foregroundColor(theme.tertiaryText)
      }

      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(theme.inputBackground)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(theme.inputBorder, lineWidth: 1)
            )
        )
        .foregroundColor(theme.primaryText)
    }
  }
}

// MARK: - CLI Install Helper
extension ConfigurationView {
  private func installCLI() {
    let fm = FileManager.default

    guard let cliURL = resolveCLIExecutableURL() else {
      cliInstallSuccess = false
      cliInstallMessage = "CLI not found. Build once (Run) in Xcode, then retry."
      return
    }

    // Candidate target directories
    let brewBin = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
    let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    let userLocalBin = fm.homeDirectoryForCurrentUser
      .appendingPathComponent(".local", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)

    if tryInstall(cliURL: cliURL, into: brewBin) {
      cliInstallSuccess = true
      cliInstallMessage = "Installed to \(brewBin.appendingPathComponent("osaurus").path)"
      return
    }

    if tryInstall(cliURL: cliURL, into: usrLocalBin) {
      cliInstallSuccess = true
      cliInstallMessage = "Installed to \(usrLocalBin.appendingPathComponent("osaurus").path)"
      return
    }

    // Fallback to user-local bin
    do {
      try fm.createDirectory(at: userLocalBin, withIntermediateDirectories: true)
    } catch {
      // If we can't create ~/.local/bin, abort
      cliInstallSuccess = false
      cliInstallMessage = "Failed to prepare ~/.local/bin (\(error.localizedDescription))"
      return
    }

    if tryInstall(cliURL: cliURL, into: userLocalBin) {
      let linkPath = userLocalBin.appendingPathComponent("osaurus").path
      let inPath = isDirInPATH(userLocalBin.path)
      cliInstallSuccess = true
      cliInstallMessage =
        inPath
        ? "Installed to \(linkPath)"
        : "Installed to \(linkPath). Add to PATH."
      return
    }

    cliInstallSuccess = false
    cliInstallMessage = "Installation failed. Try manual setup from README."
  }

  private func resolveCLIExecutableURL() -> URL? {
    let fm = FileManager.default
    let appURL = Bundle.main.bundleURL
    let embedded = appURL.appendingPathComponent("Contents/Helpers/osaurus", isDirectory: false)
    if fm.fileExists(atPath: embedded.path), fm.isExecutableFile(atPath: embedded.path) {
      return embedded
    }

    // Fallback for development when running from Xcode: try the build Products directory
    // Example: .../DerivedData/.../Build/Products/Debug/osaurus.app
    // CLI may be at: .../DerivedData/.../Build/Products/Debug/osaurus
    let productsDir = appURL.deletingLastPathComponent()
    let debugCLI = productsDir.appendingPathComponent("osaurus", isDirectory: false)
    if fm.fileExists(atPath: debugCLI.path), fm.isExecutableFile(atPath: debugCLI.path) {
      return debugCLI
    }
    let releaseCLI = productsDir.deletingLastPathComponent()
      .appendingPathComponent("Release/osaurus", isDirectory: false)
    if fm.fileExists(atPath: releaseCLI.path), fm.isExecutableFile(atPath: releaseCLI.path) {
      return releaseCLI
    }

    // Also try if the app got embedded but we ran before copy phase: check inside the app that lives in Products/Release
    let releaseEmbedded = productsDir.deletingLastPathComponent()
      .appendingPathComponent("Release/osaurus.app/Contents/Helpers/osaurus", isDirectory: false)
    if fm.fileExists(atPath: releaseEmbedded.path),
      fm.isExecutableFile(atPath: releaseEmbedded.path)
    {
      return releaseEmbedded
    }

    return nil
  }

  private func tryInstall(cliURL: URL, into dir: URL) -> Bool {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
      return false
    }

    let linkURL = dir.appendingPathComponent("osaurus")

    // If an entry exists, replace only if it's a symlink
    if fm.fileExists(atPath: linkURL.path) {
      do {
        _ = try fm.destinationOfSymbolicLink(atPath: linkURL.path)
        // It's a symlink – remove and replace
        try? fm.removeItem(at: linkURL)
      } catch {
        // Not a symlink (likely a real file); do not overwrite
        return false
      }
    }

    do {
      try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: cliURL.path)
      return true
    } catch {
      return false
    }
  }

  private func isDirInPATH(_ dir: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").map(String.init).contains { $0 == dir }
  }
}

#Preview {
  ContentView()
    .environmentObject(ServerController())
}
