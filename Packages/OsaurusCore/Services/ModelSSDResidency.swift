//
//  ModelSSDResidency.swift
//  osaurus
//
//  Bytes of a model bundle that are read from SSD on demand and never need to be resident in RAM.
//
//  Qwen4Exp bundles (Qwen3.8 Flash-Next affine/JANGH, Allosaurus) ship a per-layer n-gram embedding table
//  (`*.ple.ngram_embedding.*`, 18-54 GB). The runtime reads its rows with `pread` through the page cache; the
//  table is never loaded as weights (vmlx-swift `LoadBundleFacts.ssdResidentTableBytes`). A RAM estimate that
//  counts it told a 128 GB Mac that Allosaurus (32.5 GB of weights, 88 GB download) needed ~110 GB. Catalog
//  cards, the detail sheet and load admission all subtract these bytes through this one rule.
//

import Foundation

enum ModelSSDResidency {
    /// Tensor-name marker of the SSD-resident n-gram table. Must match vmlx-swift's loader rule.
    static let ngramTensorMarker = ".ple.ngram_embedding."

    /// Hub tag / `model_type` of the only family that ships the table today.
    static let ngramModelTypes: Set<String> = ["qwen4_exp"]

    static func mayHaveNGramTable(modelType: String?, tags: [String]?) -> Bool {
        if let modelType, ngramModelTypes.contains(modelType.lowercased()) { return true }
        return tags?.contains { ngramModelTypes.contains($0.lowercased()) } ?? false
    }

    // MARK: Local bundles

    /// Sum of n-gram tensor payloads from the bundle's safetensors HEADERS (no weights read). `0` when there
    /// is no table or the headers cannot be read. Off-main callers only (one small read per shard).
    nonisolated static func localNGramBytes(at directory: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for url in entries where url.pathExtension == "safetensors" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8,
                let length = headerLength(lengthData),
                let header = try? handle.read(upToCount: Int(length)), header.count == Int(length)
            else { continue }
            total &+= ngramBytes(inHeader: header)
        }
        return total
    }

    /// `localNGramBytes` gated on the bundle's `config.json` model type, so discovery of every other model pays
    /// one small config read and nothing more. `nil` when the architecture has no n-gram table.
    nonisolated static func localSSDResidentBytes(at directory: URL) -> Int64? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelType = object["model_type"] as? String,
            mayHaveNGramTable(modelType: modelType, tags: nil)
        else { return nil }
        let bytes = localNGramBytes(at: directory)
        return bytes > 0 ? bytes : nil
    }

    // MARK: Hub repos

    /// The repo's n-gram bytes from its index plus the headers of the shards that hold the table (two small
    /// HTTP range reads per shard; Allosaurus: 11 shards). Cached per repo revision. `nil` on network failure
    /// (callers then keep the conservative whole-download estimate), `0` when the repo has no table.
    static func remoteNGramBytes(repoId: String, revision: String?) async -> Int64? {
        let cacheKey = repoId + Self.cacheSuffix
        if let cached = ModelSizeCache.bytes(forId: cacheKey, matchingRevision: revision) {
            return cached == Self.noTableSentinel ? 0 : cached
        }
        guard let index = await fetch(repoId: repoId, path: "model.safetensors.index.json", range: nil),
            let object = try? JSONSerialization.jsonObject(with: index) as? [String: Any],
            let weightMap = object["weight_map"] as? [String: String]
        else { return nil }
        let shards = Set(weightMap.filter { $0.key.contains(ngramTensorMarker) }.values)
        var total: Int64 = 0
        for shard in shards.sorted() {
            guard let lengthData = await fetch(repoId: repoId, path: shard, range: 0...7),
                lengthData.count == 8, let length = headerLength(lengthData),
                let header = await fetch(repoId: repoId, path: shard, range: 8...(8 + Int(length) - 1)),
                header.count == Int(length)
            else { return nil }
            total &+= ngramBytes(inHeader: header)
        }
        ModelSizeCache.record(id: cacheKey, bytes: total == 0 ? Self.noTableSentinel : total, revision: revision)
        return total
    }

    // MARK: Shared parsing

    /// `ModelSizeCache` only stores positive sizes; a sentinel records "checked, no table".
    private static let noTableSentinel: Int64 = 1
    private static let cacheSuffix = "#ssd-resident-ngram"

    static func headerLength(_ data: Data) -> UInt64? {
        let length = data.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        return length > 0 && length <= 64 << 20 ? length : nil
    }

    static func ngramBytes(inHeader header: Data) -> Int64 {
        guard let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return 0 }
        var total: Int64 = 0
        for (name, value) in object where name.contains(ngramTensorMarker) {
            if let offsets = (value as? [String: Any])?["data_offsets"] as? [Int], offsets.count == 2,
                offsets[1] >= offsets[0]
            {
                total &+= Int64(offsets[1] - offsets[0])
            }
        }
        return total
    }

    private static func fetch(repoId: String, path: String, range: ClosedRange<Int>?) async -> Data? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/main/\(encoded)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        HuggingFaceAuth.authorize(&request)
        // Stream and stop at the expected size: even a server that ignores Range can never pull a whole shard.
        let limit = range?.count ?? (16 << 20)
        guard let (stream, response) = try? await GlobalProxySettings.sharedSession().bytes(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        var data = Data()
        data.reserveCapacity(min(limit, 1 << 20))
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            return nil
        }
        if range == nil, data.count >= limit { return nil }  // index larger than any real index: refuse to parse
        return data
    }
}
