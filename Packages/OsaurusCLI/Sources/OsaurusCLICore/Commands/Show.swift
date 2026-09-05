//
//  Show.swift
//  osaurus
//
//  Command to display detailed metadata for a model, similar to `ollama show`.
//

import Foundation

public struct ShowCommand: Command {
    public static let name = "show"

    // MARK: - Response Types

    private struct ShowResponse: Decodable {
        let modelfile: String?
        let parameters: String?
        let template: String?
        let details: ShowDetails?
        let modelInfo: [String: AnyCodableValue]?
        let capabilities: [String]?

        private enum CodingKeys: String, CodingKey {
            case modelfile
            case parameters
            case template
            case details
            case modelInfo = "model_info"
            case capabilities
        }
    }

    private struct ShowDetails: Decodable {
        let parentModel: String?
        let format: String?
        let family: String?
        let families: [String]?
        let parameterSize: String?
        let quantizationLevel: String?

        private enum CodingKeys: String, CodingKey {
            case parentModel = "parent_model"
            case format
            case family
            case families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }

    /// Type-erased decodable for heterogeneous JSON values.
    /// Internal (not private) so the numeric coercion can be unit-tested.
    enum AnyCodableValue: Decodable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? container.decode(Int.self) {
                self = .int(int)
            } else if let double = try? container.decode(Double.self) {
                self = .double(double)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else {
                self = .null
            }
        }

        var stringValue: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return String(d)
            case .bool(let b): return b ? "true" : "false"
            case .null: return ""
            }
        }

        var intValue: Int? {
            switch self {
            case .int(let i): return i
            case .double(let d): return Int(exactly: d)
            case .string(let s): return Int(s)
            default: return nil
            }
        }
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorDetail?
        struct ErrorDetail: Decodable {
            let message: String?
        }
    }

    // MARK: - Execute

    public static func execute(args: [String]) async {
        guard let modelArg = args.first, !modelArg.isEmpty else {
            fputs("Missing required <model_id>\n", stderr)
            fputs("Usage: osaurus show <model_id>\n", stderr)
            exit(EXIT_FAILURE)
        }

        let port = await ServerControl.ensureServerReadyOrExit()

        guard let url = URL(string: "http://127.0.0.1:\(port)/api/show") else {
            fputs("Invalid URL for show endpoint\n", stderr)
            exit(EXIT_FAILURE)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10.0

        // Build request body
        let body: [String: String] = ["name": modelArg]
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            fputs("Failed to encode request: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                fputs("Invalid response from server\n", stderr)
                exit(EXIT_FAILURE)
            }

            if http.statusCode != 200 {
                // Try to parse error message
                if let errorResp = try? JSONDecoder().decode(ErrorResponse.self, from: data),
                    let message = errorResp.error?.message
                {
                    fputs("Error: \(message)\n", stderr)
                } else {
                    fputs("Failed to get model info (status \(http.statusCode))\n", stderr)
                }
                exit(EXIT_FAILURE)
            }

            let decoder = JSONDecoder()
            let showResponse = try decoder.decode(ShowResponse.self, from: data)
            printFormattedOutput(modelArg: modelArg, response: showResponse)
            await printDecodeEstimateIfAvailable(modelArg: modelArg, port: port)
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Formatting

    private static func printFormattedOutput(modelArg: String, response: ShowResponse) {
        // Extract values from response
        let details = response.details
        let modelInfo = response.modelInfo ?? [:]

        // Architecture
        var architecture: String?
        if let arch = modelInfo["general.architecture"]?.stringValue, !arch.isEmpty {
            architecture = arch
        } else if let family = details?.family, !family.isEmpty {
            architecture = family
        }

        // Parameter count
        var parameterCount: String?
        if let params = modelInfo["general.parameter_count"]?.stringValue, !params.isEmpty {
            parameterCount = params
        } else if let size = details?.parameterSize, !size.isEmpty {
            parameterCount = size
        }

        // Context length
        var contextLength: Int?
        for (key, value) in modelInfo {
            if key.hasSuffix(".context_length"), let ctx = value.intValue {
                contextLength = ctx
                break
            }
        }

        // Embedding length
        var embeddingLength: Int?
        for (key, value) in modelInfo {
            if key.hasSuffix(".embedding_length"), let embed = value.intValue {
                embeddingLength = embed
                break
            }
        }

        // Quantization
        let quantization = details?.quantizationLevel

        // Prefer server-provided capabilities; fall back to inferring them
        // from model_info keys for older servers that omit the field.
        var capabilities: [String] = response.capabilities ?? ["completion"]
        if response.capabilities == nil, let arch = architecture?.lowercased() {
            let vlmArchitectures = [
                "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
                "qwen3_5", "qwen3_5_moe", "idefics3", "gemma3", "gemma4",
                "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3",
                "lfm2_vl", "lfm2-vl", "glm_ocr",
            ]
            if vlmArchitectures.contains(arch) {
                capabilities.append("vision")
            }
        }

        // Print Model section
        print("  Model")
        if let arch = architecture {
            print("    \(pad("architecture", to: 20))\(arch)")
        }
        if let params = parameterCount {
            print("    \(pad("parameters", to: 20))\(params)")
        }
        if let ctx = contextLength {
            print("    \(pad("context length", to: 20))\(formatNumber(ctx))")
        }
        if let embed = embeddingLength {
            print("    \(pad("embedding length", to: 20))\(formatNumber(embed))")
        }
        if let quant = quantization, !quant.isEmpty {
            print("    \(pad("quantization", to: 20))\(quant)")
        }

        // Print Capabilities section
        print("")
        print("  Capabilities")
        for cap in capabilities {
            print("    \(cap)")
        }

        // Print Parameters section if available
        if let paramsString = response.parameters, !paramsString.isEmpty {
            print("")
            print("  Parameters")
            let lines = paramsString.split(separator: "\n")
            for line in lines {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0])
                    let value = String(parts[1])
                    print("    \(pad(key, to: 20))\(value)")
                } else {
                    print("    \(line)")
                }
            }
        }
    }

    // MARK: - Decode-speed estimate (memory-bandwidth-based)

    /// Prints `Estimated decode: ~NN tok/s on this Mac (…)` when — and only
    /// when — the model's weights are installed locally (size computable) AND
    /// a bandwidth number exists: a calibration record from
    /// `osaurus bench --calibrate`, else the chip's spec-sheet bandwidth.
    /// Decode is memory-bound, so tok/s ≈ bandwidth × 0.7 ÷ weights bytes
    /// (see `MemoryBandwidthCalibration`). Silent otherwise: a missing
    /// estimate must never break `show` for remote or unknown models.
    private static func printDecodeEstimateIfAvailable(modelArg: String, port: Int) async {
        guard let weightsBytes = await localWeightsBytes(forModelId: modelArg, port: port),
            weightsBytes > 0
        else {
            return
        }
        let bandwidthGBps: Double
        let sourceLabel: String
        if let record = MemoryBandwidthCalibration.readValidRecord() {
            bandwidthGBps = record.measuredBandwidthGBps
            sourceLabel = "measured"
        } else if let spec = MemoryBandwidthCalibration.specBandwidthGBps(
            brandString: MemoryBandwidthCalibration.chipBrandString()) {
            bandwidthGBps = spec
            sourceLabel = "spec"
        } else {
            return
        }
        let tps = MemoryBandwidthCalibration.estimatedDecodeTps(
            weightsBytes: weightsBytes, bandwidthGBps: bandwidthGBps)
        guard tps > 0, tps.isFinite else { return }
        print("")
        print(String(
            format: "  Estimated decode: ~%.0f tok/s on this Mac (%@ %.0f GB/s × %.1f ÷ %.1f GB weights)",
            tps, sourceLabel, bandwidthGBps,
            MemoryBandwidthCalibration.decodeEfficiency,
            Double(weightsBytes) / 1e9))
    }

    /// Sum of local `.safetensors` file sizes for the model, or nil when the
    /// model directory can't be located (not installed locally). The
    /// recursive walk covers sharded weights placed in subdirectories by
    /// `osaurus pull`.
    static func localWeightsBytes(forModelId modelId: String, port: Int) async -> Int64? {
        let baseDir = await modelsBaseDirectory(port: port)
        guard let modelDir = resolveLocalModelDirectory(forModelId: modelId, under: baseDir)
        else { return nil }
        // MoE models activate only a fraction of their weights per token, so
        // the all-weights-streamed decode formula understates them severalfold
        // (a 35B-A3B bundle showing ~12 tok/s while really decoding ~10x that
        // misleads worse than no estimate). Suppress until the estimator
        // learns active-parameter bytes; dense models keep their line.
        guard !isMoEBundle(at: modelDir) else { return nil }
        return weightsBytes(under: modelDir)
    }

    /// True when the bundle's config.json declares a mixture-of-experts
    /// architecture (any of the expert-count keys used across families, at
    /// the top level or under text_config).
    static func isMoEBundle(at modelDir: URL) -> Bool {
        let configURL = modelDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let expertKeys = [
            "num_experts", "n_routed_experts", "num_local_experts", "num_experts_per_tok",
        ]
        func declaresExperts(_ object: [String: Any]) -> Bool {
            expertKeys.contains { key in
                (object[key] as? Int).map { $0 > 1 } ?? false
            }
        }
        if declaresExperts(root) { return true }
        if let textConfig = root["text_config"] as? [String: Any], declaresExperts(textConfig) {
            return true
        }
        return false
    }

    /// Models base directory, in order of authority:
    /// 1. The running server's own scan root (`/health` →
    ///    `local_model_scan.root`) — authoritative, because the user can
    ///    point the app at any folder (e.g. `~/MLXModels`) and only the
    ///    scanning server knows which one it actually lists models from.
    /// 2. The shared group-defaults path (mirrors
    ///    `PullCommand.resolveLocalDirectory`).
    /// 3. `~/.osaurus/models` (the default install location).
    static func modelsBaseDirectory(port: Int) async -> URL {
        if let healthURL = URL(string: "http://127.0.0.1:\(port)/health"),
            let health = await BenchCommand.fetchJSON(healthURL),
            let root = modelsRoot(fromHealth: health) {
            return root
        }
        if let shared = UserDefaults(suiteName: "group.com.osaurus.shared"),
            let storedPath = shared.string(forKey: "modelsDirectoryPath"),
            !storedPath.isEmpty {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".osaurus/models", isDirectory: true)
    }

    /// Extracts the server's local-model scan root from a `/health` payload.
    /// Pure so the JSON contract is unit-testable against a fixture.
    static func modelsRoot(fromHealth health: [String: Any]) -> URL? {
        guard let scan = health["local_model_scan"] as? [String: Any],
            let root = scan["root"] as? String,
            !root.isEmpty
        else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    /// Resolves the model's directory under `baseDir`, trying both name
    /// forms:
    /// 1. The id's `/`-components nested as-is (matches `osaurus pull`
    ///    layout and fully-qualified `org/name` ids).
    /// 2. A case-insensitive scan of the first two directory levels,
    ///    comparing lowercased names — the server lists lowercased ids
    ///    (e.g. `qwen3.6-35b-a3b-mxfp4-mtp`) while directories keep their
    ///    original casing (`OsaurusAI/Qwen3.6-35B-A3B-MXFP4-MTP`), and a
    ///    single-component id may name a repo nested one org level down.
    ///    Two levels is enough: discovery supports flat and `org/repo`
    ///    layouts; deeper multi-org roots are rare and this line is
    ///    best-effort display, never an error.
    static func resolveLocalModelDirectory(forModelId modelId: String, under baseDir: URL) -> URL? {
        let fm = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        let components = modelId.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }

        // 1. Exact nesting of the id's components.
        let exact = components.reduce(baseDir) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        if isDirectory(exact) { return exact }

        // 2. Case-insensitive two-level scan.
        func childDirectories(of url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]))
                ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        let loweredId = modelId.lowercased()
        var leafMatch: URL?
        for level1 in childDirectories(of: baseDir) {
            let name1 = level1.lastPathComponent.lowercased()
            if name1 == loweredId { return level1 }
            for level2 in childDirectories(of: level1) {
                let name2 = level2.lastPathComponent.lowercased()
                // Full relative-path match wins over a bare leaf-name match.
                if "\(name1)/\(name2)" == loweredId { return level2 }
                if leafMatch == nil, name2 == loweredId { leafMatch = level2 }
            }
        }
        return leafMatch
    }

    /// Recursive `.safetensors` byte sum, nil when `directory` is absent.
    /// Split from the id-based resolver so tests can point it at a fixture
    /// directory without touching user defaults or the home directory.
    static func weightsBytes(under directory: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension.lowercased() == "safetensors" {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func pad(_ string: String, to width: Int) -> String {
        if string.count >= width {
            return string + " "
        }
        return string + String(repeating: " ", count: width - string.count)
    }

    private static func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? String(num)
    }
}
