import Foundation

/// Ships the reviewed design without requiring the editor, a local profile, or a network request.
/// Editor builds may replace the immutable snapshot in memory; ordinary builds only read this bundle.
enum DesignLibraryRuntime {
    /// The only design files the app ships; baselines are Inspector resources.
    static var resourceNames: [String] {
        let folder = Bundle.module.resourceURL?.appendingPathComponent("LibraryResources")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder?.path ?? "")) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
    static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "LibraryResources") else {
            throw DesignWorkingError.invalid("Missing bundled design library: " + name)
        }
        return try Data(contentsOf: url)
    }
    static func bundledSnapshot() -> DesignThemeSnapshot? {
        do {
            let document = try JSONDecoder().decode(DesignWorkingDocument.self, from: resource("design-library")).resolvingColors()
            return try DesignLibraryDefinition.makeSnapshot(document)
        } catch {
            // A broken package must be visible to the engineer, never silently ship the old appearance.
            preconditionFailure("Bundled design library cannot load: \(error)")
        }
    }
}
