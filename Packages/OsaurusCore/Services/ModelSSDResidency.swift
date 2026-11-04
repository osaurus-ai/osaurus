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

    // MARK: Local bundles

    /// Sum of n-gram tensor payloads from the bundle's safetensors HEADERS (no weights read). `0` when there
    /// is no table or the headers cannot be read. Off-main callers only (one small read per shard).
    nonisolated static func localNGramBytes(at directory: URL) -> Int64 {
        localTableBytes(at: directory) ?? 0
    }

    private nonisolated static func localTableBytes(at directory: URL) -> Int64? {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        let shards = entries.filter { $0.pathExtension == "safetensors" }
        guard !shards.isEmpty else { return nil }
        var total: Int64 = 0
        for url in shards {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8,
                let length = headerLength(lengthData),
                let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
                let fileSize = try? handle.seekToEnd(), fileSize >= 8 + length
            else { return nil }
            guard let bytes = validatedNGramBytes(inHeader: header, payloadLength: Int64(fileSize - 8 - length))
            else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// Discover storage from tensor headers, independent of repo names, quantization labels or Hub tags.
    /// The marker is the runtime's SSD table contract, not a prediction from the architecture name.
    nonisolated static func localSSDResidentBytes(at directory: URL) -> Int64? {
        localTableBytes(at: directory)
    }

    // MARK: Hub repos

    /// The repo's n-gram bytes from its index plus the headers of the shards that hold the table (two small
    /// HTTP range reads per shard; Allosaurus: 11 shards). Cached per repo revision. `nil` on network failure
    /// (callers then keep the conservative whole-download estimate), `0` when the repo has no table.
    static func remoteNGramBytes(
        repoId: String,
        revision: String?,
        session: URLSession? = nil
    ) async -> Int64? {
        let cacheKey = repoId + Self.cacheSuffix
        if let cached = cachedBytes(repoId: repoId, revision: revision) { return cached }
        guard
            let indexResponse = await fetch(
                repoId: repoId,
                path: "model.safetensors.index.json",
                range: nil,
                session: session
            )
        else { return nil }
        // Pin every subsequent request to the same Hub commit, even if main moves during inspection.
        let commit = indexResponse.commit ?? "main"
        let shards: [String]
        var weightMap: [String: String]?
        if indexResponse.statusCode == 404 {
            // Small bundles commonly have a single safetensors file and no index.
            shards = ["model.safetensors"]
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: indexResponse.data) as? [String: Any],
                let map = object["weight_map"] as? [String: String], !map.isEmpty
            else { return nil }
            weightMap = map
            shards = Set(map.filter { $0.key.contains(ngramTensorMarker) }.values).sorted()
        }
        var total: Int64 = 0
        for shard in shards {
            guard isSafeShardPath(shard),
                let lengthResponse = await fetch(
                    repoId: repoId,
                    path: shard,
                    range: 0 ... 7,
                    session: session,
                    revision: commit
                ),
                lengthResponse.data.count == 8, let length = headerLength(lengthResponse.data),
                let fileLength = lengthResponse.fileLength, fileLength >= 8 + Int64(length),
                let response = await fetch(
                    repoId: repoId,
                    path: shard,
                    range: 8 ... (8 + Int(length) - 1),
                    session: session,
                    revision: lengthResponse.commit ?? commit
                ),
                response.data.count == Int(length), response.fileLength == fileLength,
                let bytes = validatedNGramBytes(inHeader: response.data, payloadLength: fileLength - 8 - Int64(length))
            else { return nil }
            if let map = weightMap {
                guard let tensors = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any],
                    Set(tensors.keys.filter { $0.contains(ngramTensorMarker) })
                        == Set(map.filter { $0.value == shard && $0.key.contains(ngramTensorMarker) }.keys)
                else { return nil }
            }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        ModelSizeCache.record(id: cacheKey, bytes: total == 0 ? Self.noTableSentinel : total, revision: revision)
        return total
    }

    // MARK: Shared parsing

    /// `ModelSizeCache` only stores positive sizes; a sentinel records "checked, no table".
    private static let noTableSentinel: Int64 = 1
    static let cacheSuffix = "#ssd-resident-ngram-v2"

    static func cachedBytes(repoId: String, revision: String? = nil) -> Int64? {
        ModelSizeCache.bytes(forId: repoId + cacheSuffix, matchingRevision: revision).map {
            $0 == noTableSentinel ? 0 : $0
        }
    }

    static func headerLength(_ data: Data) -> UInt64? {
        let length = data.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        return length > 0 && length <= 64 << 20 ? length : nil
    }

    /// Sum of n-gram payload sizes in one safetensors header. Headers can come from an untrusted Hub repo, so
    /// offsets must be non-negative, ordered and overflow-free; with `payloadLength` (local files) each range
    /// must also lie inside the file, so a crafted header cannot shrink a load-admission estimate.
    static func ngramBytes(inHeader header: Data, payloadLength: Int64? = nil) -> Int64 {
        validatedNGramBytes(inHeader: header, payloadLength: payloadLength) ?? 0
    }

    /// Reject inconsistent or overlapping spans, including aliases of compute tensors. Invalid metadata
    /// must never reduce the memory estimate. Byte spans account for packed weights/scales without
    /// interpreting JANG, JANGH or JANGHT labels as an exact bits-per-parameter value.
    static func validatedNGramBytes(inHeader header: Data, payloadLength: Int64? = nil) -> Int64? {
        guard let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return nil }
        var spans: [(start: Int64, end: Int64, table: Bool)] = []
        for (name, value) in object where name != "__metadata__" {
            guard let offsets = (value as? [String: Any])?["data_offsets"] as? [Int64], offsets.count == 2,
                offsets[0] >= 0, offsets[1] >= offsets[0],
                payloadLength.map({ offsets[1] <= $0 }) ?? true
            else { return nil }
            spans.append((offsets[0], offsets[1], name.contains(ngramTensorMarker)))
        }
        var end: Int64 = 0
        var total: Int64 = 0
        for span in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            guard span.start >= end else { return nil }
            end = span.end
            if span.table {
                let sum = total.addingReportingOverflow(span.end - span.start)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
            }
        }
        return total
    }

    private static func isSafeShardPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains {
                $0 == ".." || $0 == "." || $0.isEmpty
            }
    }

    private struct FetchResult {
        let data: Data
        let fileLength: Int64?
        let commit: String?
        let statusCode: Int
    }

    private static func fetch(
        repoId: String,
        path: String,
        range: ClosedRange<Int>?,
        session: URLSession?,
        revision: String = "main"
    ) async -> FetchResult? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://huggingface.co/\(repoId)/resolve/\(revision)/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        HuggingFaceAuth.authorize(&request)
        // Stream and stop at the expected size: even a server that ignores Range can never pull a whole shard.
        let limit = range?.count ?? (16 << 20)
        guard let (stream, response) = try? await (session ?? GlobalProxySettings.sharedSession()).bytes(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        let commit = http.value(forHTTPHeaderField: "X-Repo-Commit")
        if revision != "main", let commit, commit != revision { return nil }
        if range == nil, http.statusCode == 404 {
            return FetchResult(data: Data(), fileLength: nil, commit: commit, statusCode: 404)
        }
        guard (200 ..< 300).contains(http.statusCode) else { return nil }
        var fileLength: Int64?
        if let range {
            // A 200 response starts at byte zero even when Range was requested. Never
            // parse that as the header and persist a false "no table" cache entry.
            guard http.statusCode == 206,
                let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                contentRange.hasPrefix("bytes \(range.lowerBound)-\(range.upperBound)/")
            else { return nil }
            let total = contentRange.dropFirst("bytes \(range.lowerBound)-\(range.upperBound)/".count)
            // Without a complete length we cannot prove offsets stay inside the tensor payload.
            guard let length = Int64(total), length > range.upperBound else { return nil }
            fileLength = length
        }
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
        return FetchResult(data: data, fileLength: fileLength, commit: commit, statusCode: http.statusCode)
    }
}
