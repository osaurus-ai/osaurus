import Foundation
import HeliosPorterCore

let app = HeliosPorterApp()
let output = app.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
)

exit(output.exitCode)
