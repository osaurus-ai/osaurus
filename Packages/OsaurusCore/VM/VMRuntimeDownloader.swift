//
//  VMRuntimeDownloader.swift
//  osaurus
//
//  Downloads the Alpine Linux Virt ISO for VM installation.
//  The ISO is used with VZEFIBootLoader on first boot to install Alpine
//  into the agent's disk image. Subsequent boots use the installed system.
//

import Foundation

private let alpineVersion = "3.23.3"
private let alpineMajor = "v3.23"

private let alpineISOURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/\(alpineMajor)/releases/aarch64/alpine-virt-\(alpineVersion)-aarch64.iso")!

@MainActor
public final class VMRuntimeDownloader: ObservableObject {
    public static let shared = VMRuntimeDownloader()

    public enum Status: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case failed(String)
    }

    @Published public private(set) var status: Status = .notDownloaded

    private init() {
        refreshStatus()
    }

    public func refreshStatus() {
        if isRuntimeAvailable {
            status = .ready
        } else if case .downloading = status {
            // keep current
        } else {
            status = .notDownloaded
        }
    }

    /// Whether the Alpine ISO exists at the expected path.
    public var isRuntimeAvailable: Bool {
        FileManager.default.fileExists(atPath: OsaurusPaths.alpineISO().path)
    }

    /// Download the Alpine Virt ISO.
    public func download() async {
        switch status {
        case .downloading, .ready:
            return
        case .notDownloaded, .failed:
            break
        }

        status = .downloading(progress: 0)

        let vmDir = OsaurusPaths.root().appendingPathComponent("vm", isDirectory: true)
        OsaurusPaths.ensureExistsSilent(vmDir)

        let destination = OsaurusPaths.alpineISO()

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: alpineISOURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                status = .failed("Download failed (HTTP \(code))")
                return
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            if isRuntimeAvailable {
                status = .ready
            } else {
                status = .failed("Download completed but ISO not found at expected path")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
