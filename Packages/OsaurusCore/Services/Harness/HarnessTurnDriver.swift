//
//  HarnessTurnDriver.swift
//  osaurus
//
//  Builds what a chat turn hands its harness: the launch context (runtime,
//  folder, agent identity, server address) and the newest user message.
//

import AppKit
import Foundation

@MainActor
enum HarnessTurnDriver {
    /// Resolve how this chat's harness process should be started.
    ///
    /// - Parameter folderRoot: the chat's selected working folder, or nil for
    ///   the per-chat scratch directory. A selected folder that can't be read
    ///   fails the turn rather than silently falling back to scratch.
    static func launchContext(
        runtime: HarnessRuntime,
        chatId: UUID,
        agentId: UUID,
        folderRoot: URL?
    ) async throws -> HarnessLaunchContext {
        let workingDirectory: URL
        if let folderRoot {
            guard isReadableDirectory(folderRoot) else {
                throw HarnessError.workingFolderUnavailable(path: folderRoot.path)
            }
            workingDirectory = folderRoot
        } else {
            workingDirectory = HarnessScratch.directory(chatId: chatId)
        }

        let manager = AgentManager.shared
        let systemPrompt = manager.effectiveSystemPrompt(for: agentId)
        let port = ServerConfigurationStore.load()?.port ?? 1337
        let reachable = await Task.detached { HarnessServerProbe.isListening(port: port) }.value

        return HarnessLaunchContext(
            runtime: runtime,
            chatId: chatId,
            agentId: agentId,
            agentName: manager.agent(for: agentId)?.name ?? L("Osaurus"),
            workingDirectory: workingDirectory,
            isUserFolder: folderRoot != nil,
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : systemPrompt,
            claudeCode: manager.effectiveClaudeCodeConfig(for: agentId),
            osaurusCLIPath: ClaudeCodeConfiguration.embeddedCLIPath(),
            apiBase: "http://127.0.0.1:\(port)",
            serverReachable: reachable
        )
    }

    /// The newest user message: its text with documents inlined, and its
    /// images.
    static func userMessage(text: String, attachments: [Attachment]) -> HarnessUserMessage {
        let body = ChatSession.buildUserMessageText(content: text, attachments: attachments)
        let images = attachments.filter(\.isImage).compactMap { $0.loadImageData() }.compactMap(harnessImage)
        return HarnessUserMessage(text: body, images: images)
    }

    /// Image bytes with a MIME type harnesses accept; anything else is
    /// re-encoded as PNG.
    nonisolated static func harnessImage(_ data: Data) -> HarnessImage? {
        if let mime = sniffedMIME(data) { return HarnessImage(data: data, mimeType: mime) }
        guard let rep = NSBitmapImageRep(data: data),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return HarnessImage(data: png, mimeType: "image/png")
    }

    nonisolated static func sniffedMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, Array(bytes[0 ..< 4]) == Array("RIFF".utf8),
            Array(bytes[8 ..< 12]) == Array("WEBP".utf8)
        {
            return "image/webp"
        }
        return nil
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }
}

enum HarnessServerProbe {
    /// A TCP connect to the local server: it only needs to answer "is
    /// anything listening", which a refused connect tells immediately.
    static func isListening(port configured: Int, timeout: TimeInterval = 0.5) -> Bool {
        guard configured > 0, configured <= Int(UInt16.max) else { return false }
        let port = UInt16(configured)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
