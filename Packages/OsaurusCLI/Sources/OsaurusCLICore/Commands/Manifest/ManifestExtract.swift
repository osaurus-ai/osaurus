//
//  ManifestExtract.swift
//  osaurus
//
//  Command to extract manifest JSON from a built plugin dylib.
//

import Foundation

public struct ManifestExtract {
    public static func execute(args: [String]) {
        guard let dylibPath = args.first, !dylibPath.isEmpty else {
            fputs("Usage: osaurus manifest extract <dylib-path>\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            let json = try extractManifest(from: dylibPath)
            print(json)
            exit(EXIT_SUCCESS)
        } catch let error as ExtractionError {
            fputs("Error: \(error.description)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func extractManifest(from path: String) throws -> String {
        // Resolve path to absolute if relative
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
        }

        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExtractionError.fileNotFound(url.path)
        }

        // Load dylib
        let flags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(url.path, Int32(flags)) else {
            let errorMsg: String
            if let err = dlerror() {
                errorMsg = String(cString: err)
            } else {
                errorMsg = "unknown error"
            }
            throw ExtractionError.loadFailed(errorMsg)
        }
        defer { dlclose(handle) }

        // Find entry point
        guard let sym = dlsym(handle, "osaurus_plugin_entry") else {
            throw ExtractionError.missingEntryPoint
        }

        let entryFn = unsafeBitCast(sym, to: osr_plugin_entry_t.self)
        guard let apiRawPtr = entryFn() else {
            throw ExtractionError.entryReturnedNull
        }

        let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
        let api = apiPtr.pointee

        // Initialize plugin
        guard let initFn = api.`init`, let ctx = initFn() else {
            throw ExtractionError.initFailed
        }
        defer { api.destroy?(ctx) }

        // Get manifest
        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            throw ExtractionError.manifestFailed
        }
        defer { api.free_string?(jsonPtr) }

        return String(cString: jsonPtr)
    }

    enum ExtractionError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case loadFailed(String)
        case missingEntryPoint
        case entryReturnedNull
        case initFailed
        case manifestFailed

        var description: String {
            switch self {
            case .fileNotFound(let path):
                return "File not found: \(path)"
            case .loadFailed(let msg):
                return "Failed to load dylib: \(msg)"
            case .missingEntryPoint:
                return "Missing osaurus_plugin_entry symbol"
            case .entryReturnedNull:
                return "Plugin entry returned null"
            case .initFailed:
                return "Plugin init failed"
            case .manifestFailed:
                return "Failed to get manifest"
            }
        }
    }
}

// MARK: - C ABI Types (local copies for CLI independence)

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?

private typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
}

private typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?
