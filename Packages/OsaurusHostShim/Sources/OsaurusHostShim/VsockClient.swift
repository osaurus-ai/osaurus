//
//  VsockClient.swift
//  osaurus-host
//
//  JSON-RPC client over vsock. Connects to the Osaurus runtime on the host
//  and provides synchronous call/response semantics for CLI subcommands.
//

import Foundation

#if canImport(Glibc)
import Glibc
private let sysSocket = Glibc.socket
private let sysConnect = Glibc.connect
private let sysClose = Glibc.close
private let sysRead = Glibc.read
private let sysWrite = Glibc.write
#elseif canImport(Darwin)
import Darwin
private let sysSocket = Darwin.socket
private let sysConnect = Darwin.connect
private let sysClose = Darwin.close
private let sysRead = Darwin.read
private let sysWrite = Darwin.write
#endif

/// Vsock CID for communicating with the host (CID 2 = host).
private let hostCID: UInt32 = 2
/// Port on which VsockHostAPIServer listens.
private let hostPort: UInt32 = 5001

final class VsockClient {
    private var socketFD: Int32 = -1
    private var nextId: Int = 1

    func connect() throws {
        #if os(Linux)
        socketFD = sysSocket(AF_VSOCK, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw ShimError.connectionFailed("Failed to create vsock socket")
        }

        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_cid = hostCID
        addr.svm_port = hostPort

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sysConnect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard result == 0 else {
            sysClose(socketFD)
            throw ShimError.connectionFailed("Failed to connect to host vsock (errno: \(errno))")
        }
        #else
        throw ShimError.connectionFailed("Vsock is only supported on Linux (this binary runs inside a VM)")
        #endif
    }

    func disconnect() {
        if socketFD >= 0 {
            #if os(Linux)
            sysClose(socketFD)
            #endif
            socketFD = -1
        }
    }

    /// Send a JSON-RPC request and wait for the response.
    func call(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextId
        nextId += 1

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)
        try sendFrame(requestData)
        let responseData = try receiveFrame()

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ShimError.invalidResponse
        }

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            throw ShimError.rpcError(message)
        }

        return json["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Length-Prefixed Framing

    private func sendFrame(_ data: Data) throws {
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        try writeAll(lengthData + data)
    }

    private func receiveFrame() throws -> Data {
        let lengthData = try readExactly(4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return try readExactly(Int(length))
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < data.count {
                let ptr = buffer.baseAddress!.advanced(by: offset)
                let remaining = data.count - offset
                let written = sysWrite(socketFD, ptr, remaining)
                guard written > 0 else { throw ShimError.connectionFailed("Write failed (errno: \(errno))") }
                offset += written
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let remaining = count - offset
            let bytesRead = buffer.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                sysRead(socketFD, ptr.baseAddress!.advanced(by: offset), remaining)
            }
            guard bytesRead > 0 else { throw ShimError.connectionFailed("Read failed (errno: \(errno))") }
            offset += bytesRead
        }
        return buffer
    }
}

enum ShimError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case invalidResponse
    case rpcError(String)
    case missingArgument(String)

    var description: String {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .invalidResponse: return "Invalid response from host"
        case .rpcError(let msg): return "RPC error: \(msg)"
        case .missingArgument(let msg): return "Missing argument: \(msg)"
        }
    }
}
