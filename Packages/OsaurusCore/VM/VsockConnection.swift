//
//  VsockConnection.swift
//  osaurus
//
//  JSON-RPC client over vsock for host-to-VM communication.
//  Provides exec, file I/O, and process management primitives.
//

import Foundation
import Virtualization

/// Result of executing a command inside the VM.
public struct ExecResult: Codable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int
    public let newFiles: [String]?

    enum CodingKeys: String, CodingKey {
        case stdout, stderr
        case exitCode = "exit_code"
        case newFiles = "new_files"
    }
}

public final class VsockConnection: @unchecked Sendable {
    private let socketDevice: VZVirtioSocketDevice
    private let port: UInt32
    private var readHandle: FileHandle?
    private var writeHandle: FileHandle?
    private let lock = NSLock()
    private var nextId: Int = 1
    private let ioQueue = DispatchQueue(label: "com.osaurus.vsock.io", qos: .userInitiated)

    init(socketDevice: VZVirtioSocketDevice, port: UInt32) {
        self.socketDevice = socketDevice
        self.port = port
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        let fd = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            socketDevice.connect(toPort: port) { result in
                switch result {
                case .success(let conn):
                    continuation.resume(returning: conn.fileDescriptor)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        self.readHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        self.writeHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    /// Set file descriptor from an externally completed connect (used by VMManager's synchronous retry).
    func setFileDescriptor(_ fd: Int32) {
        self.readHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        self.writeHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    func disconnect() {
        readHandle = nil
        writeHandle = nil
    }

    // MARK: - JSON-RPC Methods

    /// Execute a command in the VM.
    public func exec(
        command: String,
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: Int = 30
    ) async throws -> ExecResult {
        var params: [String: Any] = ["command": command, "timeout": timeout]
        if let cwd { params["cwd"] = cwd }
        if let env { params["env"] = env }
        return try await call(method: "exec", params: params)
    }

    /// Write a file into the VM.
    public func writeFile(path: String, content: String) async throws {
        let _: EmptyResult = try await call(method: "write_file", params: ["path": path, "content": content])
    }

    /// Read a file from the VM.
    public func readFile(path: String) async throws -> String {
        let result: FileReadResult = try await call(method: "read_file", params: ["path": path])
        return result.content
    }

    /// List files in a directory inside the VM.
    public func listFiles(path: String) async throws -> [String] {
        let result: FileListResult = try await call(method: "list_files", params: ["path": path])
        return result.files
    }

    /// Start a long-running process in the VM.
    public func startProcess(command: String, env: [String: String]? = nil) async throws -> Int {
        var params: [String: Any] = ["command": command]
        if let env { params["env"] = env }
        let result: ProcessResult = try await call(method: "start_process", params: params)
        return result.pid
    }

    /// Stop a process by PID.
    public func stopProcess(pid: Int) async throws {
        let _: EmptyResult = try await call(method: "stop_process", params: ["pid": pid])
    }

    // MARK: - JSON-RPC Transport

    private func call<T: Decodable>(method: String, params: [String: Any]) async throws -> T {
        let id = lock.withLock { () -> Int in
            let current = nextId
            nextId += 1
            return current
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                do {
                    let data = try self.sendAndReceive(requestData)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown RPC error"
            throw NSError(domain: "VsockRPC", code: error["code"] as? Int ?? -1,
                         userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let resultData = try? JSONSerialization.data(withJSONObject: json["result"] as Any) else {
            throw NSError(domain: "VsockRPC", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Missing result in JSON-RPC response"])
        }

        return try JSONDecoder().decode(T.self, from: resultData)
    }

    /// Send a length-prefixed JSON-RPC request and read the length-prefixed response.
    private func sendAndReceive(_ data: Data) throws -> Data {
        guard let wh = writeHandle, let rh = readHandle else {
            throw VMError.vsockConnectionFailed
        }

        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)

        try wh.write(contentsOf: lengthData + data)

        let responseLengthData = try readExactly(from: rh, count: 4)
        let responseLength = responseLengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return try readExactly(from: rh, count: Int(responseLength))
    }

    private func readExactly(from handle: FileHandle, count: Int) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try handle.read(upToCount: remaining) ?? Data()
            if chunk.isEmpty {
                throw NSError(domain: "VsockRPC", code: -2,
                             userInfo: [NSLocalizedDescriptionKey: "Connection closed while reading"])
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

// MARK: - Result Types

private struct EmptyResult: Codable {}

private struct FileReadResult: Codable {
    let content: String
}

private struct FileListResult: Codable {
    let files: [String]
}

private struct ProcessResult: Codable {
    let pid: Int
}
