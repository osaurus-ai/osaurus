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
            fputs("Использование: osaurus manifest extract <dylib-path>\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            let json = try extractManifest(from: dylibPath)
            print(json)
            exit(EXIT_SUCCESS)
        } catch let error as ExtractionError {
            fputs("Ошибка: \(error.description)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("Ошибка: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func extractManifest(from path: String) throws -> String {
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
            let errorMsg = dlerror().map { String(cString: $0) } ?? "unknown error"
            throw ExtractionError.loadFailed(errorMsg)
        }
        defer { dlclose(handle) }

        // Try v2 entry point first, fall back to v1
        let api: osr_plugin_api

        if let v2sym = dlsym(handle, "osaurus_plugin_entry_v2") {
            let v2fn = unsafeBitCast(v2sym, to: osr_plugin_entry_v2_t.self)
            var stubHost = osr_host_api(
                version: 2,
                config_get: { _ in nil },
                config_set: { _, _ in },
                config_delete: { _ in },
                db_exec: { _, _ in nil },
                db_query: { _, _ in nil },
                log: { _, _ in }
            )
            guard
                let apiRawPtr = withUnsafeMutablePointer(
                    to: &stubHost,
                    { hostPtr in
                        v2fn(UnsafeRawPointer(hostPtr))
                    }
                )
            else {
                throw ExtractionError.entryReturnedNull
            }
            api = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self).pointee
        } else if let v1sym = dlsym(handle, "osaurus_plugin_entry") {
            let v1fn = unsafeBitCast(v1sym, to: osr_plugin_entry_t.self)
            guard let apiRawPtr = v1fn() else {
                throw ExtractionError.entryReturnedNull
            }
            api = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self).pointee
        } else {
            throw ExtractionError.missingEntryPoint
        }

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
                return "Файл не найден: \(path)"
            case .loadFailed(let msg):
                return "Не удалось загрузить dylib: \(msg)"
            case .missingEntryPoint:
                return "Не найдена точка входа плагина (osaurus_plugin_entry или osaurus_plugin_entry_v2)"
            case .entryReturnedNull:
                return "Точка входа плагина вернула null"
            case .initFailed:
                return "Не удалось инициализировать плагин"
            case .manifestFailed:
                return "Не удалось получить манифест"
            }
        }
    }
}

// MARK: - C ABI Types (local copies for CLI independence)

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// MARK: Host API (host → plugin callbacks via osr_host_api)

private typealias osr_config_get_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_config_set_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias osr_config_delete_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_db_exec_fn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_db_query_fn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_log_fn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
private typealias osr_dispatch_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_task_status_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_dispatch_cancel_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_dispatch_clarify_fn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias osr_complete_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_on_chunk_fn =
    @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
private typealias osr_complete_stream_fn =
    @convention(c) (UnsafePointer<CChar>?, osr_on_chunk_fn?, UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
private typealias osr_embed_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_list_models_fn = @convention(c) () -> UnsafePointer<CChar>?
private typealias osr_http_request_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_file_read_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_list_active_tasks_fn = @convention(c) () -> UnsafePointer<CChar>?
private typealias osr_send_draft_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias osr_dispatch_interrupt_fn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias osr_dispatch_add_issue_fn =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

private struct osr_host_api {
    var version: UInt32
    var config_get: osr_config_get_fn?
    var config_set: osr_config_set_fn?
    var config_delete: osr_config_delete_fn?
    var db_exec: osr_db_exec_fn?
    var db_query: osr_db_query_fn?
    var log: osr_log_fn?
    var dispatch: osr_dispatch_fn?
    var task_status: osr_task_status_fn?
    var dispatch_cancel: osr_dispatch_cancel_fn?
    var dispatch_clarify: osr_dispatch_clarify_fn?
    var complete: osr_complete_fn?
    var complete_stream: osr_complete_stream_fn?
    var embed: osr_embed_fn?
    var list_models: osr_list_models_fn?
    var http_request: osr_http_request_fn?
    var file_read: osr_file_read_fn?
    var list_active_tasks: osr_list_active_tasks_fn?
    var send_draft: osr_send_draft_fn?
    var dispatch_interrupt: osr_dispatch_interrupt_fn?
    var dispatch_add_issue: osr_dispatch_add_issue_fn?
}

// MARK: Plugin API (plugin function table returned to host)

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?
private typealias osr_handle_route_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_on_config_changed_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

private struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
    var version: UInt32
    var handle_route: osr_handle_route_t?
    var on_config_changed: osr_on_config_changed_t?
}

// MARK: Entry Points

private typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?
private typealias osr_plugin_entry_v2_t = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
