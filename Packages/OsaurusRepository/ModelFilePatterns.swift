//
//  ModelFilePatterns.swift
//  osaurus
//
//  Which files of a Hugging Face model repository Osaurus downloads. The app
//  (`ModelDownloadService`) and the CLI (`osaurus pull`) both read these, so
//  a model pulled from Terminal is the same as one downloaded in the app.
//

import Darwin

public enum ModelFilePatterns {
    /// `fnmatch` globs matched against a file's name (not its path).
    public static let download: [String] = [
        "*.json",
        "*.jinja",
        "*.txt",
        "*.model",
        "*.safetensors",
    ]

    /// Names skipped even when a pattern matches.
    public static let excluded: Set<String> = [
        "README.md",
        ".gitattributes",
    ]

    /// Whether the file at `path` (a repository-relative path) is downloaded.
    public static func matches(path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard !excluded.contains(name) else { return false }
        return download.contains { fnmatch($0, name, 0) == 0 }
    }
}
