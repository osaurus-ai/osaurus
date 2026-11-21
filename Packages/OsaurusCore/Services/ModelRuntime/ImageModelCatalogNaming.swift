//
//  ImageModelCatalogNaming.swift
//  osaurus
//
//  Plain names for image model downloads. Repo and folder names carry the
//  engine ("mflux") and the precision ("8bit", "q4", "fp8"); the catalog shows
//  one row per model and folds those tokens into a version.
//

import Foundation

enum ImageModelCatalogNaming {
    struct Parsed: Equatable, Sendable {
        /// Lowercased and publisher-independent, so mirrors of one model fold
        /// together.
        let familyKey: String
        let displayName: String
        /// "8-bit", "FP8", "NF4"; nil for an unquantized build.
        let versionLabel: String?
        let bits: Int?
    }

    /// One downloadable or installed build of a family.
    struct Version: Equatable, Sendable {
        let id: String
        let bits: Int?
        let sizeBytes: Int64?
    }

    private static let droppedTokens: Set<String> = ["mflux", "mlx", "diffusers"]

    /// Parses a repo id ("OsaurusAI/Qwen-Image-2.1-mflux-8bit") or a bundle
    /// folder name ("Qwen-Image-2.1-mflux-8bit").
    static func parse(_ repoIdOrFolder: String) -> Parsed {
        let tail = repoIdOrFolder.split(separator: "/").last.map(String.init) ?? repoIdOrFolder
        let normalized = tail
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "-bit", with: "bit", options: .caseInsensitive)
        var kept: [String] = []
        var versionLabel: String?
        var bits: Int?
        for token in normalized.split(separator: "-").map(String.init) where !token.isEmpty {
            let lower = token.lowercased()
            if droppedTokens.contains(lower) { continue }
            if let version = version(lower) {
                if versionLabel == nil {
                    versionLabel = version.label
                    bits = version.bits
                }
                continue
            }
            kept.append(token)
        }
        guard !kept.isEmpty else {
            return Parsed(familyKey: tail.lowercased(), displayName: tail, versionLabel: versionLabel, bits: bits)
        }
        return Parsed(
            familyKey: kept.joined(separator: "-").lowercased(),
            displayName: kept.map(displayWord).joined(separator: " "),
            versionLabel: versionLabel,
            bits: bits
        )
    }

    /// "Qwen Image 2.1 Turbo (8-bit)" for menus that list installed builds.
    static func pickerName(_ repoIdOrFolder: String) -> String {
        let parsed = parse(repoIdOrFolder)
        return parsed.versionLabel.map { "\(parsed.displayName) (\($0))" } ?? parsed.displayName
    }

    /// Highest precision first; size breaks ties, largest first.
    static func bestFirst(_ versions: [Version]) -> [Version] {
        versions.sorted { lhs, rhs in
            let l = lhs.bits ?? 32
            let r = rhs.bits ?? 32
            if l != r { return l > r }
            switch (lhs.sizeBytes, rhs.sizeBytes) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    /// The build a family row downloads by default: the largest one whose
    /// download fits this Mac's comfortable model budget, else the smallest.
    /// Until every size is known, the lowest precision.
    static func recommendedId(_ versions: [Version], physicalMemoryGB: Double) -> String? {
        let sized = versions.compactMap { version in
            version.sizeBytes.flatMap { $0 > 0 ? (version, $0) : nil }
        }
        guard sized.count == versions.count, physicalMemoryGB > 0 else {
            return bestFirst(versions).last?.id
        }
        let budgetGB = GPUMemoryBudget.assessment(
            modelSizeBytes: nil, sizeSource: nil, physicalMemoryGB: physicalMemoryGB
        ).comfortableModelBudgetGB
        let fitting = sized.filter { Double($0.1) / GPUMemoryBudget.bytesPerGB <= budgetGB }
        let pick = fitting.max { $0.1 < $1.1 } ?? sized.min { $0.1 < $1.1 }
        return pick?.0.id
    }

    // MARK: - Private

    private static func version(_ token: String) -> (label: String, bits: Int?)? {
        switch token {
        case "fp8": return ("FP8", 8)
        case "fp16": return ("FP16", 16)
        case "bf16": return ("BF16", 16)
        case "fp32": return ("FP32", 32)
        case "nf4": return ("NF4", 4)
        default: break
        }
        for prefix in ["q", "int"] where token.hasPrefix(prefix) {
            if let n = Int(token.dropFirst(prefix.count)) { return ("\(n)-bit", n) }
        }
        if token.hasSuffix("bit"), let n = Int(token.dropLast(3)) { return ("\(n)-bit", n) }
        return nil
    }

    private static func displayWord(_ token: String) -> String {
        if token.lowercased() == "flux" { return "FLUX" }
        guard token == token.lowercased(), let first = token.first else { return token }
        return first.uppercased() + token.dropFirst()
    }
}
