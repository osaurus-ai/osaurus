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

        private enum CodingKeys: String, CodingKey {
            case modelfile
            case parameters
            case template
            case details
            case modelInfo = "model_info"
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

    /// Type-erased decodable for heterogeneous JSON values
    private enum AnyCodableValue: Decodable {
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
            case .double(let d): return Int(d)
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

        // Determine capabilities
        var capabilities: [String] = ["completion"]
        // Check if it's a VLM based on architecture or family
        if let arch = architecture?.lowercased() {
            let vlmIndicators = ["vl", "vision", "llava", "pixtral", "paligemma", "vlm"]
            if vlmIndicators.contains(where: { arch.contains($0) }) {
                capabilities.append("vision")
            }
        }
        // Also check model name
        let lowerModelArg = modelArg.lowercased()
        let vlmNameIndicators = ["-vl-", "-vl", "vl-", "llava", "pixtral", "paligemma", "vision"]
        if vlmNameIndicators.contains(where: { lowerModelArg.contains($0) }) && !capabilities.contains("vision") {
            capabilities.append("vision")
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
