import Foundation
import OsaurusCore
import OsaurusEvalsKit

extension OsaurusEvalsCLI {
    @MainActor
    static func runVisionInventory(_ args: [String]) async -> Int32 {
        guard args.count == 2, args[0] == "--out" else {
            print("osaurus-evals vision-inventory --out <inventory.json>")
            return args == ["--help"] ? 0 : 2
        }
        let plan = EvalBootstrapPlan(loadInstalledPlugins: false, initializeSearchIndices: false)
        _ = EvalBootstrap.configureIsolatedRunStorage(for: plan)
        let bundles = await InstalledVisionEvaluation.inventory()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(bundles).write(to: URL(fileURLWithPath: args[1]), options: .atomic)
            print("Inventoried \(bundles.count) installed bundles; \(bundles.filter(\.supportsImage).count) advertise image input. No models loaded.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("vision inventory failed: \(error)\n".utf8))
            return 1
        }
    }
}
