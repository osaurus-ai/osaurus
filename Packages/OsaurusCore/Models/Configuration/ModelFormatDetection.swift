//
//  ModelFormatDetection.swift
//  osaurus
//
//  Single source of truth for "is this on-disk bundle in MLX format".
//  vmlx-swift can only load MLX-format weights; a co-mingled PyTorch /
//  transformers safetensors bundle (same config.json + tokenizer + safetensors
//  shape) otherwise passes discovery and then fails at load. Two file-level
//  signals decide it, either one sufficient:
//    - config.json carries a top-level `quantization` block — mlx_lm /
//      `mx.quantize` writes this; transformers uses `quantization_config`
//      instead, so keying on `quantization` does not misread a HF model.
//    - a safetensors file's header `__metadata__.format == "mlx"`.
//  Unquantized MLX bundles rely on the metadata tag; quantized ones (including
//  first-party MXFP8 builds that omit the tag) rely on the quantization block.
//

import Foundation

enum ModelFormatDetection {
    // MARK: - Memoization

    // `isMLXFormat(at:)` is read indirectly from view bodies (catalog cards,
    // picker rows) via `MLXModel.isMLXFormat`, and each call reads files off
    // disk — synchronous I/O that hangs the UI when it runs per row per body
    // eval. The verdict is a pure function of the on-disk bundle, so it is
    // cached and dropped on `.localModelsChanged` to stay in sync with
    // downloads and deletions (mirrors `VLMDetection`).
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var verdictCache: [String: Bool] = [:]
    private nonisolated(unsafe) static var didInstallObserver = false

    private static func cachedVerdict(_ key: String, compute: () -> Bool) -> Bool {
        ensureCacheObserverInstalled()
        cacheLock.lock()
        if let cached = verdictCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = compute()

        cacheLock.lock()
        verdictCache[key] = result
        cacheLock.unlock()
        return result
    }

    private static func ensureCacheObserverInstalled() {
        cacheLock.lock()
        let already = didInstallObserver
        didInstallObserver = true
        cacheLock.unlock()
        if already { return }

        NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: nil
        ) { _ in
            ModelFormatDetection.cacheLock.lock()
            ModelFormatDetection.verdictCache.removeAll(keepingCapacity: true)
            ModelFormatDetection.cacheLock.unlock()
        }
    }

    // MARK: - Detection

    /// Whether the bundle at `directory` should be treated as MLX-loadable.
    ///
    /// Deliberately biased toward *allowing*: a bundle is greyed out only when
    /// it can be **positively proven non-MLX** (a safetensors header tagged for
    /// another framework — `pt`, `tf`, `flax`, …). MLX proof (a `quantization`
    /// block or a `format: mlx` tag) always allows; a bundle with no usable
    /// signal at all is allowed too, since a real MLX build can legitimately
    /// lack both (e.g. an unquantized conversion whose weights carry no
    /// `__metadata__`). This keeps a working MLX model from ever being hidden;
    /// the cost is that a non-MLX bundle with no framework tag isn't greyed and
    /// instead fails at load as before — no regression.
    static func isMLXFormat(at directory: URL) -> Bool {
        cachedVerdict("dir:\(directory.path)") {
            if configHasMLXQuantization(at: directory) { return true }

            let formats = safetensorsFormatTags(at: directory)
            if formats.contains("mlx") { return true }
            // Proven non-MLX only if some shard names another framework.
            let provenNonMLX = formats.contains { !$0.isEmpty && $0 != "mlx" }
            return !provenNonMLX
        }
    }

    // MARK: - Private

    /// True when config.json has a top-level `quantization` object. mlx_lm /
    /// `mx.quantize` writes this; transformers quantized models instead carry
    /// `quantization_config`, which this deliberately ignores.
    private static func configHasMLXQuantization(at directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["quantization"] is [String: Any]
    }

    /// The lowercased `__metadata__.format` tags declared by the `*.safetensors`
    /// files in `directory` (deduplicated; untagged files contribute nothing).
    /// Only each file's header is read — an 8-byte little-endian length prefix
    /// followed by that many JSON bytes — never the weights, so this stays cheap
    /// even for multi-gigabyte bundles. Short-circuits as soon as an `mlx` tag
    /// is seen so the common case touches just one shard.
    private static func safetensorsFormatTags(at directory: URL) -> Set<String> {
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return [] }

        var formats: Set<String> = []
        for url in items where url.pathExtension == "safetensors" {
            if let format = safetensorsFormatTag(at: url)?.lowercased() {
                formats.insert(format)
                if format == "mlx" { return formats }
            }
        }
        return formats
    }

    private static func safetensorsFormatTag(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else {
            return nil
        }
        let headerLength = lengthData.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
        // Guard against a corrupt/non-safetensors file claiming a huge header.
        guard headerLength > 0, headerLength < 50_000_000 else { return nil }

        guard let headerData = try? handle.read(upToCount: Int(headerLength)),
            headerData.count == Int(headerLength),
            let object = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            let metadata = object["__metadata__"] as? [String: Any],
            let format = metadata["format"] as? String
        else { return nil }
        return format
    }
}
