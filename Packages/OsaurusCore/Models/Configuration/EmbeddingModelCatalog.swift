//
//  EmbeddingModelCatalog.swift
//  osaurus
//
//  Embedding models offered in Local Models → Embedding and Model Defaults →
//  Embedding Model. Curated entries carry the facts the UI shows before a
//  download plus the retrieval prompts for bundles that don't ship a
//  sentence-transformers prompt file. OsaurusAI embedding repos are listed
//  automatically from the Hub.
//

import Foundation

enum EmbeddingModelCatalog {
    struct Entry: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let family: String
        let dimension: Int
        let downloadSizeBytes: Int64
        let languages: String
        let summary: String
        var isTopPick: Bool = false
        /// Applied when the bundle's `config_sentence_transformers.json`
        /// does not declare a query prompt.
        var queryPrefix: String? = nil
        var documentPrefix: String? = nil
        var isBuiltIn: Bool = false

        var downloadURL: String { "https://huggingface.co/\(id)" }

        var mlxModel: MLXModel {
            MLXModel(
                id: id,
                name: name,
                description: summary,
                downloadURL: downloadURL,
                isTopSuggestion: isTopPick,
                downloadSizeBytes: downloadSizeBytes
            )
        }
    }

    private static let qwen3Query =
        "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"
    private static let bgeQuery = "Represent this sentence for searching relevant passages: "

    static let builtIn = Entry(
        id: EmbeddingProfile.builtInModelId,
        name: "Potion Base 4M",
        family: "Model2Vec",
        dimension: 128,
        downloadSizeBytes: 15_000_000,
        languages: "English",
        summary: "Ships with Osaurus. A static embedding model that indexes instantly and uses almost no memory.",
        isBuiltIn: true
    )

    static let curated: [Entry] = [
        builtIn,
        Entry(
            id: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
            name: "Qwen3 Embedding 0.6B",
            family: "Qwen3",
            dimension: 1024,
            downloadSizeBytes: 351_230_811,
            languages: "Multilingual",
            summary: "Strong multilingual retrieval at a small size. A good first upgrade from the built-in model.",
            isTopPick: true,
            queryPrefix: qwen3Query,
            documentPrefix: ""
        ),
        Entry(
            id: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
            name: "Qwen3 Embedding 4B",
            family: "Qwen3",
            dimension: 2560,
            downloadSizeBytes: 2_278_577_159,
            languages: "Multilingual",
            summary: "Higher retrieval quality than 0.6B for large knowledge collections, at several times the memory.",
            queryPrefix: qwen3Query,
            documentPrefix: ""
        ),
        Entry(
            id: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
            name: "Qwen3 Embedding 8B",
            family: "Qwen3",
            dimension: 4096,
            downloadSizeBytes: 4_273_094_744,
            languages: "Multilingual",
            summary: "The largest Qwen3 embedder. Best quality, slowest indexing; suited to Macs with plenty of memory.",
            queryPrefix: qwen3Query,
            documentPrefix: ""
        ),
        Entry(
            id: "nomic-ai/modernbert-embed-base",
            name: "ModernBERT Embed Base",
            family: "ModernBERT",
            dimension: 768,
            downloadSizeBytes: 599_677_068,
            languages: "English",
            summary: "Nomic's embedder on the ModernBERT encoder, with an 8K-token context.",
            queryPrefix: "search_query: ",
            documentPrefix: "search_document: "
        ),
        Entry(
            id: "BAAI/bge-small-en-v1.5",
            name: "BGE Small EN v1.5",
            family: "BERT",
            dimension: 384,
            downloadSizeBytes: 134_411_157,
            languages: "English",
            summary: "Small, fast English retrieval model from BAAI.",
            queryPrefix: bgeQuery,
            documentPrefix: ""
        ),
        Entry(
            id: "BAAI/bge-base-en-v1.5",
            name: "BGE Base EN v1.5",
            family: "BERT",
            dimension: 768,
            downloadSizeBytes: 438_900_399,
            languages: "English",
            summary: "Balanced English retrieval model from BAAI.",
            queryPrefix: bgeQuery,
            documentPrefix: ""
        ),
        Entry(
            id: "BAAI/bge-large-en-v1.5",
            name: "BGE Large EN v1.5",
            family: "BERT",
            dimension: 1024,
            downloadSizeBytes: 1_341_561_506,
            languages: "English",
            summary: "The largest BGE v1.5 English model, for the best quality in its family.",
            queryPrefix: bgeQuery,
            documentPrefix: ""
        ),
        Entry(
            id: "mixedbread-ai/mxbai-embed-large-v1",
            name: "mxbai Embed Large v1",
            family: "BERT",
            dimension: 1024,
            downloadSizeBytes: 671_274_755,
            languages: "English",
            summary: "Mixedbread's large English embedder with strong retrieval benchmarks.",
            queryPrefix: bgeQuery,
            documentPrefix: ""
        ),
        Entry(
            id: "intfloat/multilingual-e5-small",
            name: "Multilingual E5 Small",
            family: "XLM-RoBERTa",
            dimension: 384,
            downloadSizeBytes: 514_948_334,
            languages: "Multilingual",
            summary: "Compact multilingual retrieval model covering about 100 languages.",
            queryPrefix: "query: ",
            documentPrefix: "passage: "
        ),
        Entry(
            id: "sentence-transformers/all-MiniLM-L6-v2",
            name: "all-MiniLM-L6-v2",
            family: "BERT",
            dimension: 384,
            downloadSizeBytes: 91_607_178,
            languages: "English",
            summary: "The classic general-purpose sentence-transformers model. Fast and small."
        ),
        Entry(
            id: "minishlab/potion-base-8M",
            name: "Potion Base 8M",
            family: "Model2Vec",
            dimension: 256,
            downloadSizeBytes: 31_142_161,
            languages: "English",
            summary: "A larger sibling of the built-in static model. Same instant indexing, better recall."
        ),
        Entry(
            id: "minishlab/potion-base-32M",
            name: "Potion Base 32M",
            family: "Model2Vec",
            dimension: 512,
            downloadSizeBytes: 131_197_807,
            languages: "English",
            summary: "The largest general Potion static model."
        ),
        Entry(
            id: "minishlab/potion-retrieval-32M",
            name: "Potion Retrieval 32M",
            family: "Model2Vec",
            dimension: 512,
            downloadSizeBytes: 131_197_807,
            languages: "English",
            summary: "A static model tuned for retrieval, keeping Model2Vec's speed."
        ),
        Entry(
            id: "minishlab/potion-multilingual-128M",
            name: "Potion Multilingual 128M",
            family: "Model2Vec",
            dimension: 256,
            downloadSizeBytes: 537_336_040,
            languages: "Multilingual",
            summary: "A static multilingual model for over 100 languages."
        ),
    ]

    static func entry(for id: String) -> Entry? {
        curated.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func isCatalogId(_ id: String) -> Bool { entry(for: id) != nil }

    /// Curated name, or the repository name for anything else.
    static func displayName(for id: String) -> String {
        entry(for: id)?.name ?? id.split(separator: "/").last.map(String.init) ?? id
    }

    // MARK: - OsaurusAI listing

    static let osaurusAIAuthor = "OsaurusAI"

    /// Hub tags that mark an embedding repo.
    static func isEmbeddingListing(pipelineTag: String?, tags: [String]) -> Bool {
        if let pipelineTag, ["feature-extraction", "sentence-similarity"].contains(pipelineTag) {
            return true
        }
        return tags.contains("sentence-transformers")
    }

    /// OsaurusAI embedding repos not already in the curated list. Facts that
    /// the listing doesn't carry (dimension, size) stay unknown until download.
    static func fetchOsaurusAIModels() async -> [MLXModel] {
        let listings = await HuggingFaceService.shared.fetchModels(author: osaurusAIAuthor)
        return listings
            .filter { isEmbeddingListing(pipelineTag: $0.pipelineTag, tags: $0.tags) }
            .filter { !isCatalogId($0.id) }
            .map { listing in
                let repo = listing.id.split(separator: "/").last.map(String.init) ?? listing.id
                return MLXModel(
                    id: listing.id,
                    name: repo,
                    description: "Embedding model published by OsaurusAI.",
                    downloadURL: "https://huggingface.co/\(listing.id)",
                    downloads: listing.downloads
                )
            }
    }

    // MARK: - Installed

    /// Embedding bundles on disk that are not curated entries: anything the
    /// user downloaded by repo id, placed in the models folder, or has in a
    /// registered external source.
    static func discoveredModels() -> [MLXModel] {
        ModelManager.localModelsSnapshotNonBlocking()
            .filter { !isCatalogId($0.id) && !EmbeddingProfile.isBuiltInId($0.id) }
            .filter { $0.isDownloaded && EmbeddingDetection.isEmbedding(at: $0.localDirectory) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Directory of an installed curated entry, or `nil` when not on disk.
    static func installedDirectory(for entry: Entry) -> URL? {
        guard !entry.isBuiltIn else { return nil }
        if entry.mlxModel.isDownloaded { return entry.mlxModel.localDirectory }
        return ExternalModelLocator.path(forId: entry.id)
    }
}
